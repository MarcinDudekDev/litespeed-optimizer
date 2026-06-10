#!/bin/bash
################################################################################
# core/templates.sh - Template Deployment Helpers
################################################################################
# Deploys *.tpl files from templates/ with @PLACEHOLDER@ substitution.
# Feature modules (Phase 2+) call template_render/template_deploy.
################################################################################

# template_render <template-path> [VAR=value ...]
# Render a template to stdout, replacing @VAR@ tokens with values.
template_render() {
    local template="$1"
    shift

    [ -f "$template" ] || { log_error "Template not found: $template"; return 1; }

    local sed_script=""
    local pair
    for pair in "$@"; do
        local var="${pair%%=*}"
        local val="${pair#*=}"
        # Escape sed special chars in replacement
        val=$(printf '%s' "$val" | sed 's/[&/\]/\\&/g')
        sed_script="${sed_script}s/@${var}@/${val}/g;"
    done

    if [ -n "$sed_script" ]; then
        sed "$sed_script" "$template"
    else
        cat "$template"
    fi
}

# template_deploy <template-path> <target-path> [VAR=value ...]
# Render a template to a target file (dry-run aware, atomic write).
template_deploy() {
    local template="$1"
    local target="$2"
    shift 2

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would deploy: $(basename "$template") -> $target"
        return 0
    fi

    local target_dir
    target_dir=$(dirname "$target")
    mkdir -p "$target_dir"

    local tmp
    tmp=$(secure_mktemp "${target_dir}/.lso-tpl.XXXXXX") || return 1

    if ! template_render "$template" "$@" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    if [ -f "$target" ]; then
        copy_file_permissions "$target" "$tmp" 2>/dev/null || true
        copy_file_ownership "$target" "$tmp" 2>/dev/null || true
    fi
    mv "$tmp" "$target"
    log_info "Deployed: $target"
}
