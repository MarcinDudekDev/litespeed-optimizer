#!/bin/bash
################################################################################
# optimizer.sh - Feature Application Workflow
################################################################################
# Resolves the profile to a feature list, then runs feature_apply for each
# (custom apply functions defined in lib/features/*). File edits inside the
# applies are dry-run aware; the entrypoint handles backup before and the
# verified restart-or-rollback after.
################################################################################

# Canonical apply order per profile (security/redis/mariadb/os land in Phase 3.5/4)
PROFILE_FEATURES_GENERIC="server-tuning lsapi-tuning opcache security"
PROFILE_FEATURES_WORDPRESS="server-tuning lsapi-tuning opcache lscache lscwp security"
PROFILE_FEATURES_WOOCOMMERCE="server-tuning lsapi-tuning opcache lscache lscwp woocommerce security"

# Resolve profile name -> feature list. "auto": woocommerce when an active Woo
# install is found, wordpress when WP sites exist, generic otherwise.
# NOTE: called via $(...) — never log to stdout from here
resolve_profile_features() {
    local profile="${1:-auto}"

    if [ "$profile" = "auto" ]; then
        if [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ]; then
            profile="wordpress"
            if type -t _lscwp_have_wpcli &>/dev/null && _lscwp_have_wpcli; then
                local docroot
                for docroot in "${LSO_WP_SITES[@]}"; do
                    if lso_wp "$docroot" plugin is-active woocommerce >/dev/null 2>&1; then
                        profile="woocommerce"
                        break
                    fi
                done
            fi
        else
            profile="generic"
        fi
        # (runs in $(...): per-site profile choice re-resolves the same way
        # inside _lscwp_profile_for, so the outcome stays consistent)
        echo "Profile auto-resolved to: $profile" >> "${LOG_FILE:-/dev/null}"
    fi

    case "$profile" in
        generic)     echo "$PROFILE_FEATURES_GENERIC" ;;
        wordpress)   echo "$PROFILE_FEATURES_WORDPRESS" ;;
        woocommerce) echo "$PROFILE_FEATURES_WOOCOMMERCE" ;;
        *)           echo "$PROFILE_FEATURES_GENERIC" ;;
    esac
}

# apply_optimizations <site> <specific_feature> <exclude_feature> <profile>
apply_optimizations() {
    local target_site="${1:-}"
    local specific="${2:-}"
    local exclude="${3:-}"
    local profile="${4:-auto}"

    # Environment must be detected (entrypoint check may not have run detect)
    if [ -z "${LSO_EDITION:-}" ]; then
        if ! detect_environment; then
            log_error "No LiteSpeed installation found — nothing to optimize"
            return 1
        fi
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Preview mode — no files will be modified"
    fi
    log_info "Target: ${LSO_EDITION} (${LSO_PANEL}) at ${LSO_LSWS_ROOT}"

    # Panel policy: panels that regenerate or own the server config get
    # server-config features as manual-only (we'd otherwise fight the panel).
    # _lso_panel_restricted (detect-env.sh) is the single source of truth.
    local panel_restricted=false
    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        panel_restricted=true
        log_warn "${LSO_PANEL}: server config writes are manual-only (panel regenerates/owns configs)"
        log_warn "Applying opcache/lscwp/woocommerce only; server-tuning/lsapi/lscache + security throttling steps will be printed for manual application"
    fi

    # Build the feature list
    local features=""
    if [ -n "$specific" ]; then
        local fid
        fid=$(feature_get_by_alias "$specific" 2>/dev/null) || fid=""
        if [ -z "$fid" ]; then
            log_error "Feature not available: $specific (registered: $(feature_list | tr '\n' ' '))"
            return 1
        fi
        features="$fid"
    else
        features=$(resolve_profile_features "$profile")
    fi

    local exclude_id=""
    if [ -n "$exclude" ]; then
        exclude_id=$(feature_get_by_alias "$exclude" 2>/dev/null) || exclude_id=""
    fi

    local applied=0 failed=0 skipped=0
    local fid

    # Atomic SERVER-CONFIG edits: every confedit (ols_set/ols_set_env) write is
    # staged to a per-file temp and committed together at the end, so a broken
    # half-applied server config can never reach disk (the EXIT trap also rolls
    # back on an abort/crash).
    #
    # Rollback is scoped to CONFIG failures, not every feature failure: if a
    # feature stages main-config edits and then fails mid-write, its partial edit
    # is unsafe -> roll back the whole transaction and abort. But a feature that
    # writes NO main config (LSCWP/Woo via wp-cli, opcache .ini, per-site
    # .htaccess) failing must NOT discard the already-valid server config staged
    # by earlier features (those side effects are non-transactional and aren't
    # undone anyway) — its failure is recorded and the run continues; the staged
    # config still commits. Skipped under DRY_RUN and when the engine isn't loaded.
    local _txn_active=false
    if [ "${DRY_RUN:-false}" != true ] && type -t transaction_start >/dev/null 2>&1; then
        transaction_start
        _txn_active=true
    fi

    for fid in $features; do
        if [ -n "$exclude_id" ] && [ "$fid" = "$exclude_id" ]; then
            log_info "Skipping (excluded): $fid"
            skipped=$((skipped + 1))
            continue
        fi
        if ! feature_exists "$fid"; then
            log_warn "Skipping (not registered yet): $fid"
            skipped=$((skipped + 1))
            continue
        fi
        # Panel policy: on DA/RunCloud only non-server-config features apply
        if [ "$panel_restricted" = true ]; then
            case "$fid" in
                server-tuning|lsapi-tuning|lscache)
                    log_warn "Skipping $fid on ${LSO_PANEL} — apply manually via panel:"
                    case "$fid" in
                        server-tuning) _st_print_recommendations 2>/dev/null || true ;;
                        lsapi-tuning)  log_info "  PHP children target: $(_lsapi_children 2>/dev/null || echo '?')" ;;
                    esac
                    skipped=$((skipped + 1))
                    continue
                    ;;
            esac
        fi

        local display
        display=$(feature_get "$fid" "display" 2>/dev/null)
        [ -z "$display" ] && display="$fid"
        log_info "Applying: $display"

        # Snapshot per-feature write + write-error counters. (A file-count delta
        # can't attribute writes — every server-config feature edits the same
        # httpd_config and dedups onto one staged temp; the counters rise per edit.)
        local _writes_before=0 _werrs_before=0
        if [ "$_txn_active" = true ]; then
            _writes_before=${TRANSACTION_WRITES:-0}
            _werrs_before=${TRANSACTION_WRITE_ERRORS:-0}
        fi

        local _feat_ok=true
        feature_apply "$fid" "$target_site" || _feat_ok=false

        # A confedit write can FAIL while the feature still returns success — errexit
        # is off inside this `if`/`||` context, so a feature may not propagate it.
        # Detect it directly via the write-error counter so partial config can't commit.
        local _cfg_write_failed=false
        if [ "$_txn_active" = true ] && [ "${TRANSACTION_WRITE_ERRORS:-0}" -gt "$_werrs_before" ]; then
            _cfg_write_failed=true
        fi

        if [ "$_feat_ok" = true ] && [ "$_cfg_write_failed" = false ]; then
            applied=$((applied + 1))
            log_success "$display done"
        else
            failed=$((failed + 1))
            if [ "$_cfg_write_failed" = true ]; then
                log_error "$display: a server-config write FAILED"
            else
                log_error "$display FAILED"
            fi
            # Roll back + abort only when this feature TOUCHED the server config —
            # either a write physically failed, or the feature failed after writing
            # config (its partial/guard-rejected config is unsafe). A non-config
            # failure (no staged writes) keeps earlier features' valid config, which
            # still commits below.
            if [ "$_txn_active" = true ] && \
               { [ "$_cfg_write_failed" = true ] || [ "${TRANSACTION_WRITES:-0}" -gt "$_writes_before" ]; }; then
                log_error "Rolling back staged server config ($display) — config left unchanged."
                transaction_rollback
                _txn_active=false
                break
            fi
        fi
    done

    # Commit the staged server-config edits: control reaches here only when no
    # config-writing feature failed mid-write (those abort + roll back above), so
    # every staged edit is from a feature that completed its config writes.
    if [ "$_txn_active" = true ]; then
        transaction_commit
        _txn_active=false
    fi

    echo ""
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] ${applied} feature(s) previewed, ${skipped} skipped"
    else
        log_info "${applied} applied, ${failed} failed, ${skipped} skipped"
    fi

    [ "$failed" -eq 0 ]
}
