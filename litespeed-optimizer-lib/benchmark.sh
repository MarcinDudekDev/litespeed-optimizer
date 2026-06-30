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
LOAD_CONCURRENCY="${LSO_LOAD_CONCURRENCY:-10}"
LOAD_DURATION="${LSO_LOAD_DURATION:-10}"

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
    local auth_args
    auth_args=$(_lso_auth_args)
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
    local auth_args
    auth_args=$(_lso_auth_args)
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
        "$(json_escape "$url")" "$first_ttfb" "$median_ttfb" "$(json_escape "$code")" "$(json_escape "$cache_header")" "$BENCH_RUNS" > "$out"
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

################################################################################
# Concurrent load benchmarking (SPEC §T4.3 saturation). Prefers a real load
# generator (wrk > k6 > ab) and falls back to backgrounded parallel curl so the
# subcommand always works, even on a box with no load tool installed. OFFLINE
# CAVEAT: meaningful saturation thresholds need a live server under real traffic;
# without one this measures mechanics (the harness, JSON shape, the fallback),
# not a production capacity number.
################################################################################

# Coerce a named variable to a valid number, defaulting to 0 — guarantees the
# JSON fields are never empty/garbage regardless of how a tool formatted output.
# $1 = var name, $2 = int|float. Uses eval (bash 3.2 has no namerefs).
_load_num() {
    local _n="$1" _kind="$2" _v
    eval "_v=\${$_n}"
    if [ "$_kind" = int ]; then
        case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
    else
        case "$_v" in ''|*[!0-9.]*|*.*.*) _v=0 ;; esac
    fi
    eval "$_n=\$_v"
}

# Which load tool to use. LSO_LOAD_TOOL overrides (set 'curl' to force the
# portable fallback, e.g. in tests). If HTTP Basic auth is configured, use the
# curl fallback regardless — only the curl/ab paths plumb _lso_auth_args, so
# wrk/k6 would otherwise hammer a gated site unauthenticated. Else prefer wrk,
# then k6, then ab, then the curl fallback.
_load_tool() {
    if [ -n "${LSO_LOAD_TOOL:-}" ]; then printf '%s' "$LSO_LOAD_TOOL"; return 0; fi
    local _auth
    _auth=$(_lso_auth_args 2>/dev/null || true)
    if [ -n "$_auth" ]; then printf 'curl'; return 0; fi
    if command -v wrk >/dev/null 2>&1; then printf 'wrk'
    elif command -v k6 >/dev/null 2>&1; then printf 'k6'
    elif command -v ab >/dev/null 2>&1; then printf 'ab'
    else printf 'curl'; fi
}

# Portable fallback: $conc background workers each loop GET $url until a wall-clock
# deadline, recording "<http_code> <ttfb_seconds>" per request to a per-worker
# file (per-worker files avoid interleaved-append corruption). Echoes
# "requests errors sum_ttfb_ms" on stdout.
_load_curl_fallback() {
    local url="$1" conc="$2" dur="$3" auth_args="$4"
    local workdir deadline w pids=""
    # mktemp -d under a tight umask (secure_mktemp only forwards a file template).
    workdir=$( (umask 077; mktemp -d "${LSO_DATA_DIR:-${TMPDIR:-/tmp}}/.lso-load.XXXXXX") 2>/dev/null) \
        || { workdir="${TMPDIR:-/tmp}/.lso-load.$$"; mkdir -p "$workdir" 2>/dev/null || true; }
    deadline=$(( $(date +%s) + dur ))

    w=1
    while [ "$w" -le "$conc" ]; do
        (
            while [ "$(date +%s)" -lt "$deadline" ]; do
                # shellcheck disable=SC2086
                curl -o /dev/null -s -m 20 $auth_args \
                    -w '%{http_code} %{time_starttransfer}\n' "$url" 2>/dev/null \
                    || printf '000 0\n'
            done >> "${workdir}/w${w}"
        ) &
        pids="${pids} $!"
        w=$((w + 1))
    done
    # shellcheck disable=SC2086
    wait $pids 2>/dev/null || true

    # Aggregate across all worker files in one awk pass. A 000 code is a
    # connection failure (no HTTP response) — counted as an error but NOT as a
    # completed request, so an unreachable host yields 0 completed (-> error
    # path) instead of a bogus "all requests succeeded". Echoes
    # "completed errors sum_ttfb_ms" (sum only over completed requests).
    cat "${workdir}"/w* 2>/dev/null | awk '
        {
            if ($1 == "000") { errors++; next }
            reqs++
            if ($1 < 200 || $1 >= 400) errors++
            sum += $2 * 1000
        }
        END { printf "%d %d %.0f", reqs, errors, sum }
    '
    rm -rf "$workdir" 2>/dev/null || true
}

run_load() {
    local url="$1"

    case "$url" in
        http://*|https://*) ;;
        *) log_error "load test requires a full URL (http:// or https://)"; exit 1 ;;
    esac

    local conc="$LOAD_CONCURRENCY" dur="$LOAD_DURATION" tool
    # Guard the knobs against non-numeric input (set -e safe arithmetic below).
    case "$conc" in ''|*[!0-9]*) conc=10 ;; esac
    case "$dur" in ''|*[!0-9]*) dur=10 ;; esac
    [ "$conc" -lt 1 ] && conc=1
    [ "$dur" -lt 1 ] && dur=1
    tool=$(_load_tool)

    log_info "Load test: ${url}  (tool=${tool}, concurrency=${conc}, duration=${dur}s)"
    log_warn "Offline caveat: real saturation thresholds need a live box under load — this measures the harness, not production capacity."

    local auth_args reqs="0" errors="0" sum_ms="0" rps="0" mean_ms="0"
    auth_args=$(_lso_auth_args)

    if [ "$tool" = "wrk" ]; then
        local wrk_out
        # shellcheck disable=SC2086
        wrk_out=$(wrk -t"$conc" -c"$conc" -d"${dur}s" "$url" 2>/dev/null || true)
        reqs=$(printf '%s' "$wrk_out" | awk '/requests in/ {print $1; exit}')
        rps=$(printf '%s' "$wrk_out" | sed -n 's/^Requests\/sec:[[:space:]]*\([0-9.]*\).*/\1/p')
        # wrk prints latency WITH a unit suffix (e.g. "65.83ms", "1.20s") — strip
        # the unit so the value is a bare number, else it would land non-numeric in
        # the JSON. Not normalised to ms, so the mean is approximate across units.
        mean_ms=$(printf '%s' "$wrk_out" | awk '/Latency/ {v=$2; sub(/[a-zA-Z]+$/,"",v); print v; exit}')
        _load_num reqs int; _load_num rps float; _load_num mean_ms float
    elif [ "$tool" = "k6" ]; then
        local k6_out
        # URL passed via -e (env), NOT interpolated into the JS, so a URL with a
        # quote can't break the k6 script (quoted heredoc => no shell expansion).
        k6_out=$(k6 run --quiet --vus "$conc" --duration "${dur}s" -e "TARGET=${url}" - <<'K6EOF' 2>/dev/null || true
import http from 'k6/http';
export default function () { http.get(__ENV.TARGET); }
K6EOF
)
        reqs=$(printf '%s' "$k6_out" | sed -n 's/.*http_reqs[^0-9]*\([0-9]*\).*/\1/p' | head -1)
        rps=$(printf '%s' "$k6_out" | sed -n 's#.*http_reqs[^0-9]*[0-9]*[^0-9]*\([0-9.]*\)/s.*#\1#p' | head -1)
        _load_num reqs int; _load_num rps float
    elif [ "$tool" = "ab" ]; then
        local ab_out total_reqs="$(( conc * dur * 20 ))"
        # shellcheck disable=SC2086
        ab_out=$(ab -c "$conc" -n "$total_reqs" -s 20 $auth_args "$url" 2>/dev/null || true)
        reqs=$(printf '%s' "$ab_out" | sed -n 's/^Complete requests:[[:space:]]*\([0-9]*\).*/\1/p')
        rps=$(printf '%s' "$ab_out" | sed -n 's/^Requests per second:[[:space:]]*\([0-9.]*\).*/\1/p')
        mean_ms=$(printf '%s' "$ab_out" | sed -n 's/^Time per request:[[:space:]]*\([0-9.]*\).*(mean).*/\1/p' | head -1)
        errors=$(printf '%s' "$ab_out" | sed -n 's/^Failed requests:[[:space:]]*\([0-9]*\).*/\1/p')
        _load_num reqs int; _load_num rps float; _load_num mean_ms float; _load_num errors int
    else
        tool="curl"
        local agg
        agg=$(_load_curl_fallback "$url" "$conc" "$dur" "$auth_args")
        reqs=$(printf '%s' "$agg" | awk '{print $1}')
        errors=$(printf '%s' "$agg" | awk '{print $2}')
        sum_ms=$(printf '%s' "$agg" | awk '{print $3}')
        [ -n "$reqs" ] || reqs=0
        [ -n "$errors" ] || errors=0
        [ -n "$sum_ms" ] || sum_ms=0
        if [ "$reqs" -gt 0 ]; then
            rps=$(awk -v r="$reqs" -v d="$dur" 'BEGIN { printf "%.1f", r / d }')
            mean_ms=$(awk -v s="$sum_ms" -v r="$reqs" 'BEGIN { printf "%.1f", s / r }')
        fi
    fi

    if [ "${reqs:-0}" = "0" ]; then
        log_error "Load test produced no completed requests — is ${url} reachable?"
        exit 1
    fi

    echo ""
    echo "=== Load test: ${url} ==="
    echo "  Tool / concurrency:   ${tool} / ${conc}"
    echo "  Duration:             ${dur}s"
    echo "  Requests completed:   ${reqs}"
    echo "  Requests/sec:         ${rps}"
    [ "$mean_ms" != "0" ] && echo "  Mean TTFB (ms):       ${mean_ms}"
    echo "  Errors (non-2xx/3xx): ${errors}"

    # Persist + before/after comparison (own file family, diffed by URL).
    local load_dir="${DATA_DIR}/benchmarks"
    mkdir -p "$load_dir"
    local prev out
    prev=$(ls -1t "$load_dir"/load-*.json 2>/dev/null | head -1 || true)
    out="${load_dir}/load-$(date +%Y%m%d-%H%M%S).json"
    printf '{"command":"load","url":"%s","tool":"%s","concurrency":%s,"duration_s":%s,"requests":%s,"rps":%s,"mean_ttfb_ms":%s,"errors":%s}\n' \
        "$(json_escape "$url")" "$(json_escape "$tool")" "$conc" "$dur" "$reqs" "${rps:-0}" "${mean_ms:-0}" "${errors:-0}" > "$out"
    log_info "Saved: $out"

    if [ -n "$prev" ] && grep -q "\"url\":\"$url\"" "$prev" 2>/dev/null; then
        local prev_rps
        prev_rps=$(sed -n 's/.*"rps":\([0-9.]*\).*/\1/p' "$prev")
        if [ -n "$prev_rps" ]; then
            echo ""
            log_info "Before/after (req/sec): ${prev_rps} -> ${rps}"
        fi
    fi
}
