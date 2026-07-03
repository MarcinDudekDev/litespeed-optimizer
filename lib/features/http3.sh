#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/http3.sh - HTTP/3 (QUIC) enablement on OpenLiteSpeed
################################################################################
# OPT-IN (--http3), default-off, NOT in any profile. Flips a single server-level
# tuning key so LiteSpeed advertises and serves HTTP/3 (QUIC over UDP/443).
#
# On OpenLiteSpeed 1.9.0, HTTP/3 / QUIC is controlled by `quicEnable 1` inside the
# SERVER-LEVEL `tuning { }` block of httpd_config.conf (LIVE-verified — it is NOT
# an `enableQuic` key on a listener block). This is a safe single-key edit into an
# existing simple block, the same path server-tuning / lsapi-tuning use; the
# `tuning` block is addressed by name exactly like `extprocessor lsphp` is.
#
# LSWS Enterprise's httpd_config.xml is READ-ONLY for this tool, so on Enterprise
# this feature is manual-only (enable QUIC via the WebAdmin console). On panel-
# managed hosts (DirectAdmin/RunCloud/Plesk/…), where the panel owns/regenerates
# the server config, it is manual-only too (mirrors modsec/recaptcha/os-limits).
#
# We NEVER touch a firewall — HTTP/3 needs UDP/443 open, so we ADVISE the exact
# command for the detected firewall (and, for CSF, warn about UDPFLOOD) but run
# nothing. A live curl probe (guarded behind empty LSO_FS_ROOT + not DRY_RUN) only
# notes the verification command when curl advertises HTTP3; a missing/old curl
# never fails the feature. Activation (a LiteSpeed restart) is the OPERATOR's step
# and rides the existing backup + restart-or-rollback chain via lso_conf_set.
################################################################################

feature_apply_custom_http3() {
    # Opt-in gate: never touch server config unless explicitly asked.
    if [ "${LSO_HTTP3:-}" != "1" ]; then
        log_info "http3: not enabled — pass --http3 to enable HTTP/3 (QUIC) (tuning quicEnable 1 on OLS); OPT-IN, default-off"
        return 0
    fi

    # Enterprise: httpd_config.xml is READ-ONLY for this tool, so QUIC must be
    # enabled by hand via the WebAdmin console. Manual-only (mirrors modsec).
    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        log_warn "http3: Enterprise manages server config in httpd_config.xml (read-only for this tool) — HTTP/3 is manual-only here."
        log_info "  Enable via WebAdmin console > Server Configuration > Tuning > Enable QUIC (then ensure UDP/443 is open)."
        return 0
    fi

    # Panel-managed hosts: the panel owns/regenerates the server config, so writing
    # here could be clobbered or be out of scope. Manual-only, mirroring os-limits/modsec.
    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        log_warn "http3: ${LSO_PANEL} manages server config — HTTP/3 is manual-only here."
        log_info "  Enable QUIC in the tuning{} block via the panel/WebAdmin (Server Configuration > Tuning > Enable QUIC), then open UDP/443."
        return 0
    fi

    # With --http3 explicitly requested on OLS, a missing/unreadable main config is a
    # hard failure (the requested change cannot be staged) — return 1 so the optimize
    # loop does not report http3 as applied (mirrors recaptcha, not the "nothing to do"
    # no-op of os-limits/mariadb which have a legitimate absent-target case).
    local conf="${LSO_MAIN_CONF:-}"
    if [ -z "$conf" ] || [ ! -f "$conf" ]; then
        log_error "http3: main config (LSO_MAIN_CONF) not found — cannot enable HTTP/3"
        return 1
    fi

    # Read the current tuning quicEnable value. Already-on -> idempotent no-op; else
    # flip it on (transactional) and verify the staged write (mirrors recaptcha).
    local q
    q=$(ols_get "$conf" tuning quicEnable 2>/dev/null || true)
    if [ "$q" = "1" ]; then
        log_success "http3: HTTP/3 (QUIC) already enabled (tuning quicEnable=1)"
    else
        lso_conf_set "$conf" tuning quicEnable 1 || return 1
        if [ "${DRY_RUN:-false}" = true ]; then
            # DRY_RUN: lso_conf_set was a no-op ([DRY RUN] Would set ...), so the live
            # file is unchanged — skip the post-write re-read (it would falsely "not
            # confirm"). Mirrors recaptcha, which skips its verify under DRY_RUN.
            log_info "http3: [DRY RUN] would enable HTTP/3 (QUIC) (tuning quicEnable=1)"
        else
            # Post-write verification (reads the staged temp under an active transaction).
            local q_verify
            q_verify=$(ols_get "$conf" tuning quicEnable 2>/dev/null || true)
            if [ "$q_verify" = "1" ]; then
                log_success "http3: HTTP/3 (QUIC) enabled (tuning quicEnable=1)"
            else
                # Wrote but the read-back did not confirm — fail so the transaction rolls
                # back rather than committing/restarting on an unverified change (mirrors
                # recaptcha's return-1-on-mismatch guard).
                log_error "http3: staged tuning quicEnable but the re-read did not confirm it (found '${q_verify}') — QUIC NOT enabled"
                return 1
            fi
        fi
    fi

    # Firewall advice (ADVISE-ONLY — we never run anything). HTTP/3 rides UDP/443.
    case "${LSO_FIREWALL:-none}" in
        ufw)       log_info "http3: HTTP/3 needs UDP/443 open: ufw allow 443/udp" ;;
        csf)       log_warn "http3: CSF — ensure UDPFLOOD=0 in /etc/csf/csf.conf or QUIC UDP/443 is dropped; edit it yourself (this tool never touches csf.conf)" ;;
        firewalld) log_info "http3: HTTP/3 needs UDP/443: firewall-cmd --add-port=443/udp --permanent && firewall-cmd --reload" ;;
        *)         log_info "http3: ensure UDP/443 is open for HTTP/3" ;;
    esac

    # Live-only verification hint. Only note the curl command when curl advertises
    # HTTP3 (its Features line lists it as "HTTP3"); a missing/old curl never fails
    # the feature — we just skip the hint. There is no domain arg here, so we only
    # advise the command, never hammer a URL.
    if [ -z "${LSO_FS_ROOT:-}" ] && [ "${DRY_RUN:-false}" != true ]; then
        if curl --version 2>/dev/null | grep -qiw HTTP3; then
            log_info "http3: after restarting LiteSpeed, verify with: curl --http3 -I https://<domain>"
        else
            log_info "http3: this curl lacks --http3 (no HTTP3 in its Features line) — skipping the live verification hint"
        fi
    fi
}

# Detected iff (OLS only) the server-level tuning block has quicEnable=1. QUIC-on is
# the desired end-state regardless of who set it (no owned marker), matching
# lsapi-tuning's directive-value detection.
feature_detect_custom_http3() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"
    [ -f "$config_file" ] || return 1
    [ "${LSO_EDITION:-}" = "enterprise" ] && return 1
    [ "$(ols_get "$config_file" tuning quicEnable 2>/dev/null)" = "1" ]
}

FEATURE_ID="http3"
FEATURE_DISPLAY="HTTP/3 (QUIC) enablement"
FEATURE_DETECT_PATTERN="quicEnable"
FEATURE_SCOPE="global"
FEATURE_ALIASES="quic"
feature_register
