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

    # DirectAdmin/RunCloud panel policy: server-config features are manual-only
    local panel_restricted=false
    case "${LSO_PANEL:-}" in
        directadmin|runcloud)
            panel_restricted=true
            log_warn "${LSO_PANEL}: server config writes are manual-only (panel regenerates configs)"
            log_warn "Applying opcache/lscwp/woocommerce/security only; server-tuning/lsapi/lscache steps will be printed for manual application"
            ;;
    esac

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

    # Atomic config edits: stage every confedit (ols_set/ols_set_env) write to a
    # per-file temp and commit them all at once only if EVERY feature succeeds.
    # A mid-run feature failure rolls the staged config edits back, so a broken
    # half-applied server config can never reach disk (the EXIT trap also rolls
    # back on an abort/crash). NOTE: this covers the main server config only —
    # wp-cli (LSCWP/Woo) and per-site .htaccess writes are not transactional, so
    # side effects from features that already ran are not undone. Skipped under
    # DRY_RUN (no real writes) and when the engine isn't loaded (subset tests).
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

        if feature_apply "$fid" "$target_site"; then
            applied=$((applied + 1))
            log_success "$display done"
        else
            failed=$((failed + 1))
            log_error "$display FAILED"
            # Atomic optimize: abort the run and discard ALL staged config edits
            # so the live server config is left exactly as it was found.
            if [ "$_txn_active" = true ]; then
                log_error "Rolling back staged config edits (atomic optimize) — server config left unchanged."
                transaction_rollback
                _txn_active=false
                break
            fi
        fi
    done

    # Commit the staged config edits onto the live files — but ONLY when every
    # feature succeeded. (On failure we already rolled back and broke above.)
    if [ "$_txn_active" = true ]; then
        if [ "$failed" -eq 0 ]; then
            transaction_commit
        else
            transaction_rollback
        fi
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
