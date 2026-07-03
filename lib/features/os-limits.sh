#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/os-limits.sh - OS connection-limit tuning (systemd LimitNOFILE + sysctl)
################################################################################
# OPT-IN (--os-limits), default-off. Writes two standard, conservative OS config
# drop-ins so LiteSpeed can accept more concurrent connections. It touches the OS
# layer ONLY — never the LSWS httpd_config — so it is safe on Enterprise (that
# guard is about httpd_config.xml, not systemd/sysctl). On panel-managed hosts
# (DirectAdmin/RunCloud/Plesk/…), where the operator may not own systemd/sysctl,
# it is manual-only (mirrors modsec/recaptcha).
#
# Two owned files (both start with the managed marker so detect/rollback can prove
# ownership; both paths go through _lso_fs so fixtures work):
#   /etc/systemd/system/lsws.service.d/override.conf  <- [Service] LimitNOFILE=65535
#   /etc/sysctl.d/99-litespeed.conf                   <- net.core/net.ipv4/vm tuning
#
# Values are FIXED constants (not RAM/CPU-tier scaled) per SPEC §T2.3. The bbr +
# fq lines are only emitted when the kernel actually offers BBR congestion control
# (tcp_bbr) — otherwise they are omitted with a comment saying why (an unavailable
# congestion-control value would make `sysctl --system` error).
#
# Activation (systemctl daemon-reload && systemctl restart lsws; sysctl --system)
# is the OPERATOR's step — we only log the reminder, live-only, and NEVER auto-run
# those (guarded behind empty LSO_FS_ROOT + not DRY_RUN); their absence never fails
# the feature. Backup/rollback of both files rides the existing sysctl/systemd
# drop-in coverage in litespeed-optimizer-lib/backup.sh.
################################################################################

# Owned-file paths (through _lso_fs so LSO_FS_ROOT fixtures work).
_ol_systemd_file() { _lso_fs /etc/systemd/system/lsws.service.d/override.conf; }
_ol_sysctl_file()  { _lso_fs /etc/sysctl.d/99-litespeed.conf; }

# True when <file> already EXISTS but was NOT written by us (lacks the managed marker) —
# i.e. an operator-owned file we must refuse to clobber. Our own prior files DO carry the
# marker, so idempotent re-apply is allowed. Returns 1 when the file is absent or marked.
_ol_unmanaged_exists() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -q "Managed by litespeed-optimizer" "$file" 2>/dev/null && return 1
    return 0
}

# Write a whole owned file atomically (DRY_RUN-aware). Mirrors modsec's _ms_write_file:
# secure_mktemp + copy_file_permissions + atomic mv + "[DRY RUN] Would write ..." log.
_ol_write_file() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write ${file#${LSO_FS_ROOT:-}}"
        cat >/dev/null
        return 0
    fi
    mkdir -p "$dir" || { log_warn "os-limits: cannot create ${dir}"; return 1; }
    local tmp
    tmp=$(secure_mktemp "${dir}/.lso-oslimits.XXXXXX") || return 1
    # errexit is OFF inside `if feature_apply ...`, so a silent cat/mv failure would
    # otherwise skip rollback — propagate it explicitly (mirrors mariadb's _mdb_write_file).
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    log_info "Wrote ${file#${LSO_FS_ROOT:-}}"
}

# True when the kernel offers BBR congestion control. Detection is PROC-ONLY: read the
# ACTIVE algorithm list at /proc/sys/net/ipv4/tcp_available_congestion_control (through
# _lso_fs, so live reads real /proc when LSO_FS_ROOT is empty and a fixture can seed it)
# and match 'bbr' as a whole word. We deliberately do NOT probe module loadability:
# `modprobe -n -q tcp_bbr` only proves the module COULD load, not that bbr is in the
# ACTIVE list — writing tcp_congestion_control=bbr while the module is unloaded would make
# the operator's `sysctl --system` error. Returns 1 when the proc file is unreadable or
# lacks bbr.
_ol_bbr_available() {
    local cc_file
    cc_file="$(_lso_fs /proc/sys/net/ipv4/tcp_available_congestion_control)"
    [ -r "$cc_file" ] || return 1
    grep -qw bbr "$cc_file" 2>/dev/null
}

# systemd drop-in: raise the LiteSpeed unit's file-descriptor limit. LimitNOFILE is
# a FIXED 65535 (not tier-scaled).
_ol_write_systemd() {
    _ol_write_file "$(_ol_systemd_file)" <<'EOF'
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Raise the LiteSpeed service file-descriptor limit so it can hold more concurrent
# connections/sockets. Apply with: systemctl daemon-reload && systemctl restart lsws
[Service]
LimitNOFILE=65535
EOF
}

# sysctl drop-in: conservative network + VM tuning (FIXED values). BBR + fq lines are
# emitted only when the kernel offers BBR — otherwise omitted with a comment.
_ol_write_sysctl() {
    local bbr_block
    if _ol_bbr_available; then
        bbr_block="# BBR congestion control (tcp_bbr) is available — pair it with the fq qdisc for
# lower latency and higher throughput under load.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr"
        log_info "os-limits: BBR congestion control available — enabling net.core.default_qdisc=fq + tcp_congestion_control=bbr"
    else
        bbr_block="# BBR congestion control (tcp_bbr) is NOT available on this kernel — omitting
# net.core.default_qdisc=fq and net.ipv4.tcp_congestion_control=bbr (setting an
# unavailable algorithm would make 'sysctl --system' error). Load the module
# (modprobe tcp_bbr) and re-run --os-limits to enable them."
        log_info "os-limits: BBR not available — omitting the bbr/fq lines (see the drop-in comment for why)"
    fi
    _ol_write_file "$(_ol_sysctl_file)" <<EOF
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Conservative kernel network + VM tuning so LiteSpeed can accept more concurrent
# connections. Apply with: sysctl --system
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
vm.swappiness=10
${bbr_block}
EOF
}

feature_apply_custom_os_limits() {
    # Opt-in gate: never touch OS config unless explicitly asked.
    if [ "${LSO_OS_LIMITS:-}" != "1" ]; then
        log_info "os-limits: not enabled — pass --os-limits to raise OS connection limits (systemd LimitNOFILE=65535 + sysctl tuning); OPT-IN, default-off"
        return 0
    fi

    # Panel-managed hosts: the operator may not own systemd/sysctl (the panel
    # regenerates units / manages the kernel), so writing here could be clobbered or
    # be out of scope. Manual-only, mirroring modsec/recaptcha. (Enterprise is NOT
    # restricted here — os-limits is OS-level, not httpd_config.xml.)
    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        log_warn "os-limits: ${LSO_PANEL} manages the OS/service config — OS limits are manual-only here."
        log_info "  Set them by hand: a systemd drop-in with [Service] LimitNOFILE=65535 for the LiteSpeed unit,"
        log_info "  plus /etc/sysctl.d tuning (somaxconn 4096, tcp_max_syn_backlog 8192, fin_timeout 15, tw_reuse 1, swappiness 10)."
        return 0
    fi

    # Ownership guard (H1): refuse to overwrite an operator's own config at either target
    # path. Our own prior files carry the managed marker, so idempotent re-apply is fine.
    # This is a READ-ONLY check — kept active even under DRY_RUN so a dry run surfaces the
    # conflict — and fixture-safe (the *_file helpers return _lso_fs-prefixed paths).
    local _ol_sysd_target _ol_sysctl_target
    _ol_sysd_target="$(_ol_systemd_file)"
    _ol_sysctl_target="$(_ol_sysctl_file)"
    if _ol_unmanaged_exists "$_ol_sysd_target"; then
        log_error "os-limits: refusing to overwrite ${_ol_sysd_target#${LSO_FS_ROOT:-}} — it exists WITHOUT our '# Managed by litespeed-optimizer' marker (operator-owned). Move/remove that file or add the marker, then re-run --os-limits."
        return 1
    fi
    if _ol_unmanaged_exists "$_ol_sysctl_target"; then
        log_error "os-limits: refusing to overwrite ${_ol_sysctl_target#${LSO_FS_ROOT:-}} — it exists WITHOUT our '# Managed by litespeed-optimizer' marker (operator-owned). Move/remove that file or add the marker, then re-run --os-limits."
        return 1
    fi

    _ol_write_systemd || return 1
    _ol_write_sysctl || return 1

    log_success "os-limits: wrote systemd LimitNOFILE=65535 + sysctl network/VM tuning (conservative, fixed values)"

    # Live-only activation reminder. We NEVER auto-run daemon-reload / restart / sysctl
    # (the operator picks the window); their absence must never fail the feature.
    if [ -z "${LSO_FS_ROOT:-}" ] && [ "${DRY_RUN:-false}" != true ]; then
        log_info "os-limits: apply the changes with: systemctl daemon-reload && systemctl restart lsws && sysctl --system"
    fi
}

# Detected iff BOTH owned files exist AND carry our managed marker (so a third-party
# file at the same path is never mis-credited to this feature).
feature_detect_custom_os_limits() {
    local sysd sysctl_f
    sysd="$(_ol_systemd_file)"
    sysctl_f="$(_ol_sysctl_file)"
    [ -f "$sysd" ] && grep -q "Managed by litespeed-optimizer" "$sysd" 2>/dev/null || return 1
    [ -f "$sysctl_f" ] && grep -q "Managed by litespeed-optimizer" "$sysctl_f" 2>/dev/null || return 1
    grep -qE '^LimitNOFILE=65535' "$sysd" 2>/dev/null || return 1
    grep -qE '^net\.core\.somaxconn=4096' "$sysctl_f" 2>/dev/null || return 1
    return 0
}

FEATURE_ID="os-limits"
FEATURE_DISPLAY="OS connection limits (systemd LimitNOFILE + sysctl tuning)"
FEATURE_DETECT_PATTERN="LimitNOFILE=65535"
FEATURE_SCOPE="global"
FEATURE_ALIASES="oslimits"
feature_register
