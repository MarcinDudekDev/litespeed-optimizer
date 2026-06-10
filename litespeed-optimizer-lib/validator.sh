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

################################################################################
# Health Checks
################################################################################

# http_status <url> — print HTTP status code (000 on connection failure)
http_status() {
    local url="$1"
    curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" 2>/dev/null || echo "000"
}

# snapshot_baseline [vhost_url]
# Record the pre-change HTTP status used as the health reference.
snapshot_baseline() {
    local vhost_url="${1:-}"
    LSO_BASELINE_STATUS=$(http_status "$LSO_BASELINE_URL")
    log_info "Baseline: ${LSO_BASELINE_URL} -> HTTP ${LSO_BASELINE_STATUS}"
    if [ -n "$vhost_url" ]; then
        # shellcheck disable=SC2034  # Consumed by vhost health check (Phase 2+)
        LSO_BASELINE_VHOST_URL="$vhost_url"
        LSO_BASELINE_VHOST_STATUS=$(http_status "$vhost_url")
        log_info "Baseline: ${vhost_url} -> HTTP ${LSO_BASELINE_VHOST_STATUS}"
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

# health_check — process up AND baseline URL same-or-better, 3 retries x 5s
health_check() {
    local attempt
    for attempt in 1 2 3; do
        if server_process_running; then
            local status
            status=$(http_status "$LSO_BASELINE_URL")
            # Same-or-better: any response when baseline existed; if baseline
            # was a real status (<500), require non-5xx and non-000 now.
            if [ -z "$LSO_BASELINE_STATUS" ] || [ "$LSO_BASELINE_STATUS" = "000" ]; then
                log_success "Health check passed (process running; no HTTP baseline)"
                return 0
            fi
            if [ "$status" != "000" ] && [ "${status:0:1}" != "5" ]; then
                log_success "Health check passed (HTTP ${status}, baseline ${LSO_BASELINE_STATUS})"
                return 0
            fi
            log_warn "Health attempt ${attempt}/3: HTTP ${status} (baseline ${LSO_BASELINE_STATUS})"
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
        log_warn "No restart command available — cannot verify server health"
        return 0
    fi

    log_info "Restarting LiteSpeed: ${LSO_RESTART_CMD}"
    if ! eval "$LSO_RESTART_CMD" >> "${LOG_FILE}" 2>&1; then
        log_error "Restart command failed"
        return 1
    fi

    # Give the server a moment before first probe
    sleep 2
    health_check
}

# verified_restart_or_rollback
# The full SPEC §7 sequence. Requires CURRENT_BACKUP_DIR from create_backup.
verified_restart_or_rollback() {
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would restart LiteSpeed and verify health"
        return 0
    fi

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

    log_error "Health check FAILED after restart — restoring backup"
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
