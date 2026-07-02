#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/mariadb.sh - MariaDB/MySQL InnoDB tuning for WooCommerce/WordPress
################################################################################
# OPT-IN (--mariadb), default-off, NOT in any profile. Writes ONE owned config
# drop-in with conservative, RAM-tier-aware InnoDB tuning so the WooCommerce/
# WordPress database performs under load without over-committing RAM.
#
# It touches the DATABASE config only — never the LSWS httpd_config — so, like
# os-limits, it is safe on Enterprise (that guard is about httpd_config.xml, not
# the DB). On panel-managed hosts (DirectAdmin/RunCloud/Plesk/…) the panel may
# manage the DB config, so it is manual-only there (mirrors os-limits/modsec).
#
# One owned file (starts with the managed marker so detect/rollback can prove
# ownership; the path goes through _lso_fs so fixtures work):
#   Debian/Ubuntu (MariaDB): /etc/mysql/mariadb.conf.d/99-woocommerce.cnf
#   Debian/Ubuntu (MySQL):   /etc/mysql/mysql.conf.d/99-woocommerce.cnf
#   RHEL/CentOS:             /etc/my.cnf.d/99-woocommerce.cnf
# We detect which PARENT conf.d dir the daemon actually reads and write there; if
# NONE exists we note it and do nothing (never create a conf.d dir blindly on a
# host that uses a different layout).
#
# Values are FIXED constants (SPEC §T3.4) EXCEPT the InnoDB buffer pool + its log
# file size, which scale with the RAM tier:
#   tier 1g -> pool 256M  / log 64M
#   tier 2g -> pool 512M  / log 128M
#   tier 4g -> pool 1G    / log 256M   (log = 25% of pool)
#   tier 8g -> pool 2560M / log 640M
# innodb_flush_log_at_trx_commit is ALWAYS 1 (durability for WooCommerce orders —
# never 0/2).
#
# We NEVER auto-restart mariadb (the operator picks an off-peak window); we only
# log the reminder, live-only, guarded behind empty LSO_FS_ROOT + not DRY_RUN.
# The absence of mysql/mariadb must never fail the feature. Backup/rollback of the
# owned file rides the existing mariadb conf.d coverage in
# litespeed-optimizer-lib/backup.sh (marker-guarded cleanup for a freshly-added file).
################################################################################

# Owned conf.d parent dirs (through _lso_fs so LSO_FS_ROOT fixtures work).
_mdb_debian_dir() { _lso_fs /etc/mysql/mariadb.conf.d; }   # MariaDB on Debian/Ubuntu
_mdb_mysql_dir()  { _lso_fs /etc/mysql/mysql.conf.d; }     # Oracle MySQL on Debian/Ubuntu
_mdb_rhel_dir()   { _lso_fs /etc/my.cnf.d; }               # RHEL/CentOS

# Resolve the target 99-woocommerce.cnf path by picking the conf.d dir the daemon
# actually reads. Candidate dirs, in preference order: mariadb.conf.d, mysql.conf.d,
# my.cnf.d. Among the ones that EXIST we PREFER the first that already holds a *.cnf
# (that's the active include dir the daemon reads) so we never write into a stale/
# empty tree; failing that we fall back to the first existing candidate. Echoes the
# full owned-file path and returns 0 when a dir was chosen; echoes nothing and
# returns 1 when NONE of the candidate dirs exists.
_mdb_target_file() {
    local d f chosen="" first_existing="" found_active=""
    for d in "$(_mdb_debian_dir)" "$(_mdb_mysql_dir)" "$(_mdb_rhel_dir)"; do
        [ -d "$d" ] || continue
        [ -n "$first_existing" ] || first_existing="$d"
        if [ -z "$found_active" ]; then
            # [ -e ] guards the literal-glob case when the dir holds no *.cnf (no
            # reliable nullglob in bash 3.2).
            for f in "$d"/*.cnf; do
                [ -e "$f" ] && { found_active="$d"; break; }
            done
        fi
    done
    [ -n "$first_existing" ] || return 1
    if [ -n "$found_active" ]; then
        chosen="$found_active"
    else
        chosen="$first_existing"
    fi
    echo "${chosen}/99-woocommerce.cnf"
    return 0
}

# InnoDB buffer pool size per RAM tier (conservative single value per tier). Pure
# lookup: runs inside $(...) so it MUST NOT log — tier validation/warning happens
# once in feature_apply_custom_mariadb. The silent *) mirrors the 8g default.
_mdb_buffer_pool() {
    case "$1" in
        1g) echo 256M ;;
        2g) echo 512M ;;
        4g) echo 1G ;;
        8g) echo 2560M ;;
        *)  echo 2560M ;;
    esac
}

# InnoDB log file size = 25% of the chosen buffer pool (per-tier lookup, kept
# simple rather than arithmetic on the M/G-suffixed string). Pure lookup (see
# _mdb_buffer_pool): no logging, silent *) = 8g default.
_mdb_log_file() {
    case "$1" in
        1g) echo 64M ;;
        2g) echo 128M ;;
        4g) echo 256M ;;
        8g) echo 640M ;;
        *)  echo 640M ;;
    esac
}

# True when <file> already EXISTS but was NOT written by us (lacks the managed
# marker) — an operator-owned file we must refuse to clobber. Our own prior file
# DOES carry the marker, so idempotent re-apply is allowed. Returns 1 when the
# file is absent or marked.
_mdb_unmanaged_exists() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -q "Managed by litespeed-optimizer" "$file" 2>/dev/null && return 1
    return 0
}

# Write the owned file atomically (DRY_RUN-aware). Mirrors os-limits' _ol_write_file:
# secure_mktemp + copy_file_permissions + atomic mv + "[DRY RUN] Would write ..." log.
_mdb_write_file() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write ${file#${LSO_FS_ROOT:-}}"
        cat >/dev/null
        return 0
    fi
    mkdir -p "$dir" || { log_warn "mariadb: cannot create ${dir}"; return 1; }
    local tmp
    tmp=$(secure_mktemp "${dir}/.lso-mariadb.XXXXXX") || return 1
    # errexit is OFF inside `if feature_apply ...`, so a silent cat/mv failure would
    # otherwise skip rollback — propagate it explicitly.
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    log_info "Wrote ${file#${LSO_FS_ROOT:-}}"
}

feature_apply_custom_mariadb() {
    # Opt-in gate: never touch DB config unless explicitly asked.
    if [ "${LSO_MARIADB:-}" != "1" ]; then
        log_info "mariadb: not enabled — pass --mariadb to write RAM-tier InnoDB tuning for WooCommerce/WordPress (99-woocommerce.cnf drop-in); OPT-IN, default-off"
        return 0
    fi

    # Panel-managed hosts: the panel may manage the DB config, so writing here could
    # be clobbered or be out of scope. Manual-only, mirroring os-limits/modsec.
    # (Enterprise is NOT restricted here — this is DB config, not httpd_config.xml.)
    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        log_warn "mariadb: ${LSO_PANEL} manages the database config — MariaDB tuning is manual-only here."
        log_info "  Set it by hand: a [mysqld] drop-in with innodb_buffer_pool_size (per RAM), innodb_log_file_size (25% of pool),"
        log_info "  innodb_flush_method=O_DIRECT, innodb_flush_log_at_trx_commit=1, slow_query_log=1, long_query_time=0.5."
        return 0
    fi

    # Resolve the conf.d dir to write into. If NEITHER Debian nor RHEL conf.d dir
    # exists, there is no MariaDB config layout to extend — note it and do nothing
    # (never create a Debian dir blindly on a RHEL box, or vice versa).
    local target
    if ! target="$(_mdb_target_file)"; then
        log_info "mariadb: no MariaDB conf.d directory found (checked /etc/mysql/mariadb.conf.d, /etc/mysql/mysql.conf.d and /etc/my.cnf.d) — nothing to do. Install MariaDB/MySQL first, then re-run --mariadb."
        return 0
    fi

    # Ownership guard (H1): refuse to overwrite an operator's own config at the target
    # path. Our own prior file carries the managed marker, so idempotent re-apply is
    # fine. READ-ONLY check — kept active even under DRY_RUN so a dry run surfaces the
    # conflict — and fixture-safe (target is an _lso_fs-prefixed path).
    if _mdb_unmanaged_exists "$target"; then
        log_error "mariadb: refusing to overwrite ${target#${LSO_FS_ROOT:-}} — it exists WITHOUT our '# Managed by litespeed-optimizer' marker (operator-owned). Move/remove that file or add the marker, then re-run --mariadb."
        return 1
    fi

    local tier pool logf
    tier=$(sysinfo_ram_tier)
    # Validate the tier at statement level (NOT inside the captured $() below — a
    # log_warn there would pollute the pool/log values). Warn once, fall back to 8g.
    case "$tier" in
        1g|2g|4g|8g) ;;
        *) log_warn "mariadb: unknown RAM tier '${tier}', using 8g defaults"; tier=8g ;;
    esac
    pool=$(_mdb_buffer_pool "$tier")
    logf=$(_mdb_log_file "$tier")

    _mdb_write_file "$target" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Conservative InnoDB tuning for WooCommerce/WordPress. Buffer pool + log file
# size scale with RAM (tier ${tier}); the rest are fixed. Apply at an off-peak
# window with: systemctl restart mariadb
[mysqld]
innodb_buffer_pool_size=${pool}
# If MariaDB fails to start after innodb_log_file_size changes, stop it, remove
# the old ib_logfile* redo logs, then start once (older MariaDB requires this).
innodb_log_file_size=${logf}
innodb_flush_method=O_DIRECT
innodb_flush_log_at_trx_commit=1
slow_query_log=1
long_query_time=0.5
EOF

    log_success "mariadb: wrote ${target#${LSO_FS_ROOT:-}} (InnoDB pool ${pool}, log ${logf}, O_DIRECT, trx_commit=1, slow_query_log) for tier ${tier}"

    # Live-only restart reminder. We NEVER auto-restart mariadb (the operator picks
    # the window); its absence must never fail the feature.
    if [ -z "${LSO_FS_ROOT:-}" ] && [ "${DRY_RUN:-false}" != true ]; then
        log_info "mariadb: restart at an off-peak window to apply: systemctl restart mariadb"
    fi
}

# Detected iff the owned file exists AND carries our managed marker AND has the
# anchored content sentinels (buffer pool + durability commit) — so a third-party
# file at the same path is never mis-credited to this feature.
feature_detect_custom_mariadb() {
    local target
    target="$(_mdb_target_file)" || return 1
    [ -f "$target" ] || return 1
    grep -q "Managed by litespeed-optimizer" "$target" 2>/dev/null || return 1
    grep -qE '^innodb_buffer_pool_size=' "$target" 2>/dev/null || return 1
    grep -qE '^innodb_flush_log_at_trx_commit=1' "$target" 2>/dev/null || return 1
    return 0
}

FEATURE_ID="mariadb"
FEATURE_DISPLAY="MariaDB InnoDB tuning (WooCommerce/WordPress)"
FEATURE_DETECT_PATTERN="innodb_buffer_pool_size"
FEATURE_SCOPE="global"
FEATURE_ALIASES="mysql,db"
feature_register
