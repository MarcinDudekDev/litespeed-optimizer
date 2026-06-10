#!/bin/bash
################################################################################
# benchmark.sh - TTFB Benchmark + Cache-Hit Verification (SPEC §2/§T4.3)
################################################################################
# curl ×N: dns/connect/tls/ttfb timings. First request is reported separately
# (typically the uncached MISS that primes the cache); the median of the rest
# approximates cached performance. Verifies the x-litespeed-cache header and
# optionally probes the cart URL (must NOT be cached).
#
# Results stored in $DATA_DIR/benchmarks/<timestamp>.json; the previous run is
# diffed for a before/after summary.
################################################################################

BENCH_RUNS="${LSO_BENCH_RUNS:-10}"

# _bench_median <newline-separated ms values>
_bench_median() {
    sort -n | awk '{ a[NR] = $1 } END {
        if (NR == 0) { print 0; exit }
        if (NR % 2) { print a[(NR + 1) / 2] }
        else { printf "%.1f\n", (a[NR/2] + a[NR/2 + 1]) / 2 }
    }'
}

# _bench_probe <url> -> "dns_ms connect_ms tls_ms ttfb_ms http_code"
_bench_probe() {
    local url="$1"
    local auth_args=""
    [ -n "${LSO_HTTP_AUTH:-}" ] && auth_args="--user ${LSO_HTTP_AUTH}"
    # curl failure must not trip set -o pipefail — empty output signals failure
    # shellcheck disable=SC2086
    { curl -o /dev/null -s -m 20 $auth_args \
        -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{http_code}' \
        "$url" 2>/dev/null || true; } | \
        awk 'NF >= 5 { printf "%.1f %.1f %.1f %.1f %s\n", $1*1000, $2*1000, $3*1000, $4*1000, $5 }'
}

# _bench_cache_header <url> -> value of x-litespeed-cache header (or empty)
_bench_cache_header() {
    local url="$1"
    local auth_args=""
    [ -n "${LSO_HTTP_AUTH:-}" ] && auth_args="--user ${LSO_HTTP_AUTH}"
    # shellcheck disable=SC2086
    { curl -sI -m 20 $auth_args "$url" 2>/dev/null || true; } | tr -d '\r' | \
        awk -F': ' 'tolower($1) == "x-litespeed-cache" { print $2; exit }'
}

run_benchmark() {
    local url="$1"

    case "$url" in
        http://*|https://*) ;;
        *) log_error "benchmark requires a full URL (http:// or https://)"; exit 1 ;;
    esac

    log_info "Benchmarking ${url} (${BENCH_RUNS} requests)..."

    local first="" ttfbs="" code="" i probe
    for i in $(seq 1 "$BENCH_RUNS"); do
        probe=$(_bench_probe "$url")
        code=$(echo "$probe" | awk '{print $5}')
        if [ -z "$probe" ] || [ -z "$code" ] || [ "$code" = "000" ]; then
            log_error "Request $i failed — is the URL reachable?"
            exit 1
        fi
        if [ "$i" -eq 1 ]; then
            first="$probe"
        else
            ttfbs="${ttfbs}$(echo "$probe" | awk '{print $4}')
"
        fi
    done

    local first_ttfb median_ttfb
    first_ttfb=$(echo "$first" | awk '{print $4}')
    median_ttfb=$(printf '%s' "$ttfbs" | _bench_median)

    # Cache header verification
    local cache_header
    cache_header=$(_bench_cache_header "$url")

    echo ""
    echo "=== Benchmark: ${url} ==="
    echo "  HTTP status:          ${code}"
    echo "  DNS/connect/TLS (ms): $(echo "$first" | awk '{printf "%s / %s / %s", $1, $2, $3}')"
    echo "  First request TTFB:   ${first_ttfb} ms  (typically uncached / cache-priming)"
    echo "  Median TTFB (warm):   ${median_ttfb} ms  ($((BENCH_RUNS - 1)) requests)"
    case "$cache_header" in
        hit*)  log_success "  x-litespeed-cache: ${cache_header} — page cache WORKING" ;;
        miss*) log_warn "  x-litespeed-cache: ${cache_header} — served but not cached (TTL? purge? vary?)" ;;
        "")    log_warn "  x-litespeed-cache header ABSENT — LSCache not active for this URL" ;;
        *)     log_info "  x-litespeed-cache: ${cache_header}" ;;
    esac

    # Cart probe (WooCommerce): cart must NEVER be served from cache
    local cart_header cart_url="${url%/}/cart/"
    if [ "${LSO_BENCH_CART:-1}" = "1" ]; then
        cart_header=$(_bench_cache_header "$cart_url")
        case "$cart_header" in
            hit*) log_error "  CART ${cart_url} served from cache — checkout data leakage risk!" ;;
            "")   log_info "  Cart probe: no cache header on ${cart_url} (good, or no Woo)" ;;
            *)    log_info "  Cart probe: x-litespeed-cache: ${cart_header} on cart (non-hit: OK)" ;;
        esac
    fi

    # Persist + before/after comparison
    local bench_dir="${DATA_DIR}/benchmarks"
    mkdir -p "$bench_dir"
    local prev out
    prev=$(ls -1t "$bench_dir"/*.json 2>/dev/null | head -1 || true)
    out="${bench_dir}/$(date +%Y%m%d-%H%M%S).json"
    printf '{"url":"%s","first_ttfb_ms":%s,"median_ttfb_ms":%s,"http_code":"%s","cache_header":"%s","runs":%s}\n' \
        "$url" "$first_ttfb" "$median_ttfb" "$code" "$cache_header" "$BENCH_RUNS" > "$out"
    log_info "Saved: $out"

    if [ -n "$prev" ] && grep -q "\"url\":\"$url\"" "$prev" 2>/dev/null; then
        local prev_median
        prev_median=$(sed -n 's/.*"median_ttfb_ms":\([0-9.]*\).*/\1/p' "$prev")
        if [ -n "$prev_median" ]; then
            echo ""
            log_info "Before/after (median TTFB): ${prev_median} ms -> ${median_ttfb} ms"
        fi
    fi
}
