#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/lscwp.sh - LiteSpeed Cache Plugin Management (SPEC §6 lscwp)
################################################################################
# Per WP site: ensure LSCWP installed + activated, CVE version gate (>=6.5.1:
# CVE-2024-28000 privesc, CVE-2024-44000 debug-log takeover, CVE-2024-47374
# XSS), pre-change `litespeed-option export` backup, curated profile applied
# per-key via `litespeed-option set` (the documented/verified CLI surface;
# the export/import file format varies between LSCWP versions), hardening
# (debug off, .log access blocked via rewrite — OLS .htaccess only honors
# mod_rewrite, so no <FilesMatch>), then purge all.
#
# Profile option KEYS follow LSCWP 6.x naming but are UNTESTED against a live
# plugin until the Phase 3.5 Docker E2E — flagged in ROADMAP.
#
# Test hooks: LSO_WP_BIN overrides the wp binary (mock in tests).
################################################################################

LSCWP_MIN_VERSION="6.5.1"

# lso_wp <docroot> <args...> — wp-cli wrapper (root needs --allow-root)
lso_wp() {
    local docroot="$1"
    shift
    local wp_bin="${LSO_WP_BIN:-wp}"
    local extra=""
    [ "$(id -u)" -eq 0 ] && extra="--allow-root"
    # shellcheck disable=SC2086
    "$wp_bin" --path="$docroot" $extra "$@"
}

# version_ge <a> <b> — true if dotted version a >= b
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" = "$2" ]
}

# wp-cli available? (real binary or test override)
_lscwp_have_wpcli() {
    if [ -n "${LSO_WP_BIN:-}" ]; then
        [ -x "$LSO_WP_BIN" ]
    else
        command -v wp &>/dev/null
    fi
}

# Resolve which profile file to use for a site
# _lscwp_profile_for <docroot> -> prints template path
_lscwp_profile_for() {
    local docroot="$1"
    local profile="${PROFILE:-auto}"

    if [ "$profile" = "auto" ]; then
        if lso_wp "$docroot" plugin is-active woocommerce >/dev/null 2>&1; then
            profile="woocommerce"
        else
            profile="wordpress"
        fi
    fi
    echo "${TEMPLATE_DIR}/lscwp/profile-${profile}.txt"
}

# Render a profile with environment-derived placeholder values
# _lscwp_render_profile <docroot> <template> <out-file>
_lscwp_render_profile() {
    local docroot="$1" template="$2" out="$3"

    # Object cache wiring: only when Redis is actually present
    local object=0 obj_host=127.0.0.1 obj_port=6379
    if [ "${LSO_HAS_REDIS:-false}" = true ]; then
        object=1
        if [ -S /var/run/redis/redis.sock ]; then
            obj_host=/var/run/redis/redis.sock
            obj_port=0
        fi
    fi

    # ESI: Enterprise only (OLS has no ESI engine)
    local esi=0
    [ "${LSO_EDITION:-}" = "enterprise" ] && esi=1

    # cache-priv: only with ESI available AND >=4GB RAM (SYNTHESIS §5)
    local cache_priv=0
    if [ "$esi" = "1" ]; then
        local ram
        ram=$(sysinfo_ram_mb)
        [ "$ram" -ge 4096 ] && cache_priv=1
    fi

    # Crawler sitemap: Yoast/RankMath index if active, else WP core sitemap
    local siteurl sitemap
    siteurl=$(lso_wp "$docroot" option get siteurl 2>/dev/null) || siteurl=""
    [ -z "$siteurl" ] && siteurl="http://localhost"
    if lso_wp "$docroot" plugin is-active wordpress-seo >/dev/null 2>&1; then
        sitemap="${siteurl}/sitemap_index.xml"
    elif lso_wp "$docroot" plugin is-active seo-by-rank-math >/dev/null 2>&1; then
        sitemap="${siteurl}/sitemap_index.xml"
    else
        sitemap="${siteurl}/wp-sitemap.xml"
    fi

    template_render "$template" \
        "OBJECT=${object}" \
        "OBJECT_HOST=${obj_host}" \
        "OBJECT_PORT=${obj_port}" \
        "ESI=${esi}" \
        "CACHE_PRIV=${cache_priv}" \
        "SITEMAP=${sitemap}" > "$out"
}

# Apply rendered profile per-key: `wp litespeed-option set <key> <value>`
_lscwp_apply_profile() {
    local docroot="$1" rendered="$2"
    local line key value

    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        # Trim surrounding whitespace
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$key" ] && continue

        if [ "${DRY_RUN:-false}" = true ]; then
            log_info "[DRY RUN] Would set LSCWP option: ${key} = ${value}"
        else
            if lso_wp "$docroot" litespeed-option set "$key" "$value" >/dev/null 2>&1; then
                log_info "LSCWP: ${key} = ${value}"
            else
                log_warn "LSCWP: failed to set ${key} (plugin may not expose it)"
            fi
        fi
    done < "$rendered"
}

# Normalize ownership of optimizer/LSCWP-generated paths (issue #4).
# We run wp-cli with --allow-root, so files LSCWP creates (the object-cache.php
# drop-in, and wp-content/litespeed where minified CSS/JS land) end up owned by
# root. The LSPHP runtime then runs as the docroot owner and cannot write those
# assets, so they 404 and the site renders UNSTYLED while analyze still scores
# 100. Re-own the generated paths to the docroot owner so the runtime can write.
_lscwp_fix_ownership() {
    local docroot="$1"
    [ -n "${LSO_FS_ROOT:-}" ] && return 0      # fixture/test mode: never touch fixtures
    [ "$(id -u)" -eq 0 ] || return 0           # only meaningful when we ran as root
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would chown wp-content/litespeed + object-cache.php to the docroot owner"
        return 0
    fi

    local owner
    owner=$(stat -c '%U:%G' "$docroot" 2>/dev/null || stat -f '%Su:%Sg' "$docroot" 2>/dev/null) || return 0
    case "$owner" in
        root:*|''|:*) return 0 ;;              # docroot itself root-owned: no better runtime user to infer
    esac

    # Ensure the optimized-asset dir exists and is writable by the runtime user
    local litespeed_dir="${docroot%/}/wp-content/litespeed"
    mkdir -p "$litespeed_dir" 2>/dev/null || true

    local p fixed=0
    for p in "$litespeed_dir" "${docroot%/}/wp-content/object-cache.php"; do
        [ -e "$p" ] || continue
        chown -R "$owner" "$p" 2>/dev/null && fixed=1
    done
    [ "$fixed" = 1 ] && log_info "LSCWP: normalized ownership of generated assets to ${owner} (runtime can write minified CSS/JS)"
}

# Best-effort render smoke-test (issue #4). After enabling CSS/JS minification,
# LSCWP rewrites asset URLs under /wp-content/litespeed/. If the runtime cannot
# write them they 404 and the page renders unstyled — invisible to analyze.
# Fetch the home page, pull one generated asset URL, and verify it serves 200.
# Never fails the run: needs curl + a reachable siteurl, warns if it can't pass.
_lscwp_verify_assets() {
    local docroot="$1"
    [ -n "${LSO_FS_ROOT:-}" ] && return 0
    [ "${DRY_RUN:-false}" = true ] && return 0
    command -v curl >/dev/null 2>&1 || return 0

    local siteurl
    siteurl=$(lso_wp "$docroot" option get siteurl 2>/dev/null) || return 0
    [ -z "$siteurl" ] && return 0

    # First fetch triggers lazy asset generation; second returns the rewritten HTML
    curl -sk --max-time 10 "${siteurl%/}/" -o /dev/null 2>/dev/null || return 0
    local html asset code
    html=$(curl -sk --max-time 10 "${siteurl%/}/" 2>/dev/null) || return 0
    asset=$(printf '%s\n' "$html" | grep -oE 'https?://[[:alnum:]_./:?=&%~-]*wp-content/litespeed/[[:alnum:]_./:?=&%~-]+\.(css|js)' | head -1)
    [ -z "$asset" ] && return 0                # minify produced no rewritten asset — nothing to verify

    code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$asset" 2>/dev/null)
    if [ "$code" = "200" ]; then
        log_info "LSCWP: optimized asset verified (HTTP 200) — minified CSS/JS serving correctly"
    else
        log_warn "LSCWP: optimized asset returned HTTP ${code} (expected 200): ${asset}"
        log_warn "  Minified CSS/JS may 404 -> site can render UNSTYLED. Ensure wp-content/litespeed is"
        log_warn "  writable by the PHP runtime user, then re-run or: wp litespeed-purge all"
    fi
}

# CVE version gate; updates the plugin when below minimum
_lscwp_version_gate() {
    local docroot="$1"
    local version
    version=$(lso_wp "$docroot" plugin get litespeed-cache --field=version 2>/dev/null) || return 1

    if version_ge "$version" "$LSCWP_MIN_VERSION"; then
        log_info "LSCWP version ${version} OK (>= ${LSCWP_MIN_VERSION})"
        return 0
    fi

    log_warn "LSCWP ${version} < ${LSCWP_MIN_VERSION} — known CVEs:"
    log_warn "  CVE-2024-28000 (privesc <=6.3.0.1), CVE-2024-44000 (debug-log takeover <6.5.0.1), CVE-2024-47374 (XSS <=6.5.0.2)"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would run: wp plugin update litespeed-cache"
    else
        if lso_wp "$docroot" plugin update litespeed-cache >/dev/null 2>&1; then
            log_success "LSCWP updated"
        else
            log_error "LSCWP update failed — fix manually before relying on it"
            return 1
        fi
    fi
}

# Cache-vary sanity check (SYNTHESIS C4): woocommerce_items_in_cart must NOT
# be in Do-Not-Cache Cookies — LSCWP already varies on it; excluding it
# disables caching for every visitor with a cart.
lscwp_check_vary_cookies() {
    local docroot="$1"
    local exc
    exc=$(lso_wp "$docroot" litespeed-option get cache-exc_cookies 2>/dev/null) || exc=""

    if echo "$exc" | grep -q "woocommerce_items_in_cart"; then
        log_error "DANGER: woocommerce_items_in_cart found in Do-Not-Cache Cookies (${docroot})"
        log_error "  This disables page caching for everyone with a cart. LSCWP already varies on it."
        log_error "  Fix: remove it via LiteSpeed Cache > Cache > Excludes > Do Not Cache Cookies"
        return 1
    fi
    return 0
}

# Block access to *.log (CVE-2024-44000 surface) via mod_rewrite — the only
# .htaccess mechanism OLS honors. Marker-delimited, idempotent, placed at top.
_lscwp_block_log_access() {
    local docroot="$1"
    local htaccess="${docroot}/.htaccess"

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would block *.log access in ${htaccess}"
        return 0
    fi

    touch "$htaccess"
    if grep -q "# BEGIN litespeed-optimizer logblock" "$htaccess"; then
        return 0
    fi

    local tmp
    tmp=$(secure_mktemp "${docroot}/.lso-ht.XXXXXX") || return 1
    {
        echo "# BEGIN litespeed-optimizer logblock"
        echo "<IfModule mod_rewrite.c>"
        echo "RewriteEngine On"
        echo "RewriteRule \.log\$ - [F,L]"
        echo "</IfModule>"
        echo "# END litespeed-optimizer logblock"
        cat "$htaccess"
    } > "$tmp"
    copy_file_permissions "$htaccess" "$tmp" 2>/dev/null || true
    mv "$tmp" "$htaccess"
    log_info "Blocked *.log access in ${htaccess}"
}

# Per-site apply
_lscwp_apply_site() {
    local docroot="$1"

    log_info "LSCWP: processing site ${docroot}"

    # 1. Plugin present? install + activate when missing
    if ! lso_wp "$docroot" plugin get litespeed-cache --field=version >/dev/null 2>&1; then
        if [ "${DRY_RUN:-false}" = true ]; then
            log_info "[DRY RUN] Would run: wp plugin install litespeed-cache --activate"
        else
            log_info "Installing litespeed-cache plugin..."
            if ! lso_wp "$docroot" plugin install litespeed-cache --activate >/dev/null 2>&1; then
                log_error "LSCWP install failed for ${docroot}"
                return 1
            fi
        fi
    else
        # Make sure it is active
        if ! lso_wp "$docroot" plugin is-active litespeed-cache >/dev/null 2>&1; then
            if [ "${DRY_RUN:-false}" = true ]; then
                log_info "[DRY RUN] Would run: wp plugin activate litespeed-cache"
            else
                lso_wp "$docroot" plugin activate litespeed-cache >/dev/null 2>&1 || true
            fi
        fi
    fi

    # 2. CVE version gate
    if [ "${DRY_RUN:-false}" != true ]; then
        _lscwp_version_gate "$docroot" || true
    else
        _lscwp_version_gate "$docroot" >/dev/null 2>&1 || true
    fi

    # 3. Pre-change option export (rolls back via litespeed-option import)
    local backup_root="${CURRENT_BACKUP_DIR:-${DATA_DIR}/lscwp-exports}"
    local site_slug
    site_slug=$(basename "$(dirname "$docroot")")-$(basename "$docroot")
    if [ "${DRY_RUN:-false}" != true ]; then
        mkdir -p "${backup_root}/lscwp"
        if lso_wp "$docroot" litespeed-option export > "${backup_root}/lscwp/${site_slug}.json" 2>/dev/null; then
            log_info "LSCWP options exported: ${backup_root}/lscwp/${site_slug}.json"
        else
            log_warn "LSCWP option export failed (continuing)"
        fi
    fi

    # 4. Render + apply the curated profile
    local template rendered
    template=$(_lscwp_profile_for "$docroot")
    if [ ! -f "$template" ]; then
        log_error "Profile template not found: $template"
        return 1
    fi
    rendered=$(secure_mktemp "${TMPDIR:-/tmp}/lso-profile.XXXXXX") || return 1
    _lscwp_render_profile "$docroot" "$template" "$rendered"
    log_info "Applying profile: $(basename "$template")"
    _lscwp_apply_profile "$docroot" "$rendered"
    rm -f "$rendered"

    # 5. Hardening: .log access + vary sanity
    _lscwp_block_log_access "$docroot"
    lscwp_check_vary_cookies "$docroot" || true

    # 6. Purge
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would run: wp litespeed-purge all"
    else
        lso_wp "$docroot" litespeed-purge all >/dev/null 2>&1 || log_warn "Purge failed (non-fatal)"
        log_info "LSCWP cache purged"
    fi

    # 7. Re-own generated assets to the runtime user, then verify they serve
    #    (issue #4: root-owned wp-content/litespeed -> minified CSS/JS 404 ->
    #    unstyled site that analyze still scores 100). Order matters: fix
    #    ownership first so the smoke-test's warm fetch can generate into it.
    _lscwp_fix_ownership "$docroot"
    _lscwp_verify_assets "$docroot"
}

feature_apply_custom_lscwp() {
    local target_site="${1:-}"

    if ! _lscwp_have_wpcli; then
        log_warn "wp-cli not found — skipping LSCWP plugin configuration"
        log_info "  Install wp-cli, then: litespeed-optimizer optimize --feature lscwp"
        return 0
    fi

    if [ -z "${LSO_WP_SITES+x}" ] || [ "${#LSO_WP_SITES[@]}" -eq 0 ]; then
        log_warn "No WordPress sites found — nothing for LSCWP to configure"
        return 0
    fi

    local docroot rc=0
    for docroot in "${LSO_WP_SITES[@]}"; do
        if [ -n "$target_site" ] && [[ "$docroot" != *"$target_site"* ]]; then
            continue
        fi
        _lscwp_apply_site "$docroot" || rc=1
    done
    return $rc
}

feature_detect_custom_lscwp() {
    _lscwp_have_wpcli || return 1
    [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ] || return 1

    local docroot="${LSO_WP_SITES[0]}"
    local ttl
    ttl=$(lso_wp "$docroot" litespeed-option get cache-ttl_pub 2>/dev/null) || return 1
    [ "$ttl" = "604800" ]
}

FEATURE_ID="lscwp"
FEATURE_DISPLAY="LiteSpeed Cache Plugin (LSCWP)"
FEATURE_DETECT_PATTERN="litespeed-cache"
FEATURE_SCOPE="per-site"
FEATURE_ALIASES="plugin"
feature_register
