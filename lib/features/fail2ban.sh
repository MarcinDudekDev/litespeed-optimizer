#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/fail2ban.sh - fail2ban brute-force / scanner jails (LIVE-phase Item 1)
################################################################################
# OPT-IN, default-off, and STAGED. Two flags:
#   --fail2ban          deploy OLS-specific filters + jails DISABLED (enabled=false),
#                       plus an fail2ban-regex dry-run. Nothing bans yet.
#   --fail2ban-enable   arm the jails (enabled=true). Refuses (hard abort) unless the
#                       access log shows the REAL client IP, so we never firewall a
#                       CDN edge and take the store offline.
#
# Everything that talks to a live daemon (package check, fail2ban-client -t,
# fail2ban-regex, reload) sits behind the fixture/dry-run guard so tests never
# touch a real system. All absolute paths route through _lso_fs. The fail2ban
# config dir is already covered by backup + rollback (backup.sh, Prereq B); a bad
# run's active bans are cleared by the guarded `unban --all` added there.
################################################################################

# Published Cloudflare ranges (canonical CIDRs). QUIC.cloud publishes ~individual
# IPs (volatile) — a representative sample is embedded so the containment engine is
# exercised offline; the authoritative QUIC.cloud list is refreshed at live-arm
# time. Sources: cloudflare.com/ips-v4, cloudflare.com/ips-v6, quic.cloud/ips.
_F2B_CDN_RANGES="\
173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 \
108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 \
162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 \
2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 \
2a06:98c0::/29 2c0f:f248::/32 \
102.221.36.98/32 103.106.229.82/32 104.244.77.37/32"

################################################################################
# CIDR containment (bash 3.2: integer math for v4, nibble+bit compare for v6)
################################################################################

# Dotted-quad -> 32-bit int on stdout; return 1 on a malformed address.
_f2b_ipv4_to_int() {
    local octet result=0
    local IFS=.
    # shellcheck disable=SC2086  # deliberate split of the dotted quad on IFS=.
    set -- $1
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
        result=$(( (result << 8) + octet ))
    done
    echo "$result"
}

_f2b_ipv4_in_cidr() {
    local ip="$1" cidr="$2"
    local net="${cidr%/*}" prefix="${cidr#*/}"
    [ "$cidr" = "$net" ] && prefix=32
    [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
    local ip_int net_int mask
    ip_int=$(_f2b_ipv4_to_int "$ip") || return 1
    net_int=$(_f2b_ipv4_to_int "$net") || return 1
    [ "$prefix" -eq 0 ] && return 0
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [ $(( ip_int & mask )) -eq $(( net_int & mask )) ]
}

# Expand any IPv6 form to 32 lowercase hex nibbles on stdout; return 1 on failure.
_f2b_ipv6_expand() {
    local ip="$1"
    if [[ "$ip" == *::* ]]; then
        local left="${ip%%::*}" right="${ip##*::}" present=0 colons zeros="" i
        if [ -n "$left" ]; then
            colons="${left//[^:]/}"; present=$(( ${#colons} + 1 ))
        fi
        if [ -n "$right" ]; then
            colons="${right//[^:]/}"; present=$(( present + ${#colons} + 1 ))
        fi
        local missing=$(( 8 - present ))
        [ "$missing" -lt 1 ] && return 1
        for (( i = 0; i < missing; i++ )); do zeros="${zeros}0:"; done
        [ -n "$left" ] && left="${left}:"
        ip="${left}${zeros}${right}"
        ip="${ip%:}"
    fi
    local out="" g rest="$ip" count=0
    while [ -n "$rest" ]; do
        if [ "${rest%%:*}" = "$rest" ]; then
            g="$rest"; rest=""
        else
            g="${rest%%:*}"; rest="${rest#*:}"
        fi
        [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        while [ "${#g}" -lt 4 ]; do g="0$g"; done
        out="$out$g"
        count=$(( count + 1 ))
    done
    [ "$count" -eq 8 ] || return 1
    printf '%s' "$out" | tr 'A-F' 'a-f'
}

_f2b_ipv6_in_cidr() {
    local ip="$1" cidr="$2"
    local net="${cidr%/*}" prefix="${cidr#*/}"
    [ "$cidr" = "$net" ] && prefix=128
    [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ] || return 1
    local ipx netx
    ipx=$(_f2b_ipv6_expand "$ip") || return 1
    netx=$(_f2b_ipv6_expand "$net") || return 1
    local full=$(( prefix / 4 )) rem=$(( prefix % 4 ))
    if [ "$full" -gt 0 ]; then
        [ "${ipx:0:full}" = "${netx:0:full}" ] || return 1
    fi
    if [ "$rem" -gt 0 ]; then
        local iv nv shift_by
        iv=$(( 16#${ipx:full:1} ))
        nv=$(( 16#${netx:full:1} ))
        shift_by=$(( 4 - rem ))
        [ $(( iv >> shift_by )) -eq $(( nv >> shift_by )) ] || return 1
    fi
    return 0
}

# True if <ip> is inside <cidr>. Dispatches on family; a family mismatch is false.
_f2b_cidr_contains() {
    local ip="$1" cidr="$2"
    if [[ "$ip" == *:* ]]; then
        [[ "$cidr" == *:* ]] || return 1
        _f2b_ipv6_in_cidr "$ip" "$cidr"
    else
        [[ "$cidr" == *:* ]] && return 1
        _f2b_ipv4_in_cidr "$ip" "$cidr"
    fi
}

# True if <ip> falls in ANY CIDR in the whitespace-separated <list>.
_f2b_ip_in_any() {
    local ip="$1" list="$2" cidr
    for cidr in $list; do
        _f2b_cidr_contains "$ip" "$cidr" && return 0
    done
    return 1
}

_f2b_is_ip() {
    if [[ "$1" == *:* ]]; then
        _f2b_ipv6_expand "$1" >/dev/null 2>&1
    else
        _f2b_ipv4_to_int "$1" >/dev/null 2>&1
    fi
}

################################################################################
# Real-IP guard — hard abort before arming host banning behind a CDN
################################################################################
# Parse the last N access-log lines (OLS default combined: client IP is field 1).
# If any logged IP is a CDN edge, the real client IP is NOT restored -> refuse to
# arm (banning would firewall the CDN). Fail-safe: unreadable log or no client IPs
# also refuses. Returns 0 only when real client IPs are confirmed.
_f2b_realip_guard() {
    # Strip the fixture prefix so we read the fixture copy, but report the real path.
    local log="${LSO_LSWS_ROOT}/logs/access.log"
    if [ ! -r "$log" ]; then
        log_error "fail2ban: cannot read the access log to verify the real client IP:"
        log_error "  ${log#${LSO_FS_ROOT:-}}"
        log_error "  Refusing to arm — confirm the log path and that OLS logs the real client IP."
        return 1
    fi

    local lines ip edge_found=0 valid=0 first_edge=""
    lines=$(tail -n 50 "$log" 2>/dev/null)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        ip="${line%% *}"
        _f2b_is_ip "$ip" || continue
        valid=$(( valid + 1 ))
        if _f2b_ip_in_any "$ip" "$_F2B_CDN_RANGES"; then
            edge_found=1
            [ -z "$first_edge" ] && first_edge="$ip"
        fi
    done <<EOF
$lines
EOF

    if [ "$edge_found" -eq 1 ]; then
        log_error "fail2ban: the access log shows a CDN edge IP (${first_edge}) as the client."
        log_error "  The real client IP is NOT restored — arming would firewall the CDN and take the store offline."
        log_error "  Restore the real IP first (OLS: set useIpInProxyHeader to trust the CDN's forwarded header"
        log_error "  for the CDN CIDRs), confirm it in the access log, then re-run with --fail2ban-enable."
        return 1
    fi
    if [ "$valid" -eq 0 ]; then
        log_error "fail2ban: no client IPs found in the access log — cannot confirm real-IP restoration; refusing to arm."
        return 1
    fi
    return 0
}

################################################################################
# Config writers (DRY_RUN-aware; whole files are ours, no marker block needed)
################################################################################

_f2b_dir() { _lso_fs /etc/fail2ban; }

# Write one filter file with the given failregex. OLS default access log is the
# Apache "combined" format: `<HOST> - - [date] "METHOD path proto" status ...`.
_f2b_write_filter() {
    local name="$1" failregex="$2"
    local dir file
    dir="$(_f2b_dir)/filter.d"
    file="${dir}/${name}.conf"

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write fail2ban filter ${file#${LSO_FS_ROOT:-}}"
        return 0
    fi

    mkdir -p "$dir" || { log_warn "fail2ban: cannot create ${dir} — skipping filter ${name}"; return 1; }
    local tmp
    tmp=$(secure_mktemp "${dir}/.lso-f2b.XXXXXX") || return 1
    {
        echo "# Managed by litespeed-optimizer — do not edit (regenerated on each run)."
        echo "# OLS default access log = Apache combined; <HOST> anchors the client IP."
        echo "[Definition]"
        echo "failregex = ${failregex}"
        echo "ignoreregex ="
    } > "$tmp"
    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
    log_info "Wrote fail2ban filter ${file#${LSO_FS_ROOT:-}}"
}

_f2b_write_filters() {
    # wp-login POST flood (brute force): repeated POSTs to the login endpoint.
    _f2b_write_filter "lso-wp-login" \
        '^<HOST> .*"POST /wp-login\.php[^"]* HTTP/[0-9.]+" (200|401|403)' || return 1
    # xmlrpc POST flood (amplification / brute force via system.multicall).
    _f2b_write_filter "lso-xmlrpc" \
        '^<HOST> .*"POST /xmlrpc\.php[^"]* HTTP/[0-9.]+" [0-9]+' || return 1
    # Repeated 4xx from one host = scanner probing for files/paths.
    _f2b_write_filter "lso-4xx-scan" \
        '^<HOST> .*"(GET|POST|HEAD) [^"]+ HTTP/[0-9.]+" 4[0-9][0-9]' || return 1
}

# Write jail.d/lso-jails.conf. <arm> ("1"/"0") sets enabled true/false. Thresholds
# loosen when perClientConnLimit throttling is already active (avoid double-jeopardy
# on the same offender). logpath/ignoreip carry REAL paths/IPs (fixture prefix
# stripped) so the file is valid on the live box.
_f2b_write_jail() {
    local arm="$1"
    local dir file logpath enabled ignoreip real_lsws
    dir="$(_f2b_dir)/jail.d"
    file="${dir}/lso-jails.conf"

    real_lsws="${LSO_LSWS_ROOT#${LSO_FS_ROOT:-}}"
    logpath="${real_lsws}/logs/access.log"

    enabled="false"
    [ "$arm" = "1" ] && enabled="true"

    # ignoreip: loopback + trusted allowlist (+ server IPs on a live box).
    local server_ips=""
    if [ -z "${LSO_FS_ROOT:-}" ] && command -v hostname >/dev/null 2>&1; then
        server_ips=$(hostname -I 2>/dev/null | tr -s ' ' | sed 's/ *$//')
    fi
    ignoreip="127.0.0.1/8 ::1"
    [ -n "$server_ips" ] && ignoreip="${ignoreip} ${server_ips}"
    [ -n "${LSO_TRUSTED_IPS:-}" ] && ignoreip="${ignoreip} ${LSO_TRUSTED_IPS}"

    # Looser thresholds when OLS per-client throttling already bans offenders.
    local login_retry=5 scan_retry=20
    if [ -n "${LSO_MAIN_CONF:-}" ] && grep -q "perClientConnLimit" "$LSO_MAIN_CONF" 2>/dev/null; then
        login_retry=8
        scan_retry=30
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write fail2ban jails (${file#${LSO_FS_ROOT:-}}) enabled=${enabled}"
        return 0
    fi

    mkdir -p "$dir" || { log_warn "fail2ban: cannot create ${dir} — skipping jails"; return 1; }
    local tmp
    tmp=$(secure_mktemp "${dir}/.lso-f2b.XXXXXX") || return 1
    {
        echo "# Managed by litespeed-optimizer — do not edit (regenerated on each run)."
        echo "[DEFAULT]"
        echo "ignoreip = ${ignoreip}"
        echo "backend = auto"
        echo ""
        echo "[lso-wp-login]"
        echo "enabled = ${enabled}"
        echo "filter = lso-wp-login"
        echo "logpath = ${logpath}"
        echo "port = http,https"
        echo "maxretry = ${login_retry}"
        echo "findtime = 300"
        echo "bantime = 3600"
        echo ""
        echo "[lso-xmlrpc]"
        echo "enabled = ${enabled}"
        echo "filter = lso-xmlrpc"
        echo "logpath = ${logpath}"
        echo "port = http,https"
        echo "maxretry = ${login_retry}"
        echo "findtime = 300"
        echo "bantime = 3600"
        echo ""
        echo "[lso-4xx-scan]"
        echo "enabled = ${enabled}"
        echo "filter = lso-4xx-scan"
        echo "logpath = ${logpath}"
        echo "port = http,https"
        echo "maxretry = ${scan_retry}"
        echo "findtime = 120"
        echo "bantime = 1800"
    } > "$tmp"
    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
    log_info "Wrote fail2ban jails ${file#${LSO_FS_ROOT:-}} (enabled=${enabled})"
}

################################################################################
# Live activation (skipped entirely in fixture / dry-run mode)
################################################################################
_f2b_live_activate() {
    if [ -n "${LSO_FS_ROOT:-}" ] || [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would run fail2ban-regex on the filters, 'fail2ban-client -t', then reload"
        return 0
    fi
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_warn "fail2ban is not installed — install it (e.g. apt-get install fail2ban), then re-run to activate"
        return 0
    fi

    local logpath="${LSO_LSWS_ROOT}/logs/access.log" f
    if command -v fail2ban-regex >/dev/null 2>&1 && [ -r "$logpath" ]; then
        for f in lso-wp-login lso-xmlrpc lso-4xx-scan; do
            if fail2ban-regex "$logpath" "$(_f2b_dir)/filter.d/${f}.conf" >/dev/null 2>&1; then
                log_info "fail2ban-regex OK: ${f}"
            else
                log_info "fail2ban-regex: no current matches for ${f} (fine if no such traffic yet)"
            fi
        done
    fi

    if ! fail2ban-client -t >/dev/null 2>&1; then
        log_error "fail2ban: config test (fail2ban-client -t) failed — removing the lso jail file to avoid a broken jail"
        rm -f "$(_f2b_dir)/jail.d/lso-jails.conf"
        fail2ban-client reload >/dev/null 2>&1 || true
        return 1
    fi
    if fail2ban-client reload >/dev/null 2>&1; then
        log_success "fail2ban reloaded"
    else
        log_warn "fail2ban config OK but reload failed — run 'fail2ban-client reload' manually"
    fi
}

################################################################################
# Public hooks
################################################################################
feature_apply_custom_fail2ban() {
    # Opt-in gate: never deploy fail2ban unless explicitly asked (--fail2ban).
    if [ "${LSO_FAIL2BAN:-}" != "1" ]; then
        log_info "fail2ban: not enabled — pass --fail2ban to deploy (jails ship disabled) or --fail2ban-enable to arm"
        return 0
    fi

    local arm=0
    if [ "${LSO_FAIL2BAN_ENABLE:-}" = "1" ]; then
        # Hard abort: do not arm host banning until the real client IP is confirmed.
        if ! _f2b_realip_guard; then
            log_error "fail2ban: aborting — real client IP not confirmed. No jail files written."
            return 1
        fi
        arm=1
    fi

    _f2b_write_filters || return 1
    _f2b_write_jail "$arm" || return 1

    if [ "$arm" -eq 1 ]; then
        log_success "fail2ban: jails ARMED (enabled=true)"
    else
        log_info "fail2ban: jails deployed DISABLED — review, then re-run with --fail2ban-enable to arm"
    fi

    _f2b_live_activate "$arm"
}

feature_detect_custom_fail2ban() {
    [ -f "$(_f2b_dir)/jail.d/lso-jails.conf" ]
}

FEATURE_ID="fail2ban"
FEATURE_DISPLAY="fail2ban (wp-login/xmlrpc/4xx jails, staged)"
FEATURE_DETECT_PATTERN="lso-jails"
FEATURE_SCOPE="global"
FEATURE_ALIASES="f2b"
feature_register
