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
#   ├── php/  redis/  mariadb/  sysctl/  systemd/  fail2ban/   (when present)
#   └── lscwp/<site>.json   wp litespeed-option export (Phase 3)
#
# ModSec/CRS config lives under $LSO_LSWS_ROOT/conf/owasp and is covered by
# lsws-conf. fail2ban (/etc/fail2ban) is outside the conf tree so it is captured
# separately. apt PACKAGES are not part of a backup — rollback restores config.
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

    # 5. Redis / MariaDB / sysctl / systemd / fail2ban drop-ins (when present;
    # non-critical). fail2ban state (jail.local, jail.d, filter.d) lives OUTSIDE
    # the LSWS conf tree, so without this a bad jail from the fail2ban feature
    # would survive a conf-tree-only rollback. (The ModSec/CRS tree, by contrast,
    # lives under ${LSO_LSWS_ROOT}/conf/owasp and is already captured by the
    # lsws-conf backup above. apt-installed PACKAGES — ols-modsecurity, fail2ban
    # — are NOT rolled back; rollback restores config, not package state.)
    local src dst
    for src in /etc/redis /etc/mysql/mariadb.conf.d /etc/my.cnf.d /etc/sysctl.d /etc/systemd/system/lsws.service.d /etc/fail2ban; do
        local real_src
        real_src="$(_bk_fs "$src")"
        [ -d "$real_src" ] || continue
        case "$src" in
            /etc/redis)            dst="redis" ;;
            /etc/mysql/*|/etc/my.cnf.d) dst="mariadb" ;;
            /etc/sysctl.d)         dst="sysctl" ;;
            /etc/fail2ban)         dst="fail2ban" ;;
            *)                     dst="systemd" ;;
        esac
        mkdir -p "${CURRENT_BACKUP_DIR}/${dst}"
        rsync -a "$real_src/" "${CURRENT_BACKUP_DIR}/${dst}/" 2>/dev/null || log_warn "Could not backup $real_src"
    done

    # ModSecurity audit-log logrotate drop-in — a SINGLE owned file. /etc/logrotate.d
    # is shared system-wide, so we never rsync the whole dir with --delete (that would
    # wipe unrelated logrotate configs on rollback). Back up just our file.
    if [ -f "$(_bk_fs /etc/logrotate.d/lso-modsec)" ]; then
        mkdir -p "${CURRENT_BACKUP_DIR}/logrotate"
        cp -p "$(_bk_fs /etc/logrotate.d/lso-modsec)" "${CURRENT_BACKUP_DIR}/logrotate/lso-modsec" 2>/dev/null \
            || log_warn "Could not backup /etc/logrotate.d/lso-modsec"
    fi

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
            # Reject traversal / empty (tampered backup -> arbitrary write as root)
            case "$docroot" in ''|*..*) log_warn "Unsafe docroot in backup ($docroot) — skipping"; continue ;; esac
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
    if [ -d "$backup_path/fail2ban" ] && [ -d "$(_bk_fs /etc/fail2ban)" ]; then
        log_info "Restoring /etc/fail2ban ..."
        rsync -a --delete "$backup_path/fail2ban/" "$(_bk_fs /etc/fail2ban)/"
        # Activate the restored jails (best-effort; real box only). Without a
        # reload the restored config sits on disk while fail2ban keeps running the
        # bad jail. Skipped in fixture mode (no daemon, and we never touch /etc).
        if [ -z "${LSO_FS_ROOT:-}" ] && command -v fail2ban-client >/dev/null 2>&1; then
            fail2ban-client reload >/dev/null 2>&1 \
                || log_warn "fail2ban config restored but reload failed — run 'fail2ban-client reload' manually"
            # Clear the active ban table: a ban placed DURING the bad run persists in
            # the runtime DB (/var/lib/fail2ban) after a config-only restore. unban
            # --all flushes it so rollback truly undoes the run. It clears ALL current
            # bans (including any pre-existing ones) — acceptable on a rollback, where
            # the goal is a clean pre-change state. Live-only (guarded above).
            fail2ban-client unban --all >/dev/null 2>&1 \
                || log_warn "fail2ban reloaded but 'unban --all' failed — clear stale bans manually if needed"
        fi
    fi

    # ModSecurity logrotate drop-in (single owned file; never touch other logrotate
    # configs). Restore the backed-up copy if present; otherwise the backup predates
    # the file, i.e. this run added it — remove it so rollback truly undoes the run.
    if [ -f "$backup_path/logrotate/lso-modsec" ]; then
        log_info "Restoring /etc/logrotate.d/lso-modsec ..."
        mkdir -p "$(_bk_fs /etc/logrotate.d)"
        cp -p "$backup_path/logrotate/lso-modsec" "$(_bk_fs /etc/logrotate.d/lso-modsec)" 2>/dev/null \
            || log_warn "Could not restore /etc/logrotate.d/lso-modsec"
    elif [ -f "$(_bk_fs /etc/logrotate.d/lso-modsec)" ] \
        && grep -q "Managed by litespeed-optimizer" "$(_bk_fs /etc/logrotate.d/lso-modsec)" 2>/dev/null; then
        # Only remove OUR file (marker-guarded): the backup predates it, so this run
        # added it. Never touch an identically-named file an operator created.
        log_info "Removing /etc/logrotate.d/lso-modsec (added during the rolled-back run) ..."
        rm -f "$(_bk_fs /etc/logrotate.d/lso-modsec)"
    fi

    # 6. LSCWP plugin options — the inverse of the pre-change `litespeed-option
    # export` the lscwp feature wrote into <backup>/lscwp/<slug>.json. Without
    # this, rollback restores server files but leaves LSCWP options changed
    # (SPEC §7). Best-effort: needs wp-cli + a working WP install, so failures
    # warn but never abort the file restore. Guarded by lso_wp so the backup
    # unit test (which sources backup.sh alone) skips it.
    if [ -d "$backup_path/lscwp" ] && type -t lso_wp &>/dev/null; then
        local json docroot_file lscwp_docroot
        for json in "$backup_path/lscwp"/*.json; do
            [ -f "$json" ] && [ -s "$json" ] || continue
            docroot_file="${json%.json}.docroot"
            if [ ! -f "$docroot_file" ]; then
                log_warn "No docroot sidecar for $(basename "$json") — skipping LSCWP restore"
                continue
            fi
            lscwp_docroot=$(cat "$docroot_file")
            # Reject traversal / empty (tampered backup -> arbitrary wp target)
            case "$lscwp_docroot" in
                ''|*..*) log_warn "Unsafe docroot in backup ($lscwp_docroot) — skipping LSCWP restore"; continue ;;
            esac
            # Must be a real WordPress docroot (wp-config.php present) — defends
            # against a sidecar pointing at an absolute non-WP path like /etc.
            if [ ! -f "${lscwp_docroot%/}/wp-config.php" ]; then
                log_warn "No wp-config.php under $lscwp_docroot — skipping LSCWP restore"
                continue
            fi
            if [ -d "$lscwp_docroot" ]; then
                log_info "Restoring LSCWP options -> $lscwp_docroot"
                lso_wp "$lscwp_docroot" litespeed-option import "$json" >/dev/null 2>&1 \
                    || log_warn "LSCWP option import failed for $lscwp_docroot (file restore still applied)"
            else
                log_warn "Docroot gone ($lscwp_docroot) — skipping LSCWP restore"
            fi
        done
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
