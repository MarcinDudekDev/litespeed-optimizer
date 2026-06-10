#!/bin/bash
################################################################################
# remote-analyzer.sh - HTTP-Only Remote Audit (analyze --remote <url>)
################################################################################
# Scores a LIVE site over plain HTTP — zero server access (shared-hosting /
# no-SSH scenario). Reuses the weighted _az_check scoring from analyzer.sh;
# FIX hints are phrased for no-SSH contexts ("fix in LSCWP admin", "ask host").
#
# SAFETY / POLITENESS (hard rules):
# - GET/HEAD only, anonymous only — never any login flow, never POST
# - rate-limited: sleep LSO_REMOTE_DELAY (default 1s) between requests
# - hard cap LSO_REMOTE_MAX (default 25) requests per run
# - identifying User-Agent pointing at the project repo
# - ONLY run this against sites you own or manage.
#
# The "vary-poisoning signature" check comes from the WP+Woo Docker E2E
# finding: a response carrying BOTH x-litespeed-cache-control: no-cache AND
# x-litespeed-cache: hit means the server serves stale cache copies that PHP
# asked it not to — typically vhost rewrite disabled killing LSCWP vary.
################################################################################

LSO_REMOTE_UA=""
_RM_REQ_COUNT=0
_RM_HDR_FILE=""
_RM_BODY_FILE=""

# _rm_request <url> [cookie-jar] [extra-curl-args...]
# Rate-limited GET; headers -> $_RM_HDR_FILE, body -> $_RM_BODY_FILE.
# Returns 1 when the request cap is reached or curl fails.
_rm_request() {
    local url="$1"
    local jar="${2:-}"
    shift 2 2>/dev/null || shift $#

    local cap="${LSO_REMOTE_MAX:-25}"
    if [ "$_RM_REQ_COUNT" -ge "$cap" ]; then
        log_warn "Remote request cap reached (${cap}) — remaining checks skipped"
        return 1
    fi
    if [ "$_RM_REQ_COUNT" -gt 0 ]; then
        sleep "${LSO_REMOTE_DELAY:-1}"
    fi
    _RM_REQ_COUNT=$((_RM_REQ_COUNT + 1))

    local jar_args=""
    [ -n "$jar" ] && jar_args="-c $jar -b $jar"

    # shellcheck disable=SC2086
    curl -sL -m 15 -A "$LSO_REMOTE_UA" $jar_args "$@" \
        -D "$_RM_HDR_FILE" -o "$_RM_BODY_FILE" "$url" 2>/dev/null
}

# _rm_header <name> — print value of header from the last response (lowercased name match)
_rm_header() {
    tr -d '\r' < "$_RM_HDR_FILE" | awk -F': ' -v h="$1" 'tolower($1) == h { print substr($0, index($0, ": ") + 2); exit }'
}

# _rm_ttfb <url> — single timed probe (counts against the cap)
_rm_ttfb() {
    local url="$1"
    local cap="${LSO_REMOTE_MAX:-25}"
    [ "$_RM_REQ_COUNT" -ge "$cap" ] && return 1
    sleep "${LSO_REMOTE_DELAY:-1}"
    _RM_REQ_COUNT=$((_RM_REQ_COUNT + 1))
    { curl -s -o /dev/null -m 15 -A "$LSO_REMOTE_UA" \
        -w '%{time_starttransfer}' "$url" 2>/dev/null || true; } | \
        awk '{ printf "%.0f", $1 * 1000 }'
}

# The E2E-discovered poisoning signature: no-cache + hit on the SAME response
_rm_check_poison_signature() {
    local label="$1"
    local ctl cache
    ctl=$(_rm_header "x-litespeed-cache-control")
    cache=$(_rm_header "x-litespeed-cache")
    if echo "$ctl" | grep -qi "no-cache" && echo "$cache" | grep -qi "hit"; then
        _az_check 8 cache "${label}: no-cache + HIT on one response — server serves cache copies PHP forbade (vary broken)" danger \
            "vhost rewrite is likely disabled, killing LSCWP vary cookies. Ask the host to set 'rewrite { enable 1, autoLoadHtaccess 1 }' for your vhost (see project README)"
        return 1
    fi
    return 0
}

run_remote_analyze() {
    local url="$1"

    case "$url" in
        http://*|https://*) ;;
        *) log_error "analyze --remote requires a full URL (http:// or https://)"; exit 1 ;;
    esac
    url="${url%/}/"

    LSO_REMOTE_UA="litespeed-optimizer/${VERSION:-dev} (+https://github.com/MarcinDudekDev/litespeed-optimizer; remote-audit; operator-owned-site)"
    _RM_REQ_COUNT=0
    _RM_HDR_FILE=$(secure_mktemp "${TMPDIR:-/tmp}/lso-rm-hdr.XXXXXX")
    _RM_BODY_FILE=$(secure_mktemp "${TMPDIR:-/tmp}/lso-rm-body.XXXXXX")
    local jar_a jar_b
    jar_a=$(secure_mktemp "${TMPDIR:-/tmp}/lso-rm-jar.XXXXXX")
    jar_b=$(secure_mktemp "${TMPDIR:-/tmp}/lso-rm-jar.XXXXXX")
    # shellcheck disable=SC2064  # expand now: temp paths are fixed at this point
    trap "rm -f '$_RM_HDR_FILE' '$_RM_BODY_FILE' '$jar_a' '$jar_b'" RETURN 2>/dev/null || true

    _AZ_GOT=0; _AZ_TOTAL=0; _AZ_DANGER=0; _AZ_JSON_ITEMS=""

    if [ "${JSON_OUTPUT:-false}" != true ]; then
        echo ""
        echo "=== litespeed-optimizer analyze --remote: ${url} ==="
        echo "    (GET/HEAD only, anonymous, rate-limited, max ${LSO_REMOTE_MAX:-25} requests)"
        echo ""
    fi

    ############################################################
    # 1. Reachability + LiteSpeed detection
    ############################################################
    if ! _rm_request "$url"; then
        log_error "Site unreachable: $url"
        exit 1
    fi
    local server status
    status=$(tr -d '\r' < "$_RM_HDR_FILE" | awk 'NR==1 {print $2}')
    server=$(_rm_header "server")

    if echo "$server" | grep -qi "litespeed"; then
        _az_check 3 server "served by LiteSpeed (HTTP ${status})" pass ""
    else
        _az_check 3 server "server header is '${server:-absent}' — not LiteSpeed (or hidden by CDN)" fail \
            "if behind Cloudflare, LiteSpeed headers may be stripped; audit the origin URL directly"
    fi

    # Cloudflare cache-everything in front of HTML is a danger (SPEC §3)
    local cf
    cf=$(_rm_header "cf-cache-status")
    if [ "$cf" = "HIT" ]; then
        _az_check 4 cache "Cloudflare serves cached HTML (cf-cache-status: HIT) — LSCache/LSCWP purges never reach visitors" danger \
            "remove the cache-everything page rule for HTML, or integrate via the LSCWP Cloudflare/QUIC.cloud CDN settings"
    fi

    local is_woo=false
    if grep -qi "woocommerce" "$_RM_BODY_FILE" 2>/dev/null; then
        is_woo=true
    fi

    ############################################################
    # 2. Page cache: second request must HIT
    ############################################################
    _rm_request "$url" || true
    local cache_hdr
    cache_hdr=$(_rm_header "x-litespeed-cache")
    if echo "$cache_hdr" | grep -qi "hit"; then
        _az_check 10 cache "homepage cached (x-litespeed-cache: ${cache_hdr})" pass ""
    elif [ -n "$cache_hdr" ]; then
        _az_check 10 cache "homepage not cached on repeat request (x-litespeed-cache: ${cache_hdr})" fail \
            "check LSCWP admin: Cache > Enable Cache ON; TTL > 0; look for cookie/query-string excludes that match every visitor"
    else
        _az_check 10 cache "x-litespeed-cache header absent — page cache not active" fail \
            "install/enable the LiteSpeed Cache plugin (wp-admin > Plugins); if installed, ask the host whether LSCache is enabled for your account"
    fi
    _rm_check_poison_signature "homepage" || true

    # TTL / age headers (informational quality signal)
    local age cc
    age=$(_rm_header "age")
    cc=$(_rm_header "cache-control")
    if echo "$cc" | grep -qE "max-age=[1-9]" || [ -n "$age" ]; then
        _az_check 2 cache "cache freshness headers present (cache-control: ${cc:-n/a}${age:+, age: $age})" pass ""
    else
        _az_check 2 cache "no cache-control max-age / age headers on homepage" fail \
            "set Browser Cache TTL in LSCWP admin (Cache > Browser)"
    fi

    ############################################################
    # 3. Protocol + compression
    ############################################################
    local altsvc
    altsvc=$(_rm_header "alt-svc")
    if echo "$altsvc" | grep -q "h3"; then
        _az_check 5 protocol "HTTP/3 advertised (alt-svc: h3)" pass ""
    else
        _az_check 5 protocol "no HTTP/3 advertisement (alt-svc header)" fail \
            "ask the host to enable QUIC/HTTP3 and open UDP 443 (often disabled by CSF UDPFLOOD)"
    fi

    _rm_request "$url" "" -H "Accept-Encoding: br, gzip" || true
    local enc
    enc=$(_rm_header "content-encoding")
    case "$enc" in
        *br*)   _az_check 4 protocol "Brotli compression active" pass ""
                _az_check 2 protocol "gzip fallback assumed (brotli preferred)" pass "" ;;
        *gzip*) _az_check 4 protocol "Brotli not served (got gzip)" fail "ask the host to enable Brotli (tuning > enableBr) — smaller pages than gzip"
                _az_check 2 protocol "gzip compression active" pass "" ;;
        *)      _az_check 4 protocol "no Brotli compression" fail "ask the host to enable compression"
                _az_check 2 protocol "no gzip compression either — uncompressed HTML" fail "ask the host to enable enableGzipCompress" ;;
    esac

    ############################################################
    # 4. Security headers (from the homepage response)
    ############################################################
    local h
    h=$(_rm_header "x-content-type-options")
    if echo "$h" | grep -qi "nosniff"; then
        _az_check 2 security "x-content-type-options: nosniff" pass ""
    else
        _az_check 2 security "x-content-type-options missing" fail "add security headers via LSCWP or ask the host (nosniff)"
    fi
    h=$(_rm_header "x-frame-options")
    local csp
    csp=$(_rm_header "content-security-policy")
    if [ -n "$h" ] || echo "$csp" | grep -qi "frame-ancestors"; then
        _az_check 2 security "clickjacking protection (x-frame-options/CSP)" pass ""
    else
        _az_check 2 security "no x-frame-options / frame-ancestors" fail "add X-Frame-Options: SAMEORIGIN via .htaccess or host panel"
    fi
    h=$(_rm_header "referrer-policy")
    if [ -n "$h" ]; then
        _az_check 2 security "referrer-policy set (${h})" pass ""
    else
        _az_check 2 security "referrer-policy missing" fail "add Referrer-Policy: strict-origin-when-cross-origin"
    fi
    case "$url" in
        https://*)
            h=$(_rm_header "strict-transport-security")
            if [ -n "$h" ]; then
                _az_check 2 security "HSTS active" pass ""
            else
                _az_check 2 security "HSTS missing on an https site" fail "add Strict-Transport-Security via .htaccess or host panel"
            fi
            ;;
    esac
    h=$(_rm_header "x-powered-by")
    if [ -n "$h" ]; then
        _az_check 1 security "x-powered-by leaks stack info (${h})" fail "hide via expose_php=Off / host panel"
    else
        _az_check 1 security "no x-powered-by leakage" pass ""
    fi

    ############################################################
    # 5. TTFB (3 timed probes; homepage is warm by now)
    ############################################################
    local t1 t2 t3 median
    t1=$(_rm_ttfb "$url"); t2=$(_rm_ttfb "$url"); t3=$(_rm_ttfb "$url")
    if [ -n "$t1" ] && [ -n "$t2" ] && [ -n "$t3" ]; then
        median=$(printf '%s\n%s\n%s\n' "$t1" "$t2" "$t3" | sort -n | awk 'NR==2')
        if [ "$median" -lt 800 ]; then
            _az_check 5 server "warm TTFB median ${median}ms (<800ms)" pass ""
        else
            _az_check 5 server "warm TTFB median ${median}ms (>=800ms)" fail \
                "with cache HITs this should be <200ms — if cache misses persist, fix caching first"
        fi
    fi

    ############################################################
    # 6. WooCommerce probes
    ############################################################
    if [ "$is_woo" = true ]; then
        [ "${JSON_OUTPUT:-false}" = true ] || log_info "WooCommerce detected — running store probes"

        # Discover one product via the public Store API (GET, anonymous)
        local prod_url="" prod_name="" prod_id=""
        if _rm_request "${url}?rest_route=/wc/store/v1/products&per_page=1" ""; then
            prod_url=$(sed -n 's/.*"permalink":"\([^"]*\)".*/\1/p' "$_RM_BODY_FILE" | head -1 | sed 's|\\/|/|g')
            prod_name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$_RM_BODY_FILE" | head -1)
            prod_id=$(sed -n 's/.*\[{"id":\([0-9]*\).*/\1/p' "$_RM_BODY_FILE" | head -1)
        fi

        if [ -n "$prod_url" ]; then
            _rm_request "$prod_url" || true
            _rm_request "$prod_url" || true
            cache_hdr=$(_rm_header "x-litespeed-cache")
            if echo "$cache_hdr" | grep -qi "hit"; then
                _az_check 8 woo "product page cached (x-litespeed-cache: hit)" pass ""
            else
                _az_check 8 woo "product page NOT cached (${cache_hdr:-header absent})" fail \
                    "product pages are the money pages — verify LSCWP cache enabled and no vary/cookie excludes match guests"
            fi
            _rm_check_poison_signature "product page" || true
        else
            _az_check 8 woo "no public product found via Store API" skip ""
        fi

        # Cart endpoints must never be cache HITs. Only HTTP 200 counts —
        # localized shops (e.g. /koszyk/) 404 on /cart/, and a CACHED 404 is
        # harmless, not a poisoning signal (real-world false positive on a
        # Polish production shop). Non-200 -> probe the localized URL via the
        # homepage's cart link when discoverable.
        local cart_status cart_probe_url="${url}cart/"
        _rm_request "$cart_probe_url" || true
        cart_status=$(tr -d '\r' < "$_RM_HDR_FILE" | awk 'NR==1 {print $2}')
        if [ "$cart_status" != "200" ]; then
            # Try to discover the localized cart URL from the homepage HTML
            _rm_request "$url" || true
            local discovered
            discovered=$(grep -oE 'href="[^"]*"[^>]*class="[^"]*cart[^"]*"|class="[^"]*cart[^"]*"[^>]*href="[^"]*"' "$_RM_BODY_FILE" 2>/dev/null | \
                sed -n 's/.*href="\([^"]*\)".*/\1/p' | grep -E "^${url%/}|^/" | head -1)
            if [ -n "$discovered" ]; then
                case "$discovered" in
                    /*) discovered="${url%/}${discovered}" ;;
                esac
                cart_probe_url="$discovered"
                _rm_request "$cart_probe_url" || true
                cart_status=$(tr -d '\r' < "$_RM_HDR_FILE" | awk 'NR==1 {print $2}')
            fi
        fi
        cache_hdr=$(_rm_header "x-litespeed-cache")
        if [ "$cart_status" = "200" ] && echo "$cache_hdr" | grep -qi "hit"; then
            _az_check 8 woo "cart page (${cart_probe_url}) served from cache — visitors can see each other's carts" danger \
                "NEVER cache the cart. Check LSCWP: WooCommerce integration active; cart page set in Woo settings; purge all after fixing"
        elif [ "$cart_status" = "200" ]; then
            _az_check 8 woo "cart page not cache-served (${cache_hdr:-no cache header})" pass ""
        else
            _az_check 8 woo "cart page URL not found (HTTP ${cart_status} on ${cart_probe_url} — localized slug?)" skip ""
        fi

        local co_status
        _rm_request "${url}checkout/" || true
        co_status=$(tr -d '\r' < "$_RM_HDR_FILE" | awk 'NR==1 {print $2}')
        cache_hdr=$(_rm_header "x-litespeed-cache")
        if [ "$co_status" = "200" ] && echo "$cache_hdr" | grep -qi "hit"; then
            _az_check 4 woo "/checkout/ served from cache" danger "NEVER cache checkout — same fix as cart"
        elif [ "$co_status" = "200" ]; then
            _az_check 4 woo "checkout not cache-served" pass ""
        else
            _az_check 4 woo "checkout URL not found (HTTP ${co_status} — localized slug?)" skip ""
        fi

        _rm_request "${url}?wc-ajax=get_refreshed_fragments" || true
        cache_hdr=$(_rm_header "x-litespeed-cache")
        if echo "$cache_hdr" | grep -qi "hit"; then
            _az_check 3 woo "wc-ajax responses are cached — mini-cart will show stale data" fail \
                "exclude wc-ajax in LSCWP (usually automatic — check Do-Not-Cache URIs)"
        else
            _az_check 3 woo "wc-ajax not cache-served" pass ""
        fi

        # Cart Store API cacheability — INDEPENDENT of product discovery so it
        # always runs (the cache-rest=1 trap; reproduced on a live production
        # shop). The endpoint is per-session data and must never be a cache HIT.
        _rm_request "${url}?rest_route=/wc/store/v1/cart" || true
        _rm_check_poison_signature "cart API" || true
        cache_hdr=$(_rm_header "x-litespeed-cache")
        if echo "$cache_hdr" | grep -qi "hit"; then
            _az_check 4 woo "cart Store API served from cache — stale/foreign cart JSON to cookieless visitors" danger \
                "set 'Cache REST API' OFF in LSCWP (Cache > Cache REST API) — the cart endpoint is per-session data"
        else
            _az_check 4 woo "cart Store API not cache-served (${cache_hdr:-no cache header})" pass ""
        fi

        # Two-session isolation probe (anonymous, GET-only): session A adds the
        # discovered product to ITS OWN anonymous cart, session B must not see it.
        if [ -n "$prod_id" ] && [ -n "$prod_name" ]; then
            _rm_request "${url}?add-to-cart=${prod_id}" "$jar_a" || true
            _rm_request "${url}?rest_route=/wc/store/v1/cart" "$jar_a" || true
            local cart_a_has=false
            grep -q "$prod_name" "$_RM_BODY_FILE" 2>/dev/null && cart_a_has=true
            _rm_request "${url}?rest_route=/wc/store/v1/cart" "$jar_b" || true
            local cart_b_has=false
            grep -q "$prod_name" "$_RM_BODY_FILE" 2>/dev/null && cart_b_has=true

            if [ "$cart_a_has" = true ] && [ "$cart_b_has" = true ]; then
                _az_check 8 woo "SESSION ISOLATION BROKEN — a fresh visitor sees another session's cart" danger \
                    "cookie vary is not working (often vhost rewrite disabled). Ask the host to enable the vhost rewrite engine; purge all caches"
            elif [ "$cart_a_has" = true ]; then
                _az_check 8 woo "two-session cart isolation OK" pass ""
            else
                _az_check 8 woo "isolation probe inconclusive (add-to-cart did not register — bot protection?)" skip ""
            fi
        else
            _az_check 8 woo "isolation probe skipped (no product id discoverable)" skip ""
        fi
    fi

    ############################################################
    # Score (same scale as local analyze)
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
        json_output "$(printf '{"command":"analyze-remote","version":"%s","url":"%s","requests_used":%s,"woocommerce":%s,"score":%s,"grade":"%s","danger_findings":%s,"checks":[%s]}' \
            "${VERSION:-?}" "$url" "$_RM_REQ_COUNT" "$is_woo" "$score" "$grade" "$_AZ_DANGER" "$_AZ_JSON_ITEMS")"
    else
        echo ""
        echo "==========================================================="
        if [ "$_AZ_DANGER" -gt 0 ]; then
            log_error "REMOTE SCORE: ${score}/100 (grade ${grade}) — ${_AZ_DANGER} DANGER finding(s) cap the score at 59"
        else
            log_info "REMOTE SCORE: ${score}/100 (grade ${grade}) — ${_AZ_GOT}/${_AZ_TOTAL} weighted points (${_RM_REQ_COUNT} requests used)"
        fi
        echo "==========================================================="
    fi

    rm -f "$_RM_HDR_FILE" "$_RM_BODY_FILE" "$jar_a" "$jar_b"
    [ "$_AZ_DANGER" -eq 0 ]
}
