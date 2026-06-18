#!/bin/bash
################################################################################
# probe.sh - Web-SAPI probes (probe-redis, probe-opcache)
################################################################################
# Reads things that are ONLY observable in the actual web SAPI (not CLI php, not
# wp-cli), via a token-guarded one-shot HTTP probe:
#   - probe-redis    : is the `redis` PHP extension loaded + is the server reachable
#   - probe-opcache  : runtime OPcache hit-rate / pool-fill / interned / key-table
#                      (CLI has opcache.enable_cli=0, so this is the only honest read)
#
# Shared mechanism (pattern contributed by the agrido project, validated on
# Zenbox/LiteSpeed 2026-06-17) — _probe_fetch_json():
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
#   LSO_OPCACHE_INI_WRITABLE=1 - force the self-fixable remediation branch (tests)
################################################################################

# Bare hostname from a URL/home string: strip scheme, path, port, leading www.
# Lowercased so host comparisons are case-insensitive.
_probe_url_host() {
    printf '%s' "$1" \
        | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s#:[0-9]+$##; s#^www\.##' \
        | tr '[:upper:]' '[:lower:]'
}

# The explicitly-requested probe URL (override or positional), if any. Does NOT
# fall back to wp home — that lookup depends on the docroot we are still choosing.
_probe_target_url() {
    if [ -n "${LSO_PROBE_URL:-}" ]; then printf '%s' "$LSO_PROBE_URL"; return 0; fi
    if [ -n "${TARGET_SITE:-}" ] && printf '%s' "$TARGET_SITE" | grep -qE '^https?://'; then
        printf '%s' "$TARGET_SITE"; return 0
    fi
    return 1
}

# Resolve the docroot to drop the probe into.
# When a URL is requested on a MULTI-VHOST box, the first detected WP docroot is
# usually NOT the one that serves that URL — dropping the probe there yields a 404
# at the fetch URL. So prefer the WP site whose own `home` host matches the URL
# host; only fall back to the first site when nothing matches (or no URL given).
_probe_docroot() {
    if [ -n "${LSO_PROBE_DOCROOT:-}" ]; then
        printf '%s' "$LSO_PROBE_DOCROOT"
        return 0
    fi
    [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ] || return 1

    local want_host
    want_host=$(_probe_url_host "$(_probe_target_url 2>/dev/null)")
    if [ -n "$want_host" ] && type -t lso_wp &>/dev/null \
       && type -t _lscwp_have_wpcli &>/dev/null && _lscwp_have_wpcli; then
        local d h
        for d in "${LSO_WP_SITES[@]}"; do
            h=$(_probe_url_host "$(lso_wp "$d" option get home 2>/dev/null | tr -d '\r')")
            if [ -n "$h" ] && [ "$h" = "$want_host" ]; then
                printf '%s' "$d"
                return 0
            fi
        done
    fi
    printf '%s' "${LSO_WP_SITES[0]}"
    return 0
}

# Resolve the base URL the probe is fetched from. Arg $1 = docroot (for wp-cli).
_probe_base_url() {
    if _probe_target_url; then
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

# Best-effort Redis port: LSCWP/redis-cache drop-ins frequently run Redis on a
# NON-default port (e.g. 7074), so a hard-coded 6379 reachability probe reports
# a false "down" on those boxes. Read WP_REDIS_PORT from the object-cache drop-in
# or wp-config before defaulting. Arg $1 = docroot. (agrido review)
_probe_redis_port() {
    if [ -n "${LSO_PROBE_REDIS_PORT:-}" ]; then printf '%s' "$LSO_PROBE_REDIS_PORT"; return 0; fi
    local docroot="$1" port=""
    port=$(grep -hiE 'WP_REDIS_PORT' \
              "${docroot}/wp-content/object-cache.php" "${docroot}/wp-config.php" 2>/dev/null \
           | grep -oE '[0-9]{2,5}' | head -1 || true)
    [ -n "$port" ] && printf '%s' "$port" || printf '6379'
}

# Resolve docroot + base URL with consistent error messages.
# $1 = command label. Sets globals _PROBE_DR / _PROBE_BASE; returns 1 on failure.
_probe_resolve() {
    local label="$1"
    if ! _PROBE_DR=$(_probe_docroot); then
        log_error "${label}: no WordPress docroot found (set LSO_PROBE_DOCROOT or run where a WP site is detected)"
        return 1
    fi
    if [ ! -d "$_PROBE_DR" ]; then
        log_error "${label}: docroot is not a directory: $_PROBE_DR"
        return 1
    fi
    if ! _PROBE_BASE=$(_probe_base_url "$_PROBE_DR"); then
        log_error "${label}: could not determine site URL — pass it: litespeed-optimizer ${label} https://your-site"
        return 1
    fi
    _PROBE_BASE="${_PROBE_BASE%/}"
    return 0
}

# Shared harness: drop the token-guarded probe, fetch it, self-clean.
# Args: $1 = docroot, $2 = base URL.
# Sets: _PROBE_BODY, _PROBE_HTTP, _PROBE_REDIS_HOST, _PROBE_REDIS_PORT.
# The RETURN trap deletes the dropped file the moment this function returns
# (body already captured), so callers never see the probe on disk.
_probe_fetch_json() {
    local docroot="$1" base="$2"
    local tpl token name target url rendered bodyfile auth_args
    _PROBE_BODY=""
    _PROBE_HTTP="000"

    tpl="${TEMPLATE_DIR}/php/probe.php.tpl"
    if [ ! -f "$tpl" ]; then
        log_error "probe: probe template missing: $tpl"
        return 1
    fi

    _PROBE_REDIS_HOST="${LSO_PROBE_REDIS_HOST:-127.0.0.1}"
    _PROBE_REDIS_PORT=$(_probe_redis_port "$docroot")

    token=$(_probe_rand_hex 16)
    name="_lso_probe_$(_probe_rand_hex 8).php"
    target="${docroot}/${name}"
    url="${base}/${name}?t=${token}&cb=$$$(_probe_rand_hex 3)"

    # Arm cleanup BEFORE the write so a partial/failed write can't leak an empty
    # probe into the docroot (rm -f on a not-yet-created path is harmless).
    # shellcheck disable=SC2064
    trap "rm -f '$target' 2>/dev/null || true" RETURN

    rendered=$(sed -e "s/{{TOKEN}}/${token}/g" \
                   -e "s/{{REDIS_HOST}}/${_PROBE_REDIS_HOST}/g" \
                   -e "s/{{REDIS_PORT}}/${_PROBE_REDIS_PORT}/g" "$tpl")
    if ! printf '%s\n' "$rendered" > "$target" 2>/dev/null; then
        log_error "probe: cannot write probe into docroot (permissions?): $target"
        return 1
    fi
    chmod 644 "$target" 2>/dev/null || true

    # Probe output goes to a NON-docroot temp (never momentarily web-accessible).
    bodyfile=$(secure_mktemp "${LSO_DATA_DIR:-${TMPDIR:-/tmp}}/.lso-probe.XXXXXX" 2>/dev/null) \
        || bodyfile="${TMPDIR:-/tmp}/.lso-probe.$$"
    auth_args=""
    [ -n "${LSO_HTTP_AUTH:-}" ] && auth_args="--user ${LSO_HTTP_AUTH}"
    # shellcheck disable=SC2086
    _PROBE_HTTP=$(curl -sL -m 15 $auth_args -o "$bodyfile" -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    _PROBE_BODY=$(cat "$bodyfile" 2>/dev/null || true)
    rm -f "$bodyfile" 2>/dev/null || true
    return 0
}

# Validate a fetched body is JSON; logs + returns 1 otherwise. $1=label $2=body $3=http
_probe_body_ok() {
    local label="$1" body="$2" http="$3"
    if [ "$http" = "404" ]; then
        log_error "${label}: probe returned 404 — token rejected, or the file was blocked/rewritten before PHP ran"
        return 1
    fi
    if [ -z "$body" ] || [ "${body#\{}" = "$body" ]; then
        log_error "${label}: no JSON from probe (HTTP ${http}). The docroot may not execute PHP, or the site needs --basic-auth."
        return 1
    fi
    return 0
}

# Scalar JSON field (false/null/number/unquoted) — value with quotes/spaces stripped.
_probe_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p" | tr -d '" '
}
# Quoted-string JSON field.
_probe_str_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}
# Keep only a leading non-negative integer, else empty (set -e safe arithmetic).
_probe_int() {
    case "$1" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$1" ;; esac
}

run_probe_redis() {
    _probe_resolve probe-redis || return 1

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] probe-redis: would drop a token-guarded probe in ${_PROBE_DR}, GET it over HTTP, parse redis_ext, then delete it"
        return 0
    fi

    _probe_fetch_json "$_PROBE_DR" "$_PROBE_BASE" || return 1
    _probe_body_ok probe-redis "$_PROBE_BODY" "$_PROBE_HTTP" || return 1

    local one redis_ext redis_server sapi phpver
    one=$(printf '%s' "$_PROBE_BODY" | tr -d '\n')
    redis_ext=$(_probe_field "$one" redis_ext)
    redis_server=$(_probe_field "$one" redis_server)
    sapi=$(_probe_str_field "$one" sapi)
    phpver=$(_probe_str_field "$one" php_version)

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
            up)    log_success "Redis server reachable from the web SAPI (${_PROBE_REDIS_HOST}:${_PROBE_REDIS_PORT})" ;;
            down)  log_warn "phpredis present but Redis server NOT reachable at ${_PROBE_REDIS_HOST}:${_PROBE_REDIS_PORT}" ;;
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

# Smallest bucket >= target MB from a sane ladder.
_opc_round_mb() {
    local t b
    t=$(_probe_int "$1"); [ -n "$t" ] || { printf '256'; return; }
    for b in 64 128 256 512 1024 2048 4096; do
        if [ "$t" -le "$b" ]; then printf '%s' "$b"; return; fi
    done
    printf '%s' "$t"
}
# Next power of two strictly above n (floor 1024 — opcache.max_accelerated_files).
_opc_pow2_above() {
    local n p=1024
    n=$(_probe_int "$1"); [ -n "$n" ] || { printf '%s' "$p"; return; }
    while [ "$p" -le "$n" ]; do
        p=$((p * 2))
        [ "$p" -ge 1000000 ] && break
    done
    printf '%s' "$p"
}

run_probe_opcache() {
    _probe_resolve probe-opcache || return 1

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] probe-opcache: would drop a token-guarded probe in ${_PROBE_DR}, GET it over HTTP, read opcache_get_status, then delete it"
        return 0
    fi

    _probe_fetch_json "$_PROBE_DR" "$_PROBE_BASE" || return 1
    _probe_body_ok probe-opcache "$_PROBE_BODY" "$_PROBE_HTTP" || return 1

    local one sapi phpver
    one=$(printf '%s' "$_PROBE_BODY" | tr -d '\n')
    sapi=$(_probe_str_field "$one" sapi)
    phpver=$(_probe_str_field "$one" php_version)

    # opcache is null when the SAPI has no OPcache loaded/enabled.
    local oc_block
    oc_block=$(printf '%s' "$one" | sed -n 's/.*"opcache"[[:space:]]*:[[:space:]]*\(.*\)/\1/p')
    local enabled
    enabled=$(_probe_field "$one" enabled)

    if [ -z "$oc_block" ] || [ "${oc_block#null}" != "$oc_block" ] || [ "$enabled" = "false" ]; then
        if [ "${JSON_OUTPUT:-false}" = true ]; then
            json_output "$(printf '{"command":"probe-opcache","sapi":"%s","php_version":"%s","opcache_enabled":false}' "$sapi" "$phpver")"
        else
            log_info  "Web SAPI: ${sapi:-?}   PHP: ${phpver:-?}"
            log_error "OPcache is NOT enabled in the web SAPI — every request recompiles PHP from source"
            log_info  "Fix: enable opcache for the serving lsphp (opcache.enable=1) and restart LiteSpeed."
        fi
        return 1
    fi

    # Pull the runtime numbers (bytes for memory; key/script counts; hit_rate %).
    local mem_used mem_free mem_wasted hit_rate keys max_keys scripts oom interned_free interned_buf
    mem_used=$(_probe_int "$(_probe_field "$one" mem_used)")
    mem_free=$(_probe_int "$(_probe_field "$one" mem_free)")
    mem_wasted=$(_probe_int "$(_probe_field "$one" mem_wasted)")
    hit_rate=$(_probe_field "$one" hit_rate); hit_rate="${hit_rate%%.*}"; hit_rate=$(_probe_int "$hit_rate")
    keys=$(_probe_int "$(_probe_field "$one" num_cached_keys)")
    max_keys=$(_probe_int "$(_probe_field "$one" max_cached_keys)")
    scripts=$(_probe_int "$(_probe_field "$one" num_cached_scripts)")
    oom=$(_probe_int "$(_probe_field "$one" oom_restarts)")
    interned_free=$(_probe_int "$(_probe_field "$one" interned_free)")
    interned_buf=$(_probe_int "$(_probe_field "$one" interned_buffer)")

    # ---- Verdict (agrido field thresholds) -------------------------------------
    # Per-trigger flags so remediation can name the RIGHT directive (they are
    # different knobs). HARD triggers (oom/mem/keys/interned) are true regardless
    # of cache warmth. hit_rate is the only SOFT trigger: cumulative-since-restart,
    # so it reads low on a cold/warming cache (NORMAL). It is gated on warmth via
    # num_cached_scripts — and the gate is 200, not 50, because a real WordPress
    # caches hundreds of scripts within the first few page loads, so a lower gate
    # would false-flag a merely-warming WP as undersized (agrido review).
    local full=false reasons="" free_pct=-1 pool_mb=0 wasted_pct=-1
    local t_oom=false t_mem=false t_keys=false t_interned=false t_hit=false
    if [ -n "$mem_used" ] && [ -n "$mem_free" ] && [ "$((mem_used + mem_free))" -gt 0 ]; then
        local total=$((mem_used + mem_free))
        free_pct=$(( mem_free * 100 / total ))
        pool_mb=$(( total / 1048576 ))
        [ -n "$mem_wasted" ] && wasted_pct=$(( mem_wasted * 100 / total ))
    fi

    if [ -n "$oom" ] && [ "$oom" -gt 0 ]; then
        full=true; t_oom=true; reasons="${reasons}; oom_restarts=${oom} (cache thrashing/restarting under load)"
    fi
    if [ "$free_pct" -ge 0 ] && [ "$free_pct" -lt 10 ]; then
        full=true; t_mem=true; reasons="${reasons}; pool ${free_pct}% free (<10%, ${pool_mb}MB)"
    fi
    if [ -n "$keys" ] && [ -n "$max_keys" ] && [ "$max_keys" -gt 0 ]; then
        # keys >= 95% of max_keys (key-table saturated — mem can look free)
        if [ "$(( keys * 100 / max_keys ))" -ge 95 ]; then
            full=true; t_keys=true; reasons="${reasons}; key-table ${keys}/${max_keys} (>=95%, no script slots)"
        fi
    fi
    if [ -n "$interned_free" ] && [ -n "$interned_buf" ] && [ "$interned_buf" -gt 0 ]; then
        if [ "$(( interned_free * 100 / interned_buf ))" -lt 5 ]; then
            full=true; t_interned=true; reasons="${reasons}; interned-strings buffer <5% free (string dedup spills)"
        fi
    fi
    # The soft hit-rate trigger means "undersized" ONLY when the misses are
    # plausibly caused by EVICTION — otherwise a bigger pool can't raise the rate.
    # Three independent corroborators, all required:
    #   hr_warm   — enough scripts cached (>=200). num_cached_scripts is a weak
    #               warmth proxy on its own (one page load compiles 1000+ scripts).
    #   hr_trust  — hit_rate >= 50. Since misses ≈ num_cached_scripts, "hits
    #               outnumber misses" (rate trustworthy) reduces algebraically to
    #               hit_rate >= 50; below that, misses dominate = still warming
    #               after a flush/recycle (the optimize→probe workflow), not small.
    #   hr_press  — the pool is actually under memory pressure (free_pct < 30 or
    #               OOM). With a mostly-FREE pool and no OOM nothing is being
    #               evicted, so a low rate is warming/low-traffic — raising
    #               memory_consumption would do nothing. (Builds on agrido's gate.)
    local hr_warm=false hr_low=false hr_trust=false hr_press=false
    if [ -n "$scripts" ] && [ "$scripts" -ge 200 ]; then hr_warm=true; fi
    if [ -n "$hit_rate" ] && [ "$hit_rate" -lt 90 ]; then hr_low=true; fi
    if [ -n "$hit_rate" ] && [ "$hit_rate" -ge 50 ]; then hr_trust=true; fi
    if { [ "$free_pct" -ge 0 ] && [ "$free_pct" -lt 30 ]; } || { [ -n "$oom" ] && [ "$oom" -gt 0 ]; }; then
        hr_press=true
    fi
    if [ "$hr_warm" = true ] && [ "$hr_low" = true ] && [ "$hr_trust" = true ] && [ "$hr_press" = true ]; then
        full=true; t_hit=true; reasons="${reasons}; hit-rate ${hit_rate}% (<90% on a warm cache under memory pressure)"
    fi
    reasons="${reasons#; }"

    # Fragmentation: low free but HIGH wasted (>20% of pool) means the pool is
    # churned by recompiles, not genuinely too small — a bigger pool won't fix a
    # thrashing one. Fix the churn (reset + validate_timestamps=0) FIRST.
    local fragmented=false
    if [ "$t_mem" = true ] && [ "$wasted_pct" -ge 20 ]; then fragmented=true; fi

    # ---- Host-aware remediation (detect-AND-fix split) -------------------------
    # opcache.* are PHP_INI_SYSTEM: on shared/managed hosting they are often NOT
    # raisable per-account. Emitting an unappliable php.ini snippet is worse than
    # honest — so branch on whether we can actually write the serving lsphp's ini.
    local self_fixable=false
    if [ -n "${LSO_OPCACHE_INI_WRITABLE:-}" ]; then
        [ "${LSO_OPCACHE_INI_WRITABLE}" = "1" ] && self_fixable=true
    elif [ -n "${LSO_PHP_INI:-}" ] && [ -w "${LSO_PHP_INI:-}" ]; then
        self_fixable=true
    elif [ -n "${LSO_PHP_INI_SCAN_DIR:-}" ] && [ -w "${LSO_PHP_INI_SCAN_DIR:-}" ]; then
        self_fixable=true
    fi

    if [ "${JSON_OUTPUT:-false}" = true ]; then
        json_output "$(printf '{"command":"probe-opcache","sapi":"%s","php_version":"%s","opcache_enabled":true,"verdict":"%s","pool_mb":%s,"free_pct":%s,"wasted_pct":%s,"hit_rate":%s,"num_cached_keys":%s,"max_cached_keys":%s,"num_cached_scripts":%s,"oom_restarts":%s,"fragmented":%s,"self_fixable":%s}' \
            "$sapi" "$phpver" "$([ "$full" = true ] && echo undersized || echo healthy)" \
            "${pool_mb:-0}" "${free_pct:-0}" "${wasted_pct:-0}" "${hit_rate:-0}" "${keys:-0}" "${max_keys:-0}" "${scripts:-0}" "${oom:-0}" "$fragmented" "$self_fixable")"
        [ "$full" = true ] && return 1
        return 0
    fi

    log_info "Web SAPI: ${sapi:-?}   PHP: ${phpver:-?}"
    log_info "OPcache pool ${pool_mb}MB, ${free_pct}% free (wasted ${wasted_pct}%) | hit-rate ${hit_rate:-?}% | keys ${keys:-?}/${max_keys:-?} | scripts ${scripts:-?} | oom ${oom:-0}"
    if [ "$hr_low" = true ] && [ "$t_hit" = false ]; then
        if [ "$hr_warm" = false ]; then
            log_info "(hit-rate ${hit_rate}% not flagged — cache still warming (${scripts:-?} scripts < 200); cumulative hit-rate is unreliable until warm)"
        elif [ "$hr_trust" = false ]; then
            log_info "(hit-rate ${hit_rate}% not flagged — below 50% means misses still dominate (cache warming after a flush/recycle); cumulative hit-rate is untrustworthy until hits outnumber misses)"
        else
            log_info "(hit-rate ${hit_rate}% not flagged — pool is ${free_pct}% free with no OOM, so misses aren't from eviction; a bigger pool can't raise the rate — likely warming or low repeat traffic)"
        fi
    fi

    if [ "$full" != true ]; then
        log_success "OPcache healthy in the web SAPI — no undersizing signals"
        return 0
    fi

    log_error "OPcache is undersized in the web SAPI: ${reasons}"

    # Fragmentation takes priority: sizing up a thrashing pool wastes RAM.
    if [ "$fragmented" = true ]; then
        log_warn "High wasted memory (${wasted_pct}%) — this pool is FRAGMENTED by recompiles, not simply too small."
        log_info "Do this FIRST (before sizing up): opcache_reset() / restart LiteSpeed, and set"
        log_info "     opcache.validate_timestamps=0 (+ a deploy-time reset hook) to stop the recompile churn."
        if [ "$self_fixable" != true ]; then
            log_info "     Note: validate_timestamps is PHP_INI_ALL — often settable via .user.ini even"
            log_info "     when memory_consumption (PHP_INI_SYSTEM) is locked on shared hosting."
        fi
        return 1
    fi

    # Trigger-specific remediation — name the directive that actually fired.
    local target_mb files_target
    target_mb=$(_opc_round_mb "$(( (pool_mb * 2) + 1 ))")
    files_target=$(_opc_pow2_above "${scripts:-0}")
    if [ "$self_fixable" = true ]; then
        log_info "Fix (you can write ${LSO_PHP_INI:-the lsphp php.ini}); raise then restart LiteSpeed:"
        [ "$t_oom" = true ]      && log_info "     opcache.memory_consumption=${target_mb} + opcache.validate_timestamps=0  # stop OOM thrashing"
        [ "$t_mem" = true ]      && log_info "     opcache.memory_consumption=${target_mb}        # ~2x current ${pool_mb}MB (pool full)"
        [ "$t_keys" = true ]     && log_info "     opcache.max_accelerated_files=${files_target}  # > ${scripts:-?} cached scripts (PHP rounds to next prime)"
        [ "$t_interned" = true ] && log_info "     opcache.interned_strings_buffer=32-64          # interned buffer full"
        [ "$t_hit" = true ]      && log_info "     opcache.memory_consumption=${target_mb}        # low hit-rate under memory pressure = evictions"
    else
        log_warn "opcache.memory_consumption / max_accelerated_files are PHP_INI_SYSTEM and not writable here."
        log_warn "On shared/managed hosting they are usually not raisable per-account — Contact your host to"
        log_warn "raise the directive(s) above (pool ${pool_mb}MB); an unappliable php.ini snippet won't help."
        log_info "     (opcache.validate_timestamps IS PHP_INI_ALL — you may still set it via .user.ini.)"
    fi
    return 1
}
