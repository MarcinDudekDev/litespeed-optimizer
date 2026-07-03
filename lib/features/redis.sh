#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/redis.sh - Redis object-cache tuning (maxmemory + allkeys-lru)
################################################################################
# OPT-IN (--redis), default-off, NOT in any profile. Writes ONE owned drop-in with
# conservative, RAM-tier-aware object-cache tuning so a Redis instance used as the
# WordPress object cache stays inside a sane memory budget and evicts LRU keys
# instead of OOM-ing or being killed.
#
# Redis has no native conf.d directory, so we write ONE owned drop-in and add ONE
# `include` line at the END of redis.conf (Redis applies last-occurrence-wins, so
# appending at the end makes OUR values authoritative). We set ONLY maxmemory +
# maxmemory-policy allkeys-lru — we DO NOT touch persistence (save/appendonly),
# because the instance may be shared with other apps and flipping durability could
# surprise the operator.
#
# It touches the CACHE config only — never the LSWS httpd_config — so, like
# os-limits/mariadb, it is safe on Enterprise (that guard is about httpd_config.xml,
# not the cache daemon). On panel-managed hosts (DirectAdmin/RunCloud/Plesk/…) the
# panel may manage the Redis config, so it is manual-only there (mirrors os-limits).
#
# One owned file (starts with the managed marker so detect/rollback can prove
# ownership; the path goes through _lso_fs so fixtures work):
#   /etc/redis/litespeed-optimizer.conf
# The include DIRECTIVE VALUE written into redis.conf is the REAL runtime path
# (/etc/redis/litespeed-optimizer.conf, NOT the fixture-prefixed one) because Redis
# reads it live; the file we READ/APPEND is the _lso_fs-prefixed redis.conf.
#
# maxmemory scales with the RAM tier via lso_redis_mb (64/128/384/768 MB); the
# policy is a FIXED allkeys-lru. We NEVER auto-restart redis (the operator picks an
# off-peak window); we only log the reminder, live-only, guarded behind empty
# LSO_FS_ROOT + not DRY_RUN. The absence of redis-cli/redis-server must never fail
# the feature. Backup/rollback of the owned file + the appended include rides the
# existing /etc/redis coverage in litespeed-optimizer-lib/backup.sh (marker-guarded
# cleanup for a freshly-added file).
################################################################################

# Owned drop-in + the redis.conf we append the include to (through _lso_fs so
# LSO_FS_ROOT fixtures work).
_redis_dropin_file() { _lso_fs /etc/redis/litespeed-optimizer.conf; }   # the owned drop-in
_redis_main_conf()   { _lso_fs /etc/redis/redis.conf; }                 # redis.conf we append the include to

# True when <file> already EXISTS but was NOT written by us (lacks the managed
# marker) — an operator-owned file we must refuse to clobber. Our own prior file
# DOES carry the marker, so idempotent re-apply is allowed. Returns 1 when the
# file is absent or marked.
_redis_unmanaged_exists() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -q "Managed by litespeed-optimizer" "$file" 2>/dev/null && return 1
    return 0
}

# Write the owned file atomically (DRY_RUN-aware). Mirrors mariadb's _mdb_write_file:
# secure_mktemp + copy_file_permissions + atomic mv + "[DRY RUN] Would write ..." log.
_redis_write_file() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write ${file#${LSO_FS_ROOT:-}}"
        cat >/dev/null
        return 0
    fi
    mkdir -p "$dir" || { log_warn "redis: cannot create ${dir}"; return 1; }
    local tmp
    tmp=$(secure_mktemp "${dir}/.lso-redis.XXXXXX") || return 1
    # errexit is OFF inside `if feature_apply ...`, so a silent cat/mv failure would
    # otherwise skip rollback — propagate it explicitly (mirrors mariadb's _mdb_write_file).
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    # Redis may run as user `redis` and reads include'd files as itself — the drop-in holds no secrets, so make it world-readable or the include bricks startup.
    chmod 0644 "$file" 2>/dev/null || true
    log_info "Wrote ${file#${LSO_FS_ROOT:-}}"
}

feature_apply_custom_redis() {
    # Opt-in gate: never touch Redis config unless explicitly asked.
    if [ "${LSO_REDIS:-}" != "1" ]; then
        log_info "redis: not enabled — pass --redis to write conservative Redis object-cache tuning (maxmemory + allkeys-lru drop-in); OPT-IN, default-off"
        return 0
    fi

    # Presence gate: without a redis.conf there is no Redis to tune — note it and do
    # nothing (never create /etc/redis blindly on a box without Redis).
    if [ "${LSO_HAS_REDIS:-false}" = true ]; then
        :
    else
        log_info "redis: not present (no /etc/redis/redis.conf) — install redis-server, then re-run --redis"
        return 0
    fi

    # Config gate (H1): Redis may be in PATH while /etc/redis/redis.conf is absent (custom
    # layout / not yet initialized). Without a redis.conf to include the drop-in from, writing
    # an orphan drop-in wires nothing — refuse and note it, writing NOTHING. Resolved once here
    # and reused for the include-append below (do not resolve twice).
    local main_conf
    main_conf="$(_redis_main_conf)"
    if [ ! -f "$main_conf" ]; then
        log_info "redis: Redis is present but no redis.conf at ${main_conf#${LSO_FS_ROOT:-}} — cannot wire the tuning drop-in (add 'maxmemory <N>mb' + 'maxmemory-policy allkeys-lru' by hand, or install to the standard path); skipping"
        return 0
    fi

    # Panel-managed hosts: the panel may manage the Redis config, so writing here
    # could be clobbered or be out of scope. Manual-only, mirroring os-limits/mariadb.
    # (Enterprise is NOT restricted here — this is cache config, not httpd_config.xml.)
    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        log_warn "redis: ${LSO_PANEL} manages the Redis config — Redis tuning is manual-only here."
        log_info "  Set it by hand: maxmemory (per RAM) + maxmemory-policy allkeys-lru in redis.conf (leave save/appendonly alone)."
        return 0
    fi

    # Ownership guard (H1): refuse to overwrite an operator's own drop-in at the target
    # path. Our own prior file carries the managed marker, so idempotent re-apply is
    # fine. READ-ONLY check — kept active even under DRY_RUN so a dry run surfaces the
    # conflict — and fixture-safe (the path is _lso_fs-prefixed).
    local dropin
    dropin="$(_redis_dropin_file)"
    if _redis_unmanaged_exists "$dropin"; then
        log_error "redis: refusing to overwrite ${dropin#${LSO_FS_ROOT:-}} — it exists WITHOUT our '# Managed by litespeed-optimizer' marker (operator-owned). Move/remove that file or add the marker, then re-run --redis."
        return 1
    fi

    # maxmemory in MB per RAM tier (lso_redis_mb already buckets to 64/128/384/768 and
    # honors LSO_RAM_MB). Pure capture — lso_redis_mb never logs.
    local mm
    mm=$(lso_redis_mb)

    _redis_write_file "$dropin" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Conservative Redis object-cache tuning (RAM-scaled maxmemory). Apply at an
# off-peak window with: systemctl restart redis
maxmemory ${mm}mb
maxmemory-policy allkeys-lru
EOF

    # Ensure our drop-in is included from redis.conf. Redis applies last-occurrence-wins,
    # so appending the include at the END makes our values authoritative. The include
    # VALUE is the REAL runtime path (Redis reads it live), NOT the _lso_fs-prefixed one;
    # the file we read/append is the fixture-prefixed redis.conf (resolved above). Idempotent:
    # append only when the exact include line is absent. Under DRY_RUN we log the intent and
    # do not write. inc_status feeds the final log so it never lies about what happened.
    local inc_line inc_status=""
    inc_line="include /etc/redis/litespeed-optimizer.conf"
    if grep -Fxq "$inc_line" "$main_conf" 2>/dev/null; then
        inc_status="already present"
    elif [ "${DRY_RUN:-false}" = true ]; then
        log_info "redis: [DRY RUN] Would add include of the litespeed-optimizer drop-in to redis.conf"
    else
        printf '\n# Managed by litespeed-optimizer\n%s\n' "$inc_line" >> "$main_conf" \
            || { log_warn "redis: could not append include to redis.conf"; return 1; }
        log_info "Added include of the litespeed-optimizer drop-in to redis.conf"
        inc_status="added"
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "redis: [DRY RUN] would write ${dropin#${LSO_FS_ROOT:-}} (maxmemory ${mm}mb, allkeys-lru) and add the include to redis.conf"
    else
        log_success "redis: wrote ${dropin#${LSO_FS_ROOT:-}} (maxmemory ${mm}mb, maxmemory-policy allkeys-lru); include ${inc_status} in redis.conf"
        # allkeys-lru is instance-global — a Redis shared beyond object caching can lose data.
        log_warn "redis: maxmemory-policy allkeys-lru evicts ANY key under memory pressure — safe only if this Redis is a DEDICATED object cache; a Redis shared with sessions/queues/other apps can silently lose that data."
    fi

    # Live-only restart reminder. We NEVER auto-restart redis (the operator picks the
    # window); its absence must never fail the feature.
    if [ -z "${LSO_FS_ROOT:-}" ] && [ "${DRY_RUN:-false}" != true ]; then
        log_info "redis: restart at an off-peak window to apply: systemctl restart redis"
    fi
}

# Detected iff the owned file exists AND carries our managed marker AND has the
# anchored content sentinels (eviction policy + maxmemory) — so a third-party file at
# the same path is never mis-credited to this feature.
feature_detect_custom_redis() {
    local f
    f="$(_redis_dropin_file)"
    [ -f "$f" ] || return 1
    grep -q "Managed by litespeed-optimizer" "$f" 2>/dev/null || return 1
    grep -qE '^maxmemory-policy allkeys-lru' "$f" 2>/dev/null || return 1
    grep -qE '^maxmemory ' "$f" 2>/dev/null || return 1
    # Honest detect: the drop-in only takes effect if redis.conf still includes it. If an
    # operator removed the include line, the tuning is inert — report NOT detected. The
    # include VALUE is the REAL runtime path (matches what apply writes).
    local main_conf
    main_conf="$(_redis_main_conf)"
    [ -f "$main_conf" ] || return 1
    grep -Fxq "include /etc/redis/litespeed-optimizer.conf" "$main_conf" 2>/dev/null || return 1
    return 0
}

FEATURE_ID="redis"
FEATURE_DISPLAY="Redis object-cache tuning (maxmemory + allkeys-lru)"
FEATURE_DETECT_PATTERN="maxmemory-policy"
FEATURE_SCOPE="global"
FEATURE_ALIASES="redis-tuning"
feature_register
