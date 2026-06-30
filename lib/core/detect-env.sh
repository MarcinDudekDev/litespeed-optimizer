#!/bin/bash
################################################################################
# core/detect-env.sh - Environment Detection
################################################################################
# Detects edition (OLS vs LSWS Enterprise), control panel, config paths, PHP,
# WordPress sites, firewall and services. Exports LSO_* globals consumed by
# all feature modules.
#
# Test override: LSO_FS_ROOT prefixes every absolute path so the whole module
# runs against fixture trees (tests/configs/<fixture>/) without a real server.
# LSO_LSWS_ROOT overrides the LiteSpeed root directly (already prefixed).
################################################################################

# Honor LSO_LSWS_ROOT passed as an env var (captured before we reuse the
# name as a detection output global)
if [ -n "${LSO_LSWS_ROOT:-}" ] && [ -z "${LSO_LSWS_ROOT_OVERRIDE:-}" ]; then
    LSO_LSWS_ROOT_OVERRIDE="$LSO_LSWS_ROOT"
fi

# Globals exported by detect_environment()
LSO_LSWS_ROOT=""
LSO_EDITION=""          # ols | enterprise
LSO_PANEL=""            # cyberpanel | cpanel | directadmin | runcloud | plain
LSO_MAIN_CONF=""
LSO_APACHE_INCLUDE=""
LSO_VHOSTS_DIR=""
LSO_PHP_BIN=""
LSO_PHP_INI=""
LSO_PHP_VER=""
LSO_RESTART_CMD=""
LSO_PHP_RESTART=""
LSO_RAM_TIER=""
LSO_LSPHP_RSS_MB=""
LSO_WP_SITES=()
LSO_HAS_WPCLI=false
LSO_FIREWALL="none"
LSO_HAS_REDIS=false
LSO_HAS_MARIADB=false
LSO_LSWS_VERSION=""

# Filesystem prefix for fixture testing ("" on real servers)
_lso_fs() {
    echo "${LSO_FS_ROOT:-}$1"
}

################################################################################
# Detection Steps
################################################################################

# Locate the LiteSpeed root: env override > /usr/local/lsws > /opt/lsws
_detect_lsws_root() {
    if [ -n "${LSO_LSWS_ROOT_OVERRIDE:-}" ]; then
        LSO_LSWS_ROOT="$LSO_LSWS_ROOT_OVERRIDE"
        [ -d "$LSO_LSWS_ROOT" ] && return 0
        return 1
    fi

    local candidate
    for candidate in "$(_lso_fs /usr/local/lsws)" "$(_lso_fs /opt/lsws)"; do
        if [ -d "$candidate" ]; then
            LSO_LSWS_ROOT="$candidate"
            return 0
        fi
    done
    return 1
}

# Edition: Enterprise uses XML main config + serial.no; OLS uses plain-text conf
_detect_edition() {
    if [ -f "${LSO_LSWS_ROOT}/conf/httpd_config.xml" ] || [ -f "${LSO_LSWS_ROOT}/conf/serial.no" ]; then
        LSO_EDITION="enterprise"
        LSO_MAIN_CONF="${LSO_LSWS_ROOT}/conf/httpd_config.xml"
    elif [ -f "${LSO_LSWS_ROOT}/conf/httpd_config.conf" ]; then
        LSO_EDITION="ols"
        LSO_MAIN_CONF="${LSO_LSWS_ROOT}/conf/httpd_config.conf"
    else
        return 1
    fi

    # Version from binary when runnable (skipped silently on fixture trees)
    if [ -x "${LSO_LSWS_ROOT}/bin/lshttpd" ]; then
        LSO_LSWS_VERSION=$("${LSO_LSWS_ROOT}/bin/lshttpd" -v 2>/dev/null | head -1 || true)
        # Binary self-identification trumps file heuristics when available
        if echo "$LSO_LSWS_VERSION" | grep -qi "open"; then
            LSO_EDITION="ols"
        elif echo "$LSO_LSWS_VERSION" | grep -qi "enterprise"; then
            LSO_EDITION="enterprise"
        fi
    fi

    return 0
}

# Panel detection via directory markers
_detect_panel() {
    if [ -d "$(_lso_fs /usr/local/CyberCP)" ] || [ -d "$(_lso_fs /etc/cyberpanel)" ]; then
        LSO_PANEL="cyberpanel"
    elif [ -d "$(_lso_fs /usr/local/cpanel)" ]; then
        LSO_PANEL="cpanel"
    elif [ -d "$(_lso_fs /usr/local/directadmin)" ]; then
        LSO_PANEL="directadmin"
    elif [ -d "$(_lso_fs /etc/runcloud)" ] || [ -d "$(_lso_fs /opt/runcloud)" ]; then
        LSO_PANEL="runcloud"
    else
        LSO_PANEL="plain"
    fi
}

# Per-panel config paths and restart commands
_detect_paths() {
    LSO_APACHE_INCLUDE=""
    if [ "$LSO_PANEL" = "cpanel" ]; then
        LSO_APACHE_INCLUDE="$(_lso_fs /etc/apache2/conf.d/includes/pre_main_global.conf)"
    fi

    if [ "$LSO_EDITION" = "ols" ]; then
        LSO_VHOSTS_DIR="${LSO_LSWS_ROOT}/conf/vhosts"
    else
        LSO_VHOSTS_DIR="${LSO_LSWS_ROOT}/conf/vhosts"
    fi

    # Restart command resolution (most specific first)
    if [ "$LSO_PANEL" = "cpanel" ] && [ -x "$(_lso_fs /scripts/restartsrv_lsws)" ]; then
        LSO_RESTART_CMD="$(_lso_fs /scripts/restartsrv_lsws)"
    elif [ -z "${LSO_FS_ROOT:-}" ] && command -v systemctl &>/dev/null \
         && systemctl list-unit-files 2>/dev/null | grep -q '^lsws\.service'; then
        LSO_RESTART_CMD="systemctl restart lsws"
    elif [ -x "${LSO_LSWS_ROOT}/bin/lswsctrl" ]; then
        LSO_RESTART_CMD="${LSO_LSWS_ROOT}/bin/lswsctrl restart"
    else
        LSO_RESTART_CMD=""
    fi

    # shellcheck disable=SC2034  # Consumed by opcache/lscwp features (Phase 2+)
    LSO_PHP_RESTART="touch ${LSO_LSWS_ROOT}/admin/tmp/.lsphp_restart.txt"
}

# PHP binary + ini resolution. Never hardcode ini paths (DA uses /usr/local/phpXX)
_detect_php() {
    LSO_PHP_BIN=""
    LSO_PHP_INI=""
    LSO_PHP_VER=""

    # Prefer the lsphp the vhost handler ACTUALLY runs (issue #1). The active
    # version is whatever `extProcessor lsphp { path lsphpNN/bin/lsphp }` points
    # to in the main config (OLS conf or LSWS xml) — not necessarily the newest
    # installed. Tuning the wrong lsphp's php.ini/OPcache is a silent no-op
    # (e.g. box runs lsphp82 but lsphp83 is also installed -> we'd tune 83).
    local configured_dir=""
    if [ -f "$LSO_MAIN_CONF" ]; then
        configured_dir=$(grep -oE 'lsphp[0-9]+/bin/lsphp' "$LSO_MAIN_CONF" 2>/dev/null | head -1 || true)
        configured_dir="${configured_dir%%/*}"
    fi
    if [ -n "$configured_dir" ] && [ -f "${LSO_LSWS_ROOT}/${configured_dir}/bin/php" ]; then
        LSO_PHP_BIN="${LSO_LSWS_ROOT}/${configured_dir}/bin/php"
    fi

    # Fallback: the newest lsphp bundled with LiteSpeed (no handler match found)
    local d
    if [ -z "$LSO_PHP_BIN" ]; then
        for d in "${LSO_LSWS_ROOT}"/lsphp*/bin; do
            [ -d "$d" ] || continue
            if [ -f "$d/php" ]; then
                LSO_PHP_BIN="$d/php"   # keep last (highest version) match
            fi
        done
    fi

    # Fallback: system php
    if [ -z "$LSO_PHP_BIN" ] && command -v php &>/dev/null && [ -z "${LSO_FS_ROOT:-}" ]; then
        LSO_PHP_BIN=$(command -v php)
    fi

    # Resolve loaded ini by asking the binary (only when actually executable)
    if [ -n "$LSO_PHP_BIN" ] && [ -x "$LSO_PHP_BIN" ] && [ -z "${LSO_FS_ROOT:-}" ]; then
        LSO_PHP_INI=$("$LSO_PHP_BIN" -i 2>/dev/null | grep 'Loaded Configuration File' | awk '{print $NF}' || true)
        [ "$LSO_PHP_INI" = "(none)" ] && LSO_PHP_INI=""
        LSO_PHP_VER=$("$LSO_PHP_BIN" -v 2>/dev/null | head -1 | sed -n 's/^PHP \([0-9.]*\).*/\1/p' || true)
    elif [ -n "$LSO_PHP_BIN" ]; then
        # Fixture mode: derive version from lsphpXX directory name
        LSO_PHP_VER=$(echo "$LSO_PHP_BIN" | sed -n 's|.*/lsphp\([0-9]\)\([0-9]*\)/.*|\1.\2|p')
    fi
}

# WordPress site discovery: docroots containing wp-config.php
_detect_wp_sites() {
    LSO_WP_SITES=()

    local parent docroot
    # CyberPanel + generic layouts: /home/<domain>/public_html, /var/www/<site>(/html),
    # plus default OLS vhost docroots ($LSWS_ROOT/<vhost>/html, e.g. Example/html)
    for parent in "$(_lso_fs /home)" "$(_lso_fs /var/www)" "$LSO_LSWS_ROOT"; do
        [ -d "$parent" ] || continue
        for docroot in "$parent"/*/public_html "$parent"/*/html "$parent"/*; do
            [ -d "$docroot" ] || continue
            if [ -f "$docroot/wp-config.php" ]; then
                # Dedup (a site matches both */ and */public_html patterns otherwise)
                local known seen=false
                for known in ${LSO_WP_SITES[@]+"${LSO_WP_SITES[@]}"}; do
                    if [ "$known" = "$docroot" ]; then
                        seen=true
                        break
                    fi
                done
                if [ "$seen" = false ]; then
                    LSO_WP_SITES+=("$docroot")
                fi
            fi
        done
    done

    if [ -n "${LSO_WP_BIN:-}" ] && [ -x "${LSO_WP_BIN}" ]; then
        LSO_HAS_WPCLI=true
    elif command -v wp &>/dev/null; then
        LSO_HAS_WPCLI=true
    else
        LSO_HAS_WPCLI=false
    fi
}

# Firewall + service presence
_detect_services() {
    if [ -f "$(_lso_fs /etc/csf/csf.conf)" ]; then
        LSO_FIREWALL="csf"
    elif [ -z "${LSO_FS_ROOT:-}" ] && command -v ufw &>/dev/null; then
        LSO_FIREWALL="ufw"
    elif [ -z "${LSO_FS_ROOT:-}" ] && command -v firewall-cmd &>/dev/null; then
        LSO_FIREWALL="firewalld"
    else
        LSO_FIREWALL="none"
    fi

    LSO_HAS_REDIS=false
    if [ -n "${LSO_FS_ROOT:-}" ]; then
        if [ -e "$(_lso_fs /etc/redis/redis.conf)" ]; then
            LSO_HAS_REDIS=true
        fi
    elif command -v redis-server &>/dev/null || command -v redis-cli &>/dev/null; then
        LSO_HAS_REDIS=true
    fi

    LSO_HAS_MARIADB=false
    if [ -n "${LSO_FS_ROOT:-}" ]; then
        if [ -d "$(_lso_fs /etc/mysql)" ] || [ -d "$(_lso_fs /etc/my.cnf.d)" ]; then
            LSO_HAS_MARIADB=true
        fi
    elif command -v mariadbd &>/dev/null || command -v mysqld &>/dev/null || command -v mysql &>/dev/null; then
        LSO_HAS_MARIADB=true
    fi

    return 0
}

################################################################################
# Public API
################################################################################

# detect_environment - run full detection, set all LSO_* globals
# Returns: 0 if a LiteSpeed install was found, 1 otherwise
detect_environment() {
    if ! _detect_lsws_root; then
        LSO_EDITION=""
        return 1
    fi

    if ! _detect_edition; then
        LSO_EDITION=""
        return 1
    fi

    _detect_panel
    _detect_paths
    _detect_php
    _detect_wp_sites
    _detect_services

    LSO_RAM_TIER=$(sysinfo_ram_tier)
    # shellcheck disable=SC2034  # Consumed by lsapi-tuning sizing (Phase 2+)
    LSO_LSPHP_RSS_MB=$(sysinfo_lsphp_rss)

    return 0
}

# Human-readable environment report
detect_report() {
    echo ""
    echo "=== LiteSpeed Environment ==="
    echo "  Edition:         ${LSO_EDITION}$([ "$LSO_EDITION" = "enterprise" ] && echo ' (main config is READ-ONLY for this tool)')"
    echo "  Root:            ${LSO_LSWS_ROOT}"
    echo "  Main config:     ${LSO_MAIN_CONF}"
    if [ -n "$LSO_LSWS_VERSION" ]; then
        echo "  Version:         ${LSO_LSWS_VERSION}"
    fi
    echo "  Panel:           ${LSO_PANEL}"
    if [ -n "$LSO_APACHE_INCLUDE" ]; then
        echo "  Apache include:  ${LSO_APACHE_INCLUDE}"
    fi
    echo "  Vhosts dir:      ${LSO_VHOSTS_DIR}"
    echo "  Restart cmd:     ${LSO_RESTART_CMD:-<none found>}"
    echo ""
    echo "=== PHP ==="
    echo "  Binary:          ${LSO_PHP_BIN:-<not found>}"
    echo "  Version:         ${LSO_PHP_VER:-unknown}"
    echo "  php.ini:         ${LSO_PHP_INI:-<not resolved>}"
    echo "  wp-cli:          $([ "$LSO_HAS_WPCLI" = true ] && echo present || echo absent)"
    echo ""
    echo "=== WordPress Sites ==="
    if [ ${#LSO_WP_SITES[@]} -gt 0 ]; then
        local site
        for site in "${LSO_WP_SITES[@]}"; do
            echo "  - $site"
        done
    else
        echo "  (none found)"
    fi
    echo ""
    echo "=== Services ==="
    echo "  Firewall:        ${LSO_FIREWALL}"
    echo "  Redis:           $([ "$LSO_HAS_REDIS" = true ] && echo present || echo absent)"
    echo "  MariaDB/MySQL:   $([ "$LSO_HAS_MARIADB" = true ] && echo present || echo absent)"
    echo ""
    echo "=== Sizing ==="
    sysinfo_summary | sed 's/^/  /'
    echo ""
}

# JSON environment report
detect_report_json() {
    local sites_json=""
    if [ ${#LSO_WP_SITES[@]} -gt 0 ]; then
        local site
        for site in "${LSO_WP_SITES[@]}"; do
            local esite
            esite=$(json_escape "$site")
            if [ -n "$sites_json" ]; then
                sites_json="${sites_json},\"${esite}\""
            else
                sites_json="\"${esite}\""
            fi
        done
    fi

    json_output "$(printf '{"command":"detect","version":"%s","edition":"%s","panel":"%s","lsws_root":"%s","main_conf":"%s","restart_cmd":"%s","php_bin":"%s","php_ver":"%s","ram_tier":"%s","firewall":"%s","has_redis":%s,"has_mariadb":%s,"has_wpcli":%s,"wp_sites":[%s]}' \
        "$(json_escape "${VERSION:-0.1.0}")" "$(json_escape "$LSO_EDITION")" "$(json_escape "$LSO_PANEL")" "$(json_escape "$LSO_LSWS_ROOT")" "$(json_escape "$LSO_MAIN_CONF")" \
        "$(json_escape "$LSO_RESTART_CMD")" "$(json_escape "$LSO_PHP_BIN")" "$(json_escape "$LSO_PHP_VER")" "$(json_escape "$LSO_RAM_TIER")" "$(json_escape "$LSO_FIREWALL")" \
        "$LSO_HAS_REDIS" "$LSO_HAS_MARIADB" "$LSO_HAS_WPCLI" "$sites_json")"
}
