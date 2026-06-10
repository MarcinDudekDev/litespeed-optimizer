#!/bin/bash
################################################################################
# core/sysinfo.sh - System Information + RAM-Aware LiteSpeed Sizing
################################################################################
# Cross-platform (macOS + Linux) detection of RAM and CPU, plus the RAM-tier
# lookup tables and the lso_children formula from SYNTHESIS §2/§8.
#
# RAM Tiers (LiteSpeed sizing):
#   1g: <1536MB    2g: <3072MB    4g: <6144MB    8g: >=6144MB
#
# Test overrides: LSO_RAM_MB, LSO_CORES env vars force values (golden tests).
################################################################################

# Cache detected values to avoid repeated syscalls
_SYSINFO_RAM_MB=""
_SYSINFO_CPU_CORES=""

################################################################################
# Detection Functions
################################################################################

# Get total system RAM in megabytes (honors LSO_RAM_MB override)
sysinfo_ram_mb() {
    if [ -n "${LSO_RAM_MB:-}" ]; then
        echo "$LSO_RAM_MB"
        return 0
    fi

    if [ -n "$_SYSINFO_RAM_MB" ]; then
        echo "$_SYSINFO_RAM_MB"
        return 0
    fi

    local ram_mb=0

    case "$(uname -s)" in
        Darwin)
            local ram_bytes
            ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
            ram_mb=$((ram_bytes / 1024 / 1024))
            ;;
        Linux)
            local ram_kb
            ram_kb=$(grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
            ram_mb=$(( ${ram_kb:-0} / 1024 ))
            ;;
        *)
            ram_mb=2048
            ;;
    esac

    if [ "$ram_mb" -lt 128 ]; then
        ram_mb=2048  # Fallback if detection failed
    fi

    _SYSINFO_RAM_MB="$ram_mb"
    echo "$ram_mb"
}

# Get CPU core count (honors LSO_CORES override)
sysinfo_cpu_cores() {
    if [ -n "${LSO_CORES:-}" ]; then
        echo "$LSO_CORES"
        return 0
    fi

    if [ -n "$_SYSINFO_CPU_CORES" ]; then
        echo "$_SYSINFO_CPU_CORES"
        return 0
    fi

    local cores=1

    case "$(uname -s)" in
        Darwin)
            cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
            ;;
        Linux)
            cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
            ;;
    esac

    if [ "$cores" -lt 1 ]; then
        cores=1
    fi

    _SYSINFO_CPU_CORES="$cores"
    echo "$cores"
}

# Get RAM tier name: 1g | 2g | 4g | 8g
sysinfo_ram_tier() {
    local ram_mb
    ram_mb=$(sysinfo_ram_mb)

    if [ "$ram_mb" -lt 1536 ]; then
        echo "1g"
    elif [ "$ram_mb" -lt 3072 ]; then
        echo "2g"
    elif [ "$ram_mb" -lt 6144 ]; then
        echo "4g"
    else
        echo "8g"
    fi
}

# Measure average lsphp process RSS in MB (Linux only; empty if none running)
sysinfo_lsphp_rss() {
    case "$(uname -s)" in
        Linux)
            # ps -ylC lsphp: RSS is column 8 (kB)
            local avg_kb
            avg_kb=$(ps -ylC lsphp 2>/dev/null | awk 'NR>1 {sum+=$8; n++} END {if (n>0) print int(sum/n)}')
            if [ -n "$avg_kb" ] && [ "$avg_kb" -gt 0 ]; then
                echo $((avg_kb / 1024))
                return 0
            fi
            ;;
    esac
    echo ""
}

################################################################################
# Tier-Lookup Tables (SYNTHESIS §2)
################################################################################

# InnoDB buffer pool size in MB per tier
lso_innodb_pool() {
    local ram=${1:-$(sysinfo_ram_mb)}
    if [ "$ram" -lt 1536 ]; then echo 256
    elif [ "$ram" -lt 3072 ]; then echo 512
    elif [ "$ram" -lt 6144 ]; then echo 1280
    else echo 2816
    fi
}

# Redis maxmemory in MB per tier
lso_redis_mb() {
    local ram=${1:-$(sysinfo_ram_mb)}
    if [ "$ram" -lt 1536 ]; then echo 64
    elif [ "$ram" -lt 3072 ]; then echo 128
    elif [ "$ram" -lt 6144 ]; then echo 384
    else echo 768
    fi
}

# OPcache memory_consumption in MB per tier
lso_opcache_mb() {
    local ram=${1:-$(sysinfo_ram_mb)}
    if [ "$ram" -lt 1536 ]; then echo 64
    elif [ "$ram" -lt 3072 ]; then echo 128
    elif [ "$ram" -lt 6144 ]; then echo 256
    else echo 256
    fi
}

# LSAPI_AVOID_FORK value per tier (0 / 200M / 500M / 1)
lso_avoid_fork() {
    local ram=${1:-$(sysinfo_ram_mb)}
    if [ "$ram" -lt 1536 ]; then echo "0"
    elif [ "$ram" -lt 3072 ]; then echo "200M"
    elif [ "$ram" -lt 6144 ]; then echo "500M"
    else echo "1"
    fi
}

# tuning{} maxConnections per tier
lso_max_connections() {
    local ram=${1:-$(sysinfo_ram_mb)}
    if [ "$ram" -lt 1536 ]; then echo 2000
    elif [ "$ram" -lt 3072 ]; then echo 5000
    else echo 10000
    fi
}

################################################################################
# PHP Children Formula (SPEC §8) — the one computed value
################################################################################

# lso_children <ram_mb> <cores> [rss_mb]
# Computes PHP_LSAPI_CHILDREN from available RAM after reserving for the OS,
# InnoDB pool, Redis, OPcache and LSWS itself; capped at cores*8, floor 8.
lso_children() {
    local ram=$1 cores=$2 rss=${3:-80}            # rss measured or 80MB woo / 50MB wp default
    local reserve=$(( ram*12/100 )); [ "$reserve" -lt 512 ] && reserve=512
    local pool redis opcache
    pool=$(lso_innodb_pool "$ram")
    redis=$(lso_redis_mb "$ram")
    opcache=$(lso_opcache_mb "$ram")
    local avail=$(( ram - reserve - pool - redis - opcache - 150 ))   # 150MB lsws+misc
    local n=$(( avail / rss ))
    local cpu_cap=$(( cores * 8 ))
    [ "$n" -gt "$cpu_cap" ] && n=$cpu_cap
    [ "$n" -lt 8 ] && n=8
    echo $n
}

# Sanity assertion string for analyze/optimize output
# lso_ram_budget_check <ram_mb> <cores> [rss_mb] → "OK" or "OVERCOMMIT"
# Invariant matches the lso_children formula: everything planned (OS reserve,
# InnoDB, Redis, OPcache, 150MB lsws+misc, PHP children) must fit inside RAM.
# (The formula already reserves max(12%, 512MB) for the OS as headroom.)
lso_ram_budget_check() {
    local ram=$1 cores=$2 rss=${3:-80}
    local reserve=$(( ram*12/100 )); [ "$reserve" -lt 512 ] && reserve=512
    local pool redis opcache children
    pool=$(lso_innodb_pool "$ram")
    redis=$(lso_redis_mb "$ram")
    opcache=$(lso_opcache_mb "$ram")
    children=$(lso_children "$ram" "$cores" "$rss")
    local total=$(( reserve + pool + redis + opcache + 150 + children * rss ))
    if [ "$total" -le "$ram" ]; then
        echo "OK (${total}MB planned <= ${ram}MB RAM, incl. ${reserve}MB OS reserve)"
    else
        echo "OVERCOMMIT (${total}MB planned > ${ram}MB RAM)"
    fi
}

################################################################################
# Summary
################################################################################

# Human-readable summary of detected system + sizing (used by detect/check)
sysinfo_summary() {
    local ram_mb cores tier rss
    ram_mb=$(sysinfo_ram_mb)
    cores=$(sysinfo_cpu_cores)
    tier=$(sysinfo_ram_tier)
    rss=$(sysinfo_lsphp_rss)
    local rss_label="${rss:-80 (default)}"
    [ -n "$rss" ] && rss_label="${rss} (measured)"

    echo "System: ${ram_mb}MB RAM, ${cores} CPU cores -> Tier ${tier}"
    echo "  PHP children (LSAPI):  $(lso_children "$ram_mb" "$cores" "${rss:-80}")"
    echo "  lsphp avg RSS MB:      ${rss_label}"
    echo "  InnoDB buffer pool:    $(lso_innodb_pool "$ram_mb")MB"
    echo "  Redis maxmemory:       $(lso_redis_mb "$ram_mb")MB"
    echo "  OPcache memory:        $(lso_opcache_mb "$ram_mb")MB"
    echo "  LSAPI_AVOID_FORK:      $(lso_avoid_fork "$ram_mb")"
    echo "  maxConnections:        $(lso_max_connections "$ram_mb")"
    echo "  RAM budget:            $(lso_ram_budget_check "$ram_mb" "$cores" "${rss:-80}")"
}
