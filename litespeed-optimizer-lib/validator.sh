#!/bin/bash
################################################################################
# validator.sh - Config Validation + Verified Restart-or-Rollback
################################################################################
# OLS has no `nginx -t` equivalent — the restart IS the validation (SPEC §7):
#   1. snapshot baseline HTTP status of 127.0.0.1 (and one real vhost URL)
#   2. (file changes happen inside a transaction, see helpers.sh)
#   3. graceful restart via $LSO_RESTART_CMD
#   4. health check: lswsctrl status running AND pgrep lshttpd AND baseline
#      URL returns same-or-better status within 15s (3 retries)
#   5. failure => automatic restore from the just-made backup + restart +
#      re-health-check + exit 1 with log path
#
# Pre-checks (ols_lint) run before any live file is touched.
#
# Test hooks: LSO_SKIP_RESTART=1 skips the actual restart/health-check (used
# on fixture trees where no server exists).
################################################################################

# Baseline HTTP status captured before changes
LSO_BASELINE_STATUS=""
LSO_BASELINE_URL="http://127.0.0.1/"
# Optional real-vhost baseline (set by snapshot_baseline when a site URL is
# known) — catches a broken real vhost that the default 127.0.0.1 vhost hides.
LSO_BASELINE_VHOST_URL=""
LSO_BASELINE_VHOST_STATUS=""
# Optional WooCommerce smoke-gate baselines (parallel arrays; set by
# snapshot_baseline when the target site runs WooCommerce). These guard the
# cart/checkout/Store-API flows that a homepage health check is blind to — a new
# ModSec/CAPTCHA 403 on checkout returns 200 on the homepage but breaks orders.
LSO_BASELINE_WOO_URLS=()
LSO_BASELINE_WOO_STATUS=()
# Why the last restart attempt failed (for accurate rollback messaging)
LSO_RESTART_FAIL_REASON=""

################################################################################
# Health Checks
################################################################################

# http_status <url> — print HTTP status code (000 on connection failure)
http_status() {
    local url="$1"
    curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" 2>/dev/null || echo "000"
}

# snapshot_baseline [vhost_url] [woo_urls]
# Record the pre-change HTTP status used as the health reference. woo_urls is a
# space-separated list of full WooCommerce flow URLs (resolved by the caller via
# WooCommerce's own permalink helpers, so custom slugs like /kasse/ are handled);
# baselining them lets the post-restart gate catch a checkout that a later change
# (ModSec enforce, CAPTCHA) starts 403'ing.
snapshot_baseline() {
    local vhost_url="${1:-}" woo_urls="${2:-}"
    LSO_BASELINE_STATUS=$(http_status "$LSO_BASELINE_URL")
    log_info "Baseline: ${LSO_BASELINE_URL} -> HTTP ${LSO_BASELINE_STATUS}"
    if [ -n "$vhost_url" ]; then
        LSO_BASELINE_VHOST_URL="$vhost_url"
        LSO_BASELINE_VHOST_STATUS=$(http_status "$vhost_url")
        log_info "Baseline: ${vhost_url} -> HTTP ${LSO_BASELINE_VHOST_STATUS}"
    fi
    LSO_BASELINE_WOO_URLS=()
    LSO_BASELINE_WOO_STATUS=()
    if [ -n "$woo_urls" ]; then
        local u s
        # shellcheck disable=SC2086  # intentional split of the space-separated list
        for u in $woo_urls; do
            s=$(http_status "$u")
            LSO_BASELINE_WOO_URLS+=("$u")
            LSO_BASELINE_WOO_STATUS+=("$s")
            log_info "Baseline (woo): ${u} -> HTTP ${s}"
        done
    fi
}

# server_process_running — lswsctrl status + pgrep lshttpd
server_process_running() {
    local ctrl="${LSO_LSWS_ROOT:-/usr/local/lsws}/bin/lswsctrl"

    if [ -x "$ctrl" ]; then
        if ! "$ctrl" status 2>/dev/null | grep -qi "running"; then
            return 1
        fi
    fi

    if command -v pgrep &>/dev/null; then
        pgrep -f lshttpd >/dev/null 2>&1 || return 1
    fi

    return 0
}

# _health_url_ok <url> <baseline_status> — same-or-better check for one URL.
# A URL whose baseline was unusable (empty / 000) contributes no HTTP signal
# (the process check is then the only guarantee); a URL with a real baseline
# must now answer non-000 and non-5xx.
_health_url_ok() {
    local url="$1" baseline="$2" status
    if [ -z "$baseline" ] || [ "$baseline" = "000" ]; then
        return 0
    fi
    status=$(http_status "$url")
    if [ "$status" != "000" ] && [ "${status:0:1}" != "5" ]; then
        log_success "Health: ${url} -> HTTP ${status} (baseline ${baseline})"
        return 0
    fi
    log_warn "Health: ${url} -> HTTP ${status} (baseline ${baseline})"
    return 1
}

# _health_woo_url_ok <url> <baseline> — STRICTER than _health_url_ok: a Woo flow
# that worked at baseline (2xx/3xx) must still answer 2xx/3xx. A NEW 4xx (a
# ModSec/CAPTCHA 403 on checkout) is the exact failure the generic same-or-better
# check misses (it treats any non-5xx as "ok"). Flows already broken/blocked at
# baseline contribute no signal (we don't attribute a pre-existing 403 to us).
_health_woo_url_ok() {
    local url="$1" baseline="$2" status
    case "$baseline" in 2??|3??) ;; *) return 0 ;; esac
    status=$(http_status "$url")
    case "$status" in
        2??|3??)
            log_success "Woo smoke: ${url} -> HTTP ${status} (baseline ${baseline})"
            return 0 ;;
        *)
            log_warn "Woo smoke: ${url} -> HTTP ${status} (baseline ${baseline}) — checkout/cart/REST regression (ModSec/CAPTCHA 403?)"
            return 1 ;;
    esac
}

# _health_woo_all_ok — every baselined Woo flow still 2xx/3xx (no-op when none).
_health_woo_all_ok() {
    [ "${#LSO_BASELINE_WOO_URLS[@]}" -gt 0 ] || return 0
    local i
    for ((i=0; i<${#LSO_BASELINE_WOO_URLS[@]}; i++)); do
        _health_woo_url_ok "${LSO_BASELINE_WOO_URLS[$i]}" "${LSO_BASELINE_WOO_STATUS[$i]}" || return 1
    done
    return 0
}

# health_check — process up AND every baselined URL same-or-better AND (on a Woo
# site) cart/checkout/Store-API not newly 4xx/5xx. The real vhost (when known) is
# checked too, so a broken vhost the default 127.0.0.1 vhost would mask still
# fails the gate. 3 retries x 5s.
health_check() {
    local attempt
    for attempt in 1 2 3; do
        if server_process_running; then
            if _health_url_ok "$LSO_BASELINE_URL" "$LSO_BASELINE_STATUS" &&
               _health_url_ok "$LSO_BASELINE_VHOST_URL" "$LSO_BASELINE_VHOST_STATUS" &&
               _health_woo_all_ok; then
                log_success "Health check passed (process running; baselined URLs same-or-better; Woo flows still 2xx/3xx)"
                return 0
            fi
        else
            log_warn "Health attempt ${attempt}/3: server process not running"
        fi
        if [ "$attempt" -lt 3 ]; then
            sleep 5
        fi
    done
    return 1
}

################################################################################
# Verified Restart
################################################################################

# verified_restart — graceful restart + health check. No rollback.
# Returns: 0 healthy, 1 unhealthy
verified_restart() {
    if [ "${LSO_SKIP_RESTART:-0}" = "1" ] || [ -n "${LSO_FS_ROOT:-}" ]; then
        log_info "Restart skipped (fixture/test mode)"
        return 0
    fi

    if [ -z "${LSO_RESTART_CMD:-}" ]; then
        # Fail closed: we applied changes but cannot restart to activate/verify
        # them, so we must not report success. Caller rolls back. Set
        # LSO_SKIP_RESTART=1 to intentionally skip (handled above).
        LSO_RESTART_FAIL_REASON="no restart command available"
        log_error "No restart command available — cannot activate/verify changes"
        return 1
    fi

    # Run the restart command WITHOUT eval. Unquoted expansion word-splits
    # "cmd arg arg" into argv but treats any injected ; | & \$() \` as literal
    # arguments (which simply fail), closing the root-RCE vector eval opened.
    case "$LSO_RESTART_CMD" in
        *';'*|*'|'*|*'&'*|*'$('*|*'`'*|*'>'*|*'<'*)
            LSO_RESTART_FAIL_REASON="restart command rejected (shell metacharacters)"
            log_error "Refusing restart command with shell metacharacters: ${LSO_RESTART_CMD}"
            return 1 ;;
    esac
    log_info "Restarting LiteSpeed: ${LSO_RESTART_CMD}"
    # noglob so an unquoted * / ? / [ in the command can never pathname-expand;
    # combined with the metachar guard the word-split is purely "cmd arg arg".
    set -f
    # shellcheck disable=SC2086  # intentional word-split of a validated command
    if ! $LSO_RESTART_CMD >> "${LOG_FILE}" 2>&1; then
        set +f
        LSO_RESTART_FAIL_REASON="restart command failed"
        log_error "Restart command failed"
        return 1
    fi
    set +f

    # Give the server a moment before first probe
    sleep 2
    if health_check; then
        return 0
    fi
    LSO_RESTART_FAIL_REASON="health check did not pass after restart"
    return 1
}

# verified_restart_or_rollback
# The full SPEC §7 sequence. Requires CURRENT_BACKUP_DIR from create_backup.
verified_restart_or_rollback() {
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would restart LiteSpeed and verify health"
        return 0
    fi

    LSO_RESTART_FAIL_REASON=""

    # Pre-check: lint the OLS main config before risking a restart
    if [ "${LSO_EDITION:-}" = "ols" ] && [ -n "${LSO_MAIN_CONF:-}" ] && type -t ols_lint &>/dev/null; then
        if ! ols_lint "$LSO_MAIN_CONF"; then
            log_error "Config lint failed BEFORE restart — rolling back"
            _auto_restore_and_die
        fi
    fi

    if verified_restart; then
        return 0
    fi

    # Report the ACTUAL reason — the restart may never have run (empty command
    # or metacharacter refusal), so "health check failed" would mislead.
    log_error "Restart/health check failed (${LSO_RESTART_FAIL_REASON:-unknown}) — restoring backup"
    _auto_restore_and_die
}

# Internal: restore the just-made backup, restart, re-check, exit 1
_auto_restore_and_die() {
    if [ -n "${CURRENT_BACKUP_DIR:-}" ] && [ -d "$CURRENT_BACKUP_DIR" ]; then
        log_warn "Auto-restoring from: $CURRENT_BACKUP_DIR"
        restore_backup_files "$CURRENT_BACKUP_DIR"
        verify_restored_files "$CURRENT_BACKUP_DIR" || true

        if verified_restart; then
            log_success "Auto-restore succeeded — server healthy on previous config"
        else
            log_error "Server STILL unhealthy after restore — manual intervention required"
        fi
    else
        log_error "No backup available for auto-restore"
    fi

    log_error "Optimization aborted. Full log: ${LOG_FILE}"
    exit 1
}
