#!/bin/bash
################################################################################
# analyzer.sh - Scored Audit 0-100 (SPEC §3)
################################################################################
# Weighted checks across server / PHP / cache / object-cache / security
# dimensions, each with a FIX hint. Checks that cannot run in the current
# environment (no wp-cli, no live server) are SKIPPED and excluded from the
# denominator, so the score reflects only what was actually examined.
#
# Danger findings (red) cap the score at 59 regardless of other results.
################################################################################

_AZ_GOT=0
_AZ_TOTAL=0
_AZ_DANGER=0
_AZ_JSON_ITEMS=""

# _az_check <weight> <category> <name> <status:pass|fail|skip> <fix-hint>
_az_check() {
    local weight="$1" category="$2" name="$3" status="$4" fix="$5"

    case "$status" in
        pass)
            _AZ_TOTAL=$((_AZ_TOTAL + weight))
            _AZ_GOT=$((_AZ_GOT + weight))
            [ "${JSON_OUTPUT:-false}" = true ] || log_success "  [${category}] ${name}"
            ;;
        fail)
            _AZ_TOTAL=$((_AZ_TOTAL + weight))
            if [ "${JSON_OUTPUT:-false}" != true ]; then
                log_warn "  [${category}] ${name}"
                [ -n "$fix" ] && echo "       FIX: ${fix}"
            fi
            ;;
        danger)
            _AZ_TOTAL=$((_AZ_TOTAL + weight))
            _AZ_DANGER=$((_AZ_DANGER + 1))
            if [ "${JSON_OUTPUT:-false}" != true ]; then
                log_error "  [${category}] DANGER: ${name}"
                [ -n "$fix" ] && echo "       FIX: ${fix}"
            fi
            ;;
        skip)
            [ "${JSON_OUTPUT:-false}" = true ] || \
                [ "${VERBOSE:-false}" != true ] || log_info "  [${category}] skipped: ${name}"
            ;;
    esac

    if [ "${JSON_OUTPUT:-false}" = true ]; then
        local entry
        entry=$(printf '{"category":"%s","check":"%s","status":"%s","weight":%s,"fix":"%s"}' \
            "$category" "$name" "$status" "$weight" "$fix")
        if [ -n "$_AZ_JSON_ITEMS" ]; then
            _AZ_JSON_ITEMS="${_AZ_JSON_ITEMS},${entry}"
        else
            _AZ_JSON_ITEMS="$entry"
        fi
    fi
}

# Numeric helper: pass/fail by comparison; empty value -> fail
_az_num_ok() {
    local val="$1" op="$2" want="$3"
    [ -n "$val" ] || return 1
    case "$val" in *[!0-9]*) return 1 ;; esac
    case "$op" in
        ge) [ "$val" -ge "$want" ] ;;
        le) [ "$val" -le "$want" ] ;;
        eq) [ "$val" -eq "$want" ] ;;
    esac
}

run_analyze() {
    # ($1 = target site — reserved; v0.1 analyzes the first detected WP site)
    if ! detect_environment; then
        log_error "No LiteSpeed installation found — nothing to analyze"
        exit 1
    fi

    _AZ_GOT=0; _AZ_TOTAL=0; _AZ_DANGER=0; _AZ_JSON_ITEMS=""

    local conf="${LSO_MAIN_CONF:-}"
    local ram cores tier
    ram=$(sysinfo_ram_mb)
    cores=$(sysinfo_cpu_cores)
    tier=$(sysinfo_ram_tier)

    if [ "${JSON_OUTPUT:-false}" != true ]; then
        echo ""
        echo "=== litespeed-optimizer analyze: ${LSO_EDITION} (${LSO_PANEL}), tier ${tier} ==="
        echo ""
    fi

    local v

    ############################################################
    # Server / protocol
    ############################################################
    if [ "$LSO_EDITION" = "ols" ]; then
        v=$(ols_get "$conf" tuning maxConnections 2>/dev/null) || v=""
        if _az_num_ok "$v" ge "$(lso_max_connections "$ram")"; then
            _az_check 5 server "maxConnections >= tier value ($v)" pass ""
        else
            _az_check 5 server "maxConnections below tier (got '${v:-unset}', want $(lso_max_connections "$ram"))" fail "optimize --feature server-tuning"
        fi

        v=$(ols_get "$conf" tuning keepAliveTimeout 2>/dev/null) || v=""
        if _az_num_ok "$v" ge 2 && _az_num_ok "$v" le 5; then
            _az_check 3 server "keepAliveTimeout in 2-5s ($v)" pass ""
        else
            _az_check 3 server "keepAliveTimeout out of 2-5s range ('${v:-unset}')" fail "optimize --feature server-tuning"
        fi

        v=$(ols_get "$conf" tuning gzipAutoUpdateStatic 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 3 server "gzipAutoUpdateStatic on" pass ""
        else
            _az_check 3 server "gzipAutoUpdateStatic off (static gzip never refreshes)" fail "optimize --feature server-tuning"
        fi

        v=$(ols_get "$conf" tuning enableBr 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 3 server "Brotli compression enabled" pass ""
        else
            _az_check 3 server "Brotli not enabled" fail "optimize --feature server-tuning"
        fi
    else
        _az_check 14 server "tuning{} values (Enterprise XML — verify in WebAdmin)" skip ""
    fi

    ############################################################
    # PHP capacity
    ############################################################
    if [ "$LSO_EDITION" = "ols" ]; then
        local maxconns children want_children
        maxconns=$(ols_get "$conf" "extprocessor lsphp" maxConns 2>/dev/null) || maxconns=""
        children=$(ols_get_env "$conf" "extprocessor lsphp" PHP_LSAPI_CHILDREN 2>/dev/null) || children=""
        want_children=$(lso_children "$ram" "$cores" "${LSO_LSPHP_RSS_MB:-80}")

        if [ -n "$maxconns" ] && [ "$maxconns" = "$children" ]; then
            _az_check 8 php "maxConns == PHP_LSAPI_CHILDREN (${maxconns})" pass ""
        else
            _az_check 8 php "maxConns (${maxconns:-unset}) != PHP_LSAPI_CHILDREN (${children:-unset}) — requests queue or RAM blows" fail "optimize --feature lsapi-tuning"
        fi

        # children within ±40% of formula
        if [ -n "$children" ] && case "$children" in *[!0-9]*) false ;; *) true ;; esac; then
            local lo=$(( want_children * 60 / 100 )) hi=$(( want_children * 140 / 100 ))
            if [ "$children" -ge "$lo" ] && [ "$children" -le "$hi" ]; then
                _az_check 6 php "PHP children within ±40% of formula (${children} vs ${want_children})" pass ""
            else
                _az_check 6 php "PHP children ${children} outside ±40% of formula value ${want_children}" fail "optimize --feature lsapi-tuning"
            fi
        else
            _az_check 6 php "PHP_LSAPI_CHILDREN not set" fail "optimize --feature lsapi-tuning"
        fi

        v=$(ols_get_env "$conf" "extprocessor lsphp" LSAPI_AVOID_FORK 2>/dev/null) || v=""
        if [ "$v" = "$(lso_avoid_fork "$ram")" ]; then
            _az_check 3 php "LSAPI_AVOID_FORK matches tier ($v)" pass ""
        elif [ "$v" = "1" ] && [ "$ram" -lt 2048 ]; then
            _az_check 3 php "LSAPI_AVOID_FORK=1 on a <2GB box (prefork eats free RAM)" fail "optimize --feature lsapi-tuning"
        else
            _az_check 3 php "LSAPI_AVOID_FORK is '${v:-unset}' (tier value: $(lso_avoid_fork "$ram"))" fail "optimize --feature lsapi-tuning"
        fi

        if [ "$tier" != "1g" ]; then
            v=$(ols_get_env "$conf" "extprocessor lsphp" LSAPI_PGRP_MAX_IDLE 2>/dev/null) || v=""
            if _az_num_ok "$v" ge 3600; then
                _az_check 3 php "LSAPI_PGRP_MAX_IDLE >= 3600" pass ""
            else
                _az_check 3 php "LSAPI_PGRP_MAX_IDLE missing/low — parent process churns" fail "optimize --feature lsapi-tuning"
            fi
        fi
    else
        _az_check 20 php "LSAPI settings (Enterprise — check LSPHP_Workers in Apache include)" skip ""
    fi

    ############################################################
    # OPcache
    ############################################################
    local scan_dir=""
    if type -t _opcache_scan_dir &>/dev/null; then
        scan_dir=$(_opcache_scan_dir 2>/dev/null) || scan_dir=""
    fi
    if [ -n "$scan_dir" ] && [ -f "${scan_dir}/${OPCACHE_INI_NAME:-99-litespeed-optimizer-opcache.ini}" ]; then
        _az_check 5 opcache "OPcache drop-in deployed" pass ""
        v=$(grep "memory_consumption" "${scan_dir}/${OPCACHE_INI_NAME}" | head -1 | sed 's/.*=//')
        if _az_num_ok "$v" ge "$(lso_opcache_mb "$ram")"; then
            _az_check 5 opcache "OPcache memory >= tier value (${v}MB)" pass ""
        else
            _az_check 5 opcache "OPcache memory below tier (${v:-?}MB < $(lso_opcache_mb "$ram")MB)" fail "optimize --feature opcache"
        fi
    else
        _az_check 10 opcache "OPcache drop-in not deployed" fail "optimize --feature opcache"
    fi

    ############################################################
    # Page cache
    ############################################################
    if [ "$LSO_EDITION" = "ols" ]; then
        v=$(ols_get "$conf" "module cache" enableCache 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 8 cache "enableCache 1 SERVER-WIDE — caches carts/sessions for everyone" danger "optimize --feature lscache (sets enableCache 0; LSCWP drives caching)"
        elif [ "$v" = "0" ]; then
            _az_check 8 cache "server-level enableCache 0 (LSCWP drives caching)" pass ""
        else
            _az_check 8 cache "server cache module not configured" fail "optimize --feature lscache"
        fi

        v=$(ols_get "$conf" "module cache" checkPublicCache 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 8 cache "checkPublicCache on" pass ""
        else
            _az_check 8 cache "checkPublicCache off — public cache never consulted" fail "optimize --feature lscache"
        fi
        # Vhost rewrite engine: with rewrite disabled, LSCWP's .htaccess vary
        # rules never run on OLS -> cart/cookie vary breaks (cache poisoning).
        # Found empirically in the WP+Woo Docker E2E.
        if [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ] && [ -d "${LSO_VHOSTS_DIR:-/nonexistent}" ]; then
            local vh_bad="" vhconf
            for vhconf in "${LSO_VHOSTS_DIR}"/*/vhconf.conf; do
                [ -f "$vhconf" ] || continue
                if awk '/^rewrite[[:space:]]*\{/,/\}/' "$vhconf" | grep -qE 'enable[[:space:]]+0'; then
                    vh_bad="${vh_bad} $(basename "$(dirname "$vhconf")")"
                fi
            done
            if [ -n "$vh_bad" ]; then
                _az_check 5 cache "vhost rewrite DISABLED (${vh_bad# }) — LSCWP vary cookies dead, carts can cache-poison" danger "set 'rewrite { enable 1, autoLoadHtaccess 1 }' in vhconf.conf and restart"
            else
                _az_check 5 cache "vhost rewrite engine enabled (LSCWP vary cookies functional)" pass ""
            fi
        fi
    else
        _az_check 16 cache "CacheRoot/CacheEngine (Enterprise include)" skip ""
    fi

    ############################################################
    # LSCWP / object cache / security-in-WP (wp-cli needed)
    ############################################################
    local have_wp=false docroot=""
    if type -t _lscwp_have_wpcli &>/dev/null && _lscwp_have_wpcli && \
       [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ]; then
        have_wp=true
        docroot="${LSO_WP_SITES[0]}"
    fi

    if [ "$have_wp" = true ]; then
        v=$(lso_wp "$docroot" litespeed-option get cache-ttl_pub 2>/dev/null) || v=""
        if [ "$v" = "604800" ]; then
            _az_check 5 cache "LSCWP public TTL 604800" pass ""
        else
            _az_check 5 cache "LSCWP public TTL is '${v:-unset}' (want 604800)" fail "optimize --feature lscwp"
        fi

        v=$(lso_wp "$docroot" litespeed-option get purge-stale 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 4 cache "Serve stale enabled" pass ""
        else
            _az_check 4 cache "Serve stale off — visitors wait on purges" fail "optimize --feature lscwp"
        fi

        v=$(lso_wp "$docroot" litespeed-option get object 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 3 objcache "LSCWP object cache on" pass ""
            v=$(lso_wp "$docroot" litespeed-option get object-life 2>/dev/null) || v=""
            if _az_num_ok "$v" ge 600; then
                _az_check 3 objcache "object cache lifetime >= 600 ($v)" pass ""
            else
                _az_check 3 objcache "object lifetime '${v:-unset}' < 600 breaks Woo sessions" fail "optimize --feature lscwp"
            fi
        else
            _az_check 6 objcache "LSCWP object cache off" fail "optimize --feature lscwp"
        fi

        v=$(lso_wp "$docroot" litespeed-option get debug 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 3 security "LSCWP debug log ON (CVE-2024-44000 surface)" danger "wp litespeed-option set debug 0"
        else
            _az_check 3 security "LSCWP debug log off" pass ""
        fi

        v=$(lso_wp "$docroot" litespeed-option get cache-exc_cookies 2>/dev/null) || v=""
        if echo "$v" | grep -q "woocommerce_items_in_cart"; then
            _az_check 4 cache "woocommerce_items_in_cart in Do-Not-Cache Cookies — caching dead for cart holders" danger "remove it: LSCWP already varies on this cookie"
        else
            _az_check 4 cache "no cart-cookie cache-kill misconfig" pass ""
        fi

        v=$(lso_wp "$docroot" plugin get litespeed-cache --field=version 2>/dev/null) || v=""
        if [ -n "$v" ] && version_ge "$v" "6.5.1"; then
            _az_check 3 security "LSCWP version ${v} >= 6.5.1 (CVE gate)" pass ""
        else
            _az_check 3 security "LSCWP version '${v:-not installed}' below CVE-safe 6.5.1" fail "wp plugin update litespeed-cache"
        fi
    else
        _az_check 22 cache "LSCWP checks (wp-cli or WP sites unavailable)" skip ""
    fi

    # Redis presence (server-side)
    if [ "${LSO_HAS_REDIS:-false}" = true ]; then
        _az_check 4 objcache "Redis present" pass ""
    else
        _az_check 4 objcache "Redis not installed — no object cache backend" fail "apt install redis-server, then optimize --feature lscwp"
    fi

    ############################################################
    # Security (server-level)
    ############################################################
    if [ "$LSO_EDITION" = "ols" ]; then
        v=$(ols_get "$conf" perClientConnLimit dynReqPerSec 2>/dev/null) || v=""
        if _az_num_ok "$v" ge 1 && _az_num_ok "$v" le 5; then
            _az_check 4 security "dynReqPerSec throttling sane ($v)" pass ""
        else
            _az_check 4 security "dynReqPerSec is '${v:-unset}' (0/unset = no dynamic throttle)" fail "optimize --feature security"
        fi

        v=$(ols_get "$conf" perClientConnLimit blockBadReq 2>/dev/null) || v=""
        if [ "$v" = "1" ]; then
            _az_check 3 security "blockBadReq on" pass ""
        else
            _az_check 3 security "blockBadReq off" fail "optimize --feature security"
        fi

        v=$(ols_get "$conf" perClientConnLimit banPeriod 2>/dev/null) || v=""
        if _az_num_ok "$v" ge 300; then
            _az_check 2 security "banPeriod >= 300s" pass ""
        else
            _az_check 2 security "banPeriod '${v:-unset}' < 300s" fail "optimize --feature security"
        fi
    else
        if [ -n "${LSO_APACHE_INCLUDE:-}" ] && grep -q "WordPressProtect" "$LSO_APACHE_INCLUDE" 2>/dev/null; then
            _az_check 9 security "WordPressProtect active (Enterprise)" pass ""
        else
            _az_check 9 security "WordPressProtect not configured" fail "optimize --feature security"
        fi
    fi

    ############################################################
    # Score
    ############################################################
    local score=0
    [ "$_AZ_TOTAL" -gt 0 ] && score=$(( _AZ_GOT * 100 / _AZ_TOTAL ))
    if [ "$_AZ_DANGER" -gt 0 ] && [ "$score" -gt 59 ]; then
        score=59
    fi

    local grade
    if   [ "$score" -ge 90 ]; then grade="A"
    elif [ "$score" -ge 80 ]; then grade="B"
    elif [ "$score" -ge 70 ]; then grade="C"
    elif [ "$score" -ge 60 ]; then grade="D"
    else grade="F"; fi

    if [ "${JSON_OUTPUT:-false}" = true ]; then
        json_output "$(printf '{"command":"analyze","version":"%s","edition":"%s","panel":"%s","tier":"%s","score":%s,"grade":"%s","danger_findings":%s,"checks":[%s]}' \
            "${VERSION:-?}" "$LSO_EDITION" "$LSO_PANEL" "$tier" "$score" "$grade" "$_AZ_DANGER" "$_AZ_JSON_ITEMS")"
    else
        echo ""
        echo "==========================================================="
        if [ "$_AZ_DANGER" -gt 0 ]; then
            log_error "SCORE: ${score}/100 (grade ${grade}) — ${_AZ_DANGER} DANGER finding(s) cap the score at 59"
        else
            log_info "SCORE: ${score}/100 (grade ${grade}) — ${_AZ_GOT}/${_AZ_TOTAL} weighted points"
        fi
        echo "==========================================================="
    fi

    [ "$_AZ_DANGER" -eq 0 ]
}
