#!/bin/bash
################################################################################
# detector.sh - Feature Detection Loop
################################################################################
# Loops over the registry (lib/registry.sh) and reports which optimizations
# are applied. Feature modules register themselves in Phase 2+; with an empty
# registry this reports the environment and notes that no features exist yet.
################################################################################

# detect_all_features [config_file] [site]
# Prints "id|display|applied" per registered feature.
detect_all_features() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"
    local site="${2:-}"

    if ! type -t feature_list &>/dev/null; then
        return 0
    fi

    local fid
    while IFS= read -r fid; do
        [ -z "$fid" ] && continue
        local display applied="no"
        display=$(feature_get "$fid" "display" 2>/dev/null)
        [ -z "$display" ] && display="$fid"
        if [ -n "$config_file" ] && feature_detect "$fid" "$config_file" "$site" 2>/dev/null; then
            applied="yes"
        fi
        echo "${fid}|${display}|${applied}"
    done < <(feature_list)
}

# show_status [site] — human-readable applied/missing list
show_status() {
    local site="${1:-}"

    if [ -z "${LSO_EDITION:-}" ]; then
        log_error "No LiteSpeed installation detected"
        log_info "Run 'litespeed-optimizer detect' for details"
        return 1
    fi

    echo ""
    echo "Target: ${LSO_EDITION} (${LSO_PANEL}) at ${LSO_LSWS_ROOT}"
    echo ""

    local lines
    lines=$(detect_all_features "${LSO_MAIN_CONF:-}" "$site")

    if [ -z "$lines" ]; then
        log_info "No optimization features registered yet (feature modules ship in Phase 2)."
        log_info "Available now: detect, check, backup (via optimize), rollback."
        return 0
    fi

    local applied_count=0
    local missing_count=0
    while IFS='|' read -r fid display applied; do
        [ -z "$fid" ] && continue
        if [ "$applied" = "yes" ]; then
            log_success "  [applied] $display"
            applied_count=$((applied_count + 1))
        else
            log_info "  [missing] $display"
            missing_count=$((missing_count + 1))
        fi
    done <<< "$lines"

    echo ""
    log_info "${applied_count} applied, ${missing_count} not applied"
}
