#!/bin/bash
################################################################################
# backup.sh - Timestamped Backup & Restore (LiteSpeed targets)
################################################################################
# Backup layout (SPEC §7):
#   ~/.litespeed-optimizer/backups/<YYYYmmdd-HHMMSS>/
#   ├── manifest.txt        what was backed up, edition, panel, tool version
#   ├── lsws-conf/          rsync -a $LSO_LSWS_ROOT/conf/  (main+vhosts, OLS & LSWS)
#   ├── apache-includes/    cPanel: /etc/apache2/conf.d/includes/
#   ├── htaccess/<site>/    .htaccess of each detected WP site
#   ├── php/  redis/  mariadb/  sysctl/  systemd/   (when present)
#   └── lscwp/<site>.json   wp litespeed-option export (Phase 3)
#
# All source paths honor LSO_FS_ROOT so the whole module is testable against
# fixture trees.
################################################################################

# Current backup directory (set during backup creation)
CURRENT_BACKUP_DIR=""

_bk_fs() {
    echo "${LSO_FS_ROOT:-}$1"
}

################################################################################
# Backup Creation
################################################################################

# create_backup [target_site]
# Returns: 0 on success, 1 if a critical backup target failed
create_backup() {
    local target_site="${1:-}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    CURRENT_BACKUP_DIR="${BACKUP_DIR}/${timestamp}"
    mkdir -p "$CURRENT_BACKUP_DIR"

    log_info "Creating backup: $CURRENT_BACKUP_DIR"

    local backup_failed=false

    # Ensure environment is detected (gives us LSO_LSWS_ROOT etc.)
    if [ -z "${LSO_LSWS_ROOT:-}" ] && type -t detect_environment &>/dev/null; then
        detect_environment || true
    fi

    # 1. LiteSpeed conf tree (CRITICAL — covers main config + vhosts, OLS & LSWS)
    if [ -n "${LSO_LSWS_ROOT:-}" ] && [ -d "${LSO_LSWS_ROOT}/conf" ]; then
        mkdir -p "${CURRENT_BACKUP_DIR}/lsws-conf"
        if rsync -a "${LSO_LSWS_ROOT}/conf/" "${CURRENT_BACKUP_DIR}/lsws-conf/" 2>/dev/null; then
            log_info "Backed up: ${LSO_LSWS_ROOT}/conf"
        else
            log_error "CRITICAL: Failed to backup ${LSO_LSWS_ROOT}/conf (permission denied?)"
            backup_failed=true
        fi
    else
        log_error "CRITICAL: No LiteSpeed conf directory found to backup"
        backup_failed=true
    fi

    # 2. Apache includes (cPanel Enterprise path)
    local apache_inc_dir
    apache_inc_dir="$(_bk_fs /etc/apache2/conf.d/includes)"
    if [ -d "$apache_inc_dir" ]; then
        mkdir -p "${CURRENT_BACKUP_DIR}/apache-includes"
        if rsync -a "$apache_inc_dir/" "${CURRENT_BACKUP_DIR}/apache-includes/" 2>/dev/null; then
            log_info "Backed up: $apache_inc_dir"
        else
            log_warn "Could not backup $apache_inc_dir"
        fi
    fi

    # 3. .htaccess of each detected WP site (non-critical)
    if [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ]; then
        local docroot
        for docroot in "${LSO_WP_SITES[@]}"; do
            [ -f "$docroot/.htaccess" ] || continue
            local site_slug
            site_slug=$(basename "$(dirname "$docroot")")-$(basename "$docroot")
            mkdir -p "${CURRENT_BACKUP_DIR}/htaccess/${site_slug}"
            if cp -a "$docroot/.htaccess" "${CURRENT_BACKUP_DIR}/htaccess/${site_slug}/.htaccess" 2>/dev/null; then
                echo "$docroot" > "${CURRENT_BACKUP_DIR}/htaccess/${site_slug}/.docroot"
                log_info "Backed up: $docroot/.htaccess"
            else
                log_warn "Could not backup $docroot/.htaccess"
            fi
        done
    fi

    # 4. PHP ini (when resolved; non-critical)
    if [ -n "${LSO_PHP_INI:-}" ] && [ -f "$LSO_PHP_INI" ]; then
        mkdir -p "${CURRENT_BACKUP_DIR}/php"
        cp -a "$LSO_PHP_INI" "${CURRENT_BACKUP_DIR}/php/" 2>/dev/null || log_warn "Could not backup $LSO_PHP_INI"
    fi

    # 5. Redis / MariaDB / sysctl / systemd drop-ins (when present; non-critical)
    local src dst
    for src in /etc/redis /etc/mysql/mariadb.conf.d /etc/my.cnf.d /etc/sysctl.d /etc/systemd/system/lsws.service.d; do
        local real_src
        real_src="$(_bk_fs "$src")"
        [ -d "$real_src" ] || continue
        case "$src" in
            /etc/redis)            dst="redis" ;;
            /etc/mysql/*|/etc/my.cnf.d) dst="mariadb" ;;
            /etc/sysctl.d)         dst="sysctl" ;;
            *)                     dst="systemd" ;;
        esac
        mkdir -p "${CURRENT_BACKUP_DIR}/${dst}"
        rsync -a "$real_src/" "${CURRENT_BACKUP_DIR}/${dst}/" 2>/dev/null || log_warn "Could not backup $real_src"
    done

    if [ "$backup_failed" = true ]; then
        log_error "Backup failed - aborting"
        rm -rf "$CURRENT_BACKUP_DIR"
        CURRENT_BACKUP_DIR=""
        return 1
    fi

    create_backup_manifest "$target_site"

    log_success "Backup created: ${CURRENT_BACKUP_DIR}"
    log_info "Rollback command: litespeed-optimizer rollback $(basename "$CURRENT_BACKUP_DIR")"
    return 0
}

create_backup_manifest() {
    local target_site="${1:-all}"
    local manifest="${CURRENT_BACKUP_DIR}/manifest.txt"

    {
        echo "tool_version: ${VERSION:-unknown}"
        echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "hostname: $(hostname)"
        echo "user: $(whoami)"
        echo "edition: ${LSO_EDITION:-unknown}"
        echo "panel: ${LSO_PANEL:-unknown}"
        echo "lsws_root: ${LSO_LSWS_ROOT:-unknown}"
        echo "target_site: ${target_site:-all}"
        echo "applied_features: ${SPECIFIC_FEATURE:-all}"
        echo "backed_up:"
        local d
        for d in "$CURRENT_BACKUP_DIR"/*/; do
            if [ -d "$d" ]; then
                echo "  - $(basename "$d")"
            fi
        done
    } > "$manifest"

    log_info "Manifest saved: $manifest"
}

################################################################################
# Restore
################################################################################

# restore_backup <timestamp>
# Restores all backed-up targets, then runs verified restart + health check.
restore_backup() {
    local backup_timestamp="$1"

    if [ -z "$backup_timestamp" ]; then
        log_error "No backup timestamp provided"
        exit 1
    fi

    local backup_path="${BACKUP_DIR}/${backup_timestamp}"

    if [ ! -d "$backup_path" ]; then
        log_error "Backup not found: $backup_path"
        log_info "Available backups:"
        ls -1 "$BACKUP_DIR" 2>/dev/null | tail -10 || true
        exit 1
    fi

    log_warn "About to restore backup from: $backup_timestamp"

    if [ "${FORCE:-false}" != true ]; then
        read -rp "Are you sure you want to restore this backup? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Restore cancelled"
            exit 0
        fi
    fi

    # Ensure environment is detected for target paths
    if [ -z "${LSO_LSWS_ROOT:-}" ] && type -t detect_environment &>/dev/null; then
        detect_environment || true
    fi

    log_info "Restoring backup..."
    restore_backup_files "$backup_path"
    verify_restored_files "$backup_path"

    # Restart + health check (restore is only done when the server runs again)
    if type -t verified_restart &>/dev/null; then
        if verified_restart; then
            log_success "Backup restored and server verified healthy"
        else
            log_error "Server failed health check after restore — inspect manually!"
            log_error "Log: ${LOG_FILE}"
            exit 1
        fi
    else
        log_success "Backup restored (no restart performed — validator not loaded)"
    fi
}

# restore_backup_files <backup_path>
# Pure file restore (no restart). Separated so the validator's auto-rollback
# can reuse it.
restore_backup_files() {
    local backup_path="$1"

    # 1. LiteSpeed conf tree
    if [ -d "$backup_path/lsws-conf" ] && [ -n "${LSO_LSWS_ROOT:-}" ]; then
        log_info "Restoring ${LSO_LSWS_ROOT}/conf ..."
        rsync -a --delete "$backup_path/lsws-conf/" "${LSO_LSWS_ROOT}/conf/"
    fi

    # 2. Apache includes
    local apache_inc_dir
    apache_inc_dir="$(_bk_fs /etc/apache2/conf.d/includes)"
    if [ -d "$backup_path/apache-includes" ] && [ -d "$apache_inc_dir" ]; then
        log_info "Restoring $apache_inc_dir ..."
        rsync -a --delete "$backup_path/apache-includes/" "$apache_inc_dir/"
    fi

    # 3. .htaccess files (restored to recorded docroots)
    if [ -d "$backup_path/htaccess" ]; then
        local site_dir
        for site_dir in "$backup_path/htaccess"/*/; do
            [ -d "$site_dir" ] || continue
            [ -f "$site_dir/.docroot" ] || continue
            local docroot
            docroot=$(cat "$site_dir/.docroot")
            if [ -d "$docroot" ] && [ -f "$site_dir/.htaccess" ]; then
                log_info "Restoring $docroot/.htaccess ..."
                cp -a "$site_dir/.htaccess" "$docroot/.htaccess"
            fi
        done
    fi

    # 4. PHP ini
    if [ -d "$backup_path/php" ] && [ -n "${LSO_PHP_INI:-}" ]; then
        local ini_name
        ini_name=$(basename "$LSO_PHP_INI")
        if [ -f "$backup_path/php/$ini_name" ]; then
            log_info "Restoring $LSO_PHP_INI ..."
            cp -a "$backup_path/php/$ini_name" "$LSO_PHP_INI"
        fi
    fi

    # 5. Redis / MariaDB / sysctl / systemd
    if [ -d "$backup_path/redis" ] && [ -d "$(_bk_fs /etc/redis)" ]; then
        rsync -a --delete "$backup_path/redis/" "$(_bk_fs /etc/redis)/"
    fi
    if [ -d "$backup_path/sysctl" ] && [ -d "$(_bk_fs /etc/sysctl.d)" ]; then
        rsync -a --delete "$backup_path/sysctl/" "$(_bk_fs /etc/sysctl.d)/"
    fi
    if [ -d "$backup_path/systemd" ] && [ -d "$(_bk_fs /etc/systemd/system/lsws.service.d)" ]; then
        rsync -a --delete "$backup_path/systemd/" "$(_bk_fs /etc/systemd/system/lsws.service.d)/"
    fi
    if [ -d "$backup_path/mariadb" ]; then
        if [ -d "$(_bk_fs /etc/mysql/mariadb.conf.d)" ]; then
            rsync -a --delete "$backup_path/mariadb/" "$(_bk_fs /etc/mysql/mariadb.conf.d)/"
        elif [ -d "$(_bk_fs /etc/my.cnf.d)" ]; then
            rsync -a --delete "$backup_path/mariadb/" "$(_bk_fs /etc/my.cnf.d)/"
        fi
    fi

    return 0
}

################################################################################
# Restore Verification
################################################################################

# Verify restored files match backup checksums
verify_restored_files() {
    local backup_path="$1"
    local verified=0
    local mismatched=0

    log_info "Verifying restored files..."

    if [ -d "$backup_path/lsws-conf" ] && [ -n "${LSO_LSWS_ROOT:-}" ] && [ -d "${LSO_LSWS_ROOT}/conf" ]; then
        local bak_file
        while IFS= read -r -d '' bak_file; do
            local rel_path="${bak_file#"$backup_path"/lsws-conf/}"
            local cur_file="${LSO_LSWS_ROOT}/conf/$rel_path"

            if [ ! -f "$cur_file" ]; then
                log_warn "Missing after restore: $cur_file"
                mismatched=$((mismatched + 1))
                continue
            fi

            local bak_sum cur_sum
            bak_sum=$(file_checksum "$bak_file")
            cur_sum=$(file_checksum "$cur_file")

            if [ "$bak_sum" = "$cur_sum" ]; then
                verified=$((verified + 1))
            else
                log_warn "Checksum mismatch: $cur_file"
                mismatched=$((mismatched + 1))
            fi
        done < <(find "$backup_path/lsws-conf" -type f -print0 2>/dev/null)
    fi

    if [ "$mismatched" -eq 0 ]; then
        log_success "Verification passed: $verified files match backup"
        return 0
    else
        log_warn "Verification: $verified matched, $mismatched mismatched"
        return 1
    fi
}

################################################################################
# Backup Listing / Cleanup
################################################################################

list_backups() {
    echo ""
    echo "==========================================================="
    echo "Available Backups:"
    echo "==========================================================="

    local has_backups=false
    if [ -d "$BACKUP_DIR" ]; then
        local dir
        for dir in "$BACKUP_DIR"/*/; do
            [ -d "$dir" ] || continue
            has_backups=true
            break
        done
    fi

    if [ "$has_backups" = false ]; then
        echo "  No backups found"
        echo ""
        return 0
    fi

    # List backups sorted by mtime (newest first), portable stat
    local -a backups_with_mtime=()
    local dir
    for dir in "$BACKUP_DIR"/*/; do
        [ -d "$dir" ] || continue
        local mtime
        mtime=$(get_dir_mtime "$dir")
        backups_with_mtime+=("$mtime $dir")
    done

    printf '%s\n' "${backups_with_mtime[@]}" | \
        sort -rn | \
        while IFS=' ' read -r _ backup_path; do
            local backup="${backup_path%/}"
            backup="${backup##*/}"
            echo "  Backup: $backup"

            local manifest="${backup_path}manifest.txt"
            if [ -f "$manifest" ]; then
                sed -n 's/^\(timestamp\|edition\|panel\|target_site\):/    \1:/p' "$manifest"
            fi

            local size
            size=$(du -sh "$backup_path" 2>/dev/null | cut -f1)
            echo "    size: $size"
            echo ""
        done

    echo "==========================================================="
    echo "Restore with: litespeed-optimizer rollback <timestamp>"
    echo "==========================================================="
}

cleanup_old_backups() {
    local keep_count=${1:-10}

    local backup_count=0
    while IFS= read -r -d '' _; do
        backup_count=$((backup_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -print0)

    if [ "$backup_count" -le "$keep_count" ]; then
        return 0
    fi

    log_info "Cleaning up old backups (keeping last $keep_count)..."

    local -a backups_with_mtime=()
    local dir
    for dir in "$BACKUP_DIR"/*/; do
        [ -d "$dir" ] || continue
        local mtime
        mtime=$(get_dir_mtime "$dir")
        backups_with_mtime+=("$mtime $dir")
    done

    local delete_count=$((backup_count - keep_count))
    printf '%s\n' "${backups_with_mtime[@]}" | \
        sort -n | \
        head -n "$delete_count" | \
        while IFS=' ' read -r _ backup_path; do
            log_info "Removing old backup: ${backup_path##*/}"
            rm -rf "$backup_path"
        done
}
