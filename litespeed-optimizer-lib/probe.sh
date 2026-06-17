#!/bin/bash
################################################################################
# probe.sh - Web-SAPI extension probe (probe-redis)
################################################################################
# Verifies, in the ACTUAL web SAPI (not CLI php, not wp-cli), whether the lsphp
# serving a WordPress docroot loads the `redis` PHP extension — the thing LSCWP
# needs to use Redis as an object cache. redis-server can be up and the CLI php
# can have phpredis while the WEB SAPI does not, in which case the object cache
# silently falls back to MySQL. `analyze` raises a CLI-context heuristic for
# this (lso_php_ext_loaded on the vhost's lsphp); this command CONFIRMS it in
# the web context and additionally tests server reachability.
#
# Mechanism (token-guarded one-shot HTTP probe — pattern contributed by the
# agrido project, validated on Zenbox/LiteSpeed 2026-06-17):
#   1. render a random-named PHP file carrying a per-run hash_equals token
#   2. drop it in the DOCROOT (NOT wp-content — .htaccess Denies PHP there)
#   3. fetch over HTTP with the token + a unique cache-buster; the PHP emits
#      no-cache headers so LSCache cannot serve a stale HIT
#   4. the PHP self-deletes (one-shot); we backstop-rm the file regardless
#
# Test/override seams (mirror the LSO_WP_BIN / LSO_RAM_MB convention):
#   LSO_PROBE_DOCROOT  - where to drop the probe (default: first WP docroot)
#   LSO_PROBE_URL      - base URL to fetch (default: positional URL / wp home)
#   LSO_PROBE_REDIS_HOST / LSO_PROBE_REDIS_PORT - server-reachability target
################################################################################

# Resolve the docroot to drop the probe into.
_probe_docroot() {
    if [ -n "${LSO_PROBE_DOCROOT:-}" ]; then
        printf '%s' "$LSO_PROBE_DOCROOT"
        return 0
    fi
    if [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ]; then
        printf '%s' "${LSO_WP_SITES[0]}"
        return 0
    fi
    return 1
}

# Resolve the base URL the probe is fetched from. Arg $1 = docroot (for wp-cli).
_probe_base_url() {
    if [ -n "${LSO_PROBE_URL:-}" ]; then
        printf '%s' "$LSO_PROBE_URL"
        return 0
    fi
    if [ -n "${TARGET_SITE:-}" ] && printf '%s' "$TARGET_SITE" | grep -qE '^https?://'; then
        printf '%s' "$TARGET_SITE"
        return 0
    fi
    local docroot="$1" home=""
    if type -t lso_wp &>/dev/null && type -t _lscwp_have_wpcli &>/dev/null && _lscwp_have_wpcli; then
        home=$(lso_wp "$docroot" option get home 2>/dev/null | tr -d '\r') || home=""
    fi
    if [ -n "$home" ]; then
        printf '%s' "$home"
        return 0
    fi
    return 1
}

# Random hex string of $1 bytes (=> 2*$1 hex chars). openssl with urandom fallback.
_probe_rand_hex() {
    local n="${1:-8}"
    if command -v openssl &>/dev/null; then
        openssl rand -hex "$n"
    else
        od -An -tx1 -N "$n" /dev/urandom 2>/dev/null | tr -d ' \n'
    fi
}

run_probe_redis() {
    local docroot base token name target url tpl bodyfile body http_code rendered

    if ! docroot=$(_probe_docroot); then
        log_error "probe-redis: no WordPress docroot found (set LSO_PROBE_DOCROOT or run where a WP site is detected)"
        return 1
    fi
    if [ ! -d "$docroot" ]; then
        log_error "probe-redis: docroot is not a directory: $docroot"
        return 1
    fi
    if ! base=$(_probe_base_url "$docroot"); then
        log_error "probe-redis: could not determine site URL — pass it: litespeed-optimizer probe-redis https://your-site"
        return 1
    fi
    base="${base%/}"

    tpl="${TEMPLATE_DIR}/php/probe.php.tpl"
    if [ ! -f "$tpl" ]; then
        log_error "probe-redis: probe template missing: $tpl"
        return 1
    fi

    local redis_host="${LSO_PROBE_REDIS_HOST:-127.0.0.1}"
    local redis_port="${LSO_PROBE_REDIS_PORT:-6379}"

    token=$(_probe_rand_hex 16)
    name="_lso_probe_$(_probe_rand_hex 8).php"
    target="${docroot}/${name}"
    url="${base}/${name}?t=${token}&cb=$$$(_probe_rand_hex 3)"

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would drop ${target}, GET ${base}/${name}?t=<token>&cb=<n>, parse redis_ext, then delete it"
        return 0
    fi

    rendered=$(sed -e "s/{{TOKEN}}/${token}/g" \
                   -e "s/{{REDIS_HOST}}/${redis_host}/g" \
                   -e "s/{{REDIS_PORT}}/${redis_port}/g" "$tpl")
    if ! printf '%s\n' "$rendered" > "$target" 2>/dev/null; then
        log_error "probe-redis: cannot write probe into docroot (permissions?): $target"
        return 1
    fi
    chmod 644 "$target" 2>/dev/null || true

    # Backstop cleanup: the PHP self-unlinks, this covers perms / early-exit edges.
    # shellcheck disable=SC2064
    trap "rm -f '$target' 2>/dev/null || true" RETURN

    bodyfile=$(secure_mktemp "${LSO_DATA_DIR:-/tmp}/.lso-probe.XXXXXX" 2>/dev/null) || bodyfile="${target}.out"
    local auth_args=""
    [ -n "${LSO_HTTP_AUTH:-}" ] && auth_args="--user ${LSO_HTTP_AUTH}"
    # shellcheck disable=SC2086
    http_code=$(curl -sL -m 15 $auth_args -o "$bodyfile" -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    body=$(cat "$bodyfile" 2>/dev/null || true)
    rm -f "$bodyfile" 2>/dev/null || true

    if [ "$http_code" = "404" ]; then
        log_error "probe-redis: probe returned 404 — token rejected, or the file was blocked/rewritten before PHP ran"
        return 1
    fi
    if [ -z "$body" ] || [ "${body#\{}" = "$body" ]; then
        log_error "probe-redis: no JSON from probe (HTTP ${http_code}). The docroot may not execute PHP at ${base}, or the site needs --basic-auth."
        return 1
    fi

    # Parse JSON with sed (no jq dependency, matches analyzer conventions).
    local one redis_ext redis_server sapi phpver
    one=$(printf '%s' "$body" | tr -d '\n')
    redis_ext=$(printf '%s' "$one"    | sed -n 's/.*"redis_ext"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d '" ')
    redis_server=$(printf '%s' "$one" | sed -n 's/.*"redis_server"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d '" ')
    sapi=$(printf '%s' "$one"         | sed -n 's/.*"sapi"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    phpver=$(printf '%s' "$one"       | sed -n 's/.*"php_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    local has_ext=false
    case "$redis_ext" in ''|false|null|0) has_ext=false ;; *) has_ext=true ;; esac

    if [ "${JSON_OUTPUT:-false}" = true ]; then
        json_output "$(printf '{"command":"probe-redis","sapi":"%s","php_version":"%s","redis_ext":%s,"redis_ext_version":"%s","redis_server":"%s"}' \
            "$sapi" "$phpver" "$has_ext" "$redis_ext" "$redis_server")"
        [ "$has_ext" = true ] && return 0
        return 1
    fi

    log_info "Web SAPI: ${sapi:-?}   PHP: ${phpver:-?}"
    if [ "$has_ext" = true ]; then
        log_success "redis PHP extension IS loaded in the web SAPI (phpredis ${redis_ext}) — object cache can use Redis"
        case "$redis_server" in
            up)    log_success "Redis server reachable from the web SAPI (${redis_host}:${redis_port})" ;;
            down)  log_warn "phpredis present but Redis server NOT reachable at ${redis_host}:${redis_port}" ;;
            err:*) log_warn "phpredis present but Redis connect errored: ${redis_server#err:}" ;;
        esac
        return 0
    fi

    log_error "redis PHP extension is NOT loaded in the web SAPI — LSCWP object cache silently falls back to MySQL"
    log_info  "Fix: install phpredis for the lsphp THIS vhost runs, then restart LiteSpeed."
    if [ -n "$phpver" ]; then
        local lsphp_tag
        lsphp_tag=$(printf '%s' "$phpver" | cut -d. -f1,2 | tr -d '.')
        log_info "     e.g. apt install lsphp${lsphp_tag}-redis   # match your lsphp package name"
    fi
    return 1
}
