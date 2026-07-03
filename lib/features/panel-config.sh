#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/panel-config.sh - Panel-specific server-config guidance + artifact
################################################################################
# OPT-IN (--panel-config), default-off, NOT in any profile. For panels that
# OWN or REGENERATE the web-server config (DirectAdmin/RunCloud/Plesk/Enhance/
# ADC/aaPanel/CloudPanel/Hestia/ISPConfig), a direct httpd_config edit gets
# clobbered on the next panel rebuild, and the real per-domain destination path
# needs box-specific user/domain info + each panel's rebuild pipeline (none of
# which is validatable offline). So the tool otherwise treats those hosts as
# "manual-only". This feature upgrades that generic message into CONCRETE,
# copy-paste, panel-specific output.
#
# SAFE-BY-DESIGN: it writes a READY-TO-APPLY artifact to OUR OWN labeled staging
# file under the data dir (panel-config/<panel>-recommended.conf) — it NEVER
# writes into panel internals and NEVER runs a panel rebuild/reload. It tells the
# operator the exact DESTINATION path + APPLY command for that panel (verified
# from official docs) so they can copy it in and rebuild themselves.
#
# On plain/cyberpanel/cpanel (where optimize writes server config directly) this
# feature is a no-op — there is nothing to hand off. It only fires on the
# regenerate/own-config panels (_lso_panel_restricted).
################################################################################

# Owned artifact path: OUR staging file under the data dir (goes through _lso_fs
# so fixtures work). Same DATA_DIR resolution the entrypoint uses.
_pc_outfile() {
    _lso_fs "${LSO_DATA_DIR:-$HOME/.litespeed-optimizer}/panel-config/${LSO_PANEL:-panel}-recommended.conf"
}

# First site's domain from LSO_WP_SITES (strip a trailing public_html/html, then
# basename); falls back to the literal <your-domain> placeholder when no site was
# detected. Pure lookup (called in $()): no logging, no case.
_pc_domain() {
    local site base
    if [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ]; then
        site="${LSO_WP_SITES[0]%/}"
        site="${site%/public_html}"
        site="${site%/html}"
        base="$(basename "$site" 2>/dev/null || true)"
        # Only trust the basename as a domain when it actually LOOKS like one: a
        # hostname charset AND at least one dot. This avoids emitting a confidently
        # WRONG domain for generic docroots — /var/www/html strips to "www", and
        # /home/<user>/public_html strips to "<user>" — both of which lack a dot and
        # so fall back to the <your-domain> placeholder (a placeholder the operator
        # will obviously fill in is safer than a plausible-but-wrong name). The
        # charset check also blocks a hostile directory name (e.g. an embedded
        # newline) from breaking out of a comment line in the generated artifact.
        case "$base" in
            *.*)
                case "$base" in
                    *[!A-Za-z0-9.-]*) : ;;
                    *) printf '%s' "$base"; return 0 ;;
                esac
                ;;
        esac
    fi
    printf '%s' "<your-domain>"
}

# keepAliveTimeout per tier (self-contained copy of the server-tuning table so
# this feature does not depend on another feature's private helper). Pure lookup.
_pc_keepalive() {
    case "$1" in
        1g|2g) echo 5 ;;
        4g)    echo 3 ;;
        *)     echo 2 ;;
    esac
}

# True when <file> already EXISTS but was NOT written by us (lacks the managed
# marker) — an operator-owned file we must refuse to clobber. Our own prior file
# DOES carry the marker, so idempotent re-apply is allowed.
_pc_unmanaged_exists() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -q "Managed by litespeed-optimizer" "$file" 2>/dev/null && return 1
    return 0
}

# Write the artifact atomically (DRY_RUN-aware). Mirrors mariadb's _mdb_write_file:
# secure_mktemp + copy_file_permissions + atomic mv + "[DRY RUN] Would write ..." log.
_pc_write_file() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write ${file#${LSO_FS_ROOT:-}}"
        cat >/dev/null
        return 0
    fi
    mkdir -p "$dir" || { log_warn "panel-config: cannot create ${dir}"; return 1; }
    local tmp
    tmp=$(secure_mktemp "${dir}/.lso-panelcfg.XXXXXX") || return 1
    # errexit is OFF inside `if feature_apply ...`, so a silent cat/mv failure would
    # otherwise skip rollback — propagate it explicitly.
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    log_info "Wrote ${file#${LSO_FS_ROOT:-}}"
}

# VHOST-LEVEL block: directives that ARE expressible in a per-domain include.
# Conservative security response headers (mirrors lib/features/security.sh) plus
# a note that LSCWP page caching rides the site's .htaccess (already works on
# panel hosts). Pure echoes (no case): safe to call in $().
_pc_vhost_section() {
    echo "# ==== VHOST-LEVEL (safe to include per-domain) ===================="
    echo "# These directives ARE expressible in a per-domain include. LiteSpeed"
    echo "# honors mod_headers-style response headers. Page caching itself is"
    echo "# driven by LSCWP through the site's own .htaccess, which already works"
    echo "# on panel-managed hosts — no server-config change is needed for that."
    echo "<IfModule mod_headers.c>"
    echo "    Header set X-Content-Type-Options \"nosniff\""
    echo "    Header set X-Frame-Options \"SAMEORIGIN\""
    echo "    Header set Referrer-Policy \"strict-origin-when-cross-origin\""
    echo "</IfModule>"
}

# SERVER-LEVEL block: tier-computed recommendations that CANNOT live in a
# per-domain include (they belong in the server-level tuning{}/extprocessor{},
# which the panel owns). Emitted COMMENTED with a one-line why for each — set
# these through the panel's WebAdmin. Args: tier maxconn keepalive children.
# Pure echoes (no case): safe to call in $().
_pc_server_section() {
    local tier="$1" maxconn="$2" keepalive="$3" children="$4"
    echo "# ==== SERVER-LEVEL (set via WebAdmin / panel — NOT in a per-domain include) ===="
    echo "# These are server/vhost-tuning + PHP external-app values sized for this"
    echo "# box's RAM tier (${tier}). They live in the SERVER config, which the panel"
    echo "# owns and regenerates, so set them through the panel's WebAdmin/UI — do"
    echo "# NOT paste them into the per-domain include above (they would be ignored"
    echo "# there and clobbered on the next rebuild)."
    echo "# tuning {"
    echo "#     maxConnections    ${maxconn}     # concurrent-connection ceiling for this RAM tier"
    echo "#     keepAliveTimeout  ${keepalive}   # seconds; a short keepalive frees workers under load"
    echo "#     quicEnable        1              # HTTP/3 (QUIC over UDP/443); also open UDP/443 in the firewall"
    echo "# }"
    echo "# extprocessor lsphp {"
    echo "#     maxConns              ${children}   # MUST equal PHP_LSAPI_CHILDREN (the LSO invariant)"
    echo "#     env PHP_LSAPI_CHILDREN=${children}  # PHP worker count sized to this RAM tier"
    echo "# }"
}

feature_apply_custom_panel_config() {
    # 1. Opt-in gate: never generate anything unless explicitly asked.
    if [ "${LSO_PANEL_CONFIG:-}" != "1" ]; then
        log_info "panel-config: not enabled — pass --panel-config to generate panel-specific server-config guidance + a ready-to-apply artifact for panel-managed hosts; OPT-IN, default-off"
        return 0
    fi

    # 2. Non-restricted panels (plain/cyberpanel/cpanel): optimize writes server
    #    config directly, so there is nothing to hand off. Info-only, nothing written.
    if ! { type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; }; then
        log_info "panel-config: ${LSO_PANEL:-plain} is not a regenerate-owning panel — server config is applied directly by optimize; nothing to generate."
        return 0
    fi

    # 3. Resolve panel + domain + RAM-tier recommended values. Compute tier at the
    #    STATEMENT level (never inside a captured $() with logging).
    local ram cores tier domain maxconn keepalive children
    ram=$(sysinfo_ram_mb)
    cores=$(sysinfo_cpu_cores)
    tier=$(sysinfo_ram_tier)
    domain=$(_pc_domain)
    maxconn=$(lso_max_connections "$ram")
    keepalive=$(_pc_keepalive "$tier")
    children=$(lso_children "$ram" "$cores" 80)

    local outfile
    outfile="$(_pc_outfile)"

    # 4. Ownership guard: refuse to overwrite an operator-owned file at our path.
    #    Our own prior artifact carries the marker, so idempotent re-apply is fine.
    #    READ-ONLY check — kept active even under DRY_RUN so a dry run surfaces the
    #    conflict — and fixture-safe (outfile is an _lso_fs-prefixed path).
    if _pc_unmanaged_exists "$outfile"; then
        log_error "panel-config: refusing to overwrite ${outfile#${LSO_FS_ROOT:-}} — it exists WITHOUT our '# Managed by litespeed-optimizer' marker (operator-owned). Move/remove that file, then re-run --panel-config."
        return 1
    fi

    local vhost_section server_section
    vhost_section="$(_pc_vhost_section)"
    server_section="$(_pc_server_section "$tier" "$maxconn" "$keepalive" "$children")"

    # 5. Write the artifact. Content is panel-specific: the DESTINATION path + APPLY
    #    command are verified from each panel's official docs. Statement-level case
    #    (NOT inside $()) so each branch pipes its own heredoc to the writer.
    local apply_cmd=""
    case "${LSO_PANEL}" in
        directadmin)
            apply_cmd="da build rewrite_confs   (then reload LiteSpeed)"
            _pc_write_file "$outfile" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Panel: DirectAdmin (owns/regenerates the web-server config).
#
# DESTINATION (per-domain custom directives — the CUSTOM token in this file):
#   /usr/local/directadmin/data/users/<USER>/domains/${domain}.cust_httpd
#   (replace <USER> with the DirectAdmin account that owns ${domain})
# APPLY:
#   da build rewrite_confs
#   then reload LiteSpeed (LSWS reads the Apache-style custom config).
# NOTE: never edit httpd_config.xml directly — DirectAdmin regenerates it.
#
${vhost_section}
#
${server_section}
EOF
            ;;
        plesk)
            apply_cmd="plesk repair web -y   (or httpdmng --reconfigure-domain ${domain})"
            _pc_write_file "$outfile" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Panel: Plesk (the LiteSpeed-for-Plesk extension manages the config).
#
# DESTINATION ("Additional directives for HTTP/HTTPS" for ${domain}):
#   /var/www/vhosts/system/${domain}/conf/vhost.conf
#   (and vhost_ssl.conf for the HTTPS directives)
# APPLY:
#   plesk repair web -y
#   or: /usr/local/psa/admin/sbin/httpdmng --reconfigure-domain ${domain}
#   then reload the web server.
#
${vhost_section}
#
${server_section}
EOF
            ;;
        enhance)
            apply_cmd="edit as root over SSH, then reload the web server"
            _pc_write_file "$outfile" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Panel: Enhance (regenerates configs from its own templates).
#
# DESTINATION (per-domain include for ${domain}):
#   Apache: /etc/apache2/vhost_includes/${domain}.conf
#   nginx : /etc/nginx/vhost_includes/${domain}.conf   (Enhance >= 12.0.0)
# APPLY:
#   edit the file as root over SSH, then reload the web server.
#
${vhost_section}
#
${server_section}
EOF
            ;;
        runcloud)
            apply_cmd="paste into RunCloud > Web Application > NGINX Config, then rebuild"
            _pc_write_file "$outfile" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Panel: RunCloud (NGINX-native — does NOT run LiteSpeed).
#
# IMPORTANT: RunCloud serves with NGINX, so LiteSpeed vhost/server tuning
# (tuning{}, extprocessor lsphp{}, quicEnable) does NOT apply here — those
# directives are LiteSpeed-only. Use RunCloud's own performance controls.
#
# DESTINATION (RunCloud custom NGINX config):
#   /etc/nginx-rc/extra.d/<webapp>.<slot>.<label>.conf
# APPLY:
#   RunCloud panel > your Web Application > "NGINX Config", then Rebuild.
#
# NGINX note: set security response headers there instead, e.g.
#   add_header X-Content-Type-Options "nosniff" always;
#   add_header X-Frame-Options "SAMEORIGIN" always;
#   add_header Referrer-Policy "strict-origin-when-cross-origin" always;
# (RAM-tier ${tier}; PHP worker sizing is managed via RunCloud's PHP-FPM pool.)
EOF
            ;;
        adc)
            apply_cmd="tune at the load-balancer level via LiteSpeed Web ADC WebAdmin (port 7090)"
            _pc_write_file "$outfile" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Panel: LiteSpeed Web ADC (a load balancer, not a vhost server).
#
# IMPORTANT: the ADC is a load balancer and does NOT serve vhosts, so
# per-domain / PHP "server tuning" (tuning{}, extprocessor lsphp{}) does NOT
# apply here. Its config is /usr/local/lslb/conf/lslbd_config.xml, owned by
# the ADC. Tuning is LB-level and out of scope for per-domain vhost directives.
# APPLY:
#   LiteSpeed Web ADC WebAdmin console (default port 7090) — adjust the
#   load-balancer / cluster settings there. Per-vhost / PHP tuning belongs on
#   the BACKEND LiteSpeed nodes (run 'litespeed-optimizer optimize' there),
#   NOT on the ADC — so no vhost directives are emitted here.
EOF
            ;;
        *)
            # aapanel/cloudpanel/hestia/ispconfig: no verified per-domain path —
            # generic manual-only guidance (apply via the panel's custom-config UI).
            apply_cmd="apply the recommended values via your panel's custom-config UI, then rebuild"
            _pc_write_file "$outfile" <<EOF || return 1
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Panel: ${LSO_PANEL} (regenerates/owns the web-server config).
#
# No verified per-domain destination path for this panel — this artifact is
# MANUAL-ONLY: apply the recommended values via your panel's custom-config UI
# (look for "custom directives" / "additional config" for ${domain}), then let
# the panel rebuild. Do NOT edit httpd_config.xml directly (it is regenerated).
#
${vhost_section}
#
${server_section}
EOF
            ;;
    esac

    if [ "${DRY_RUN:-false}" = true ]; then
        # DRY_RUN: _pc_write_file was a no-op, so don't claim we "wrote" it.
        log_info "panel-config: [DRY RUN] would write ${outfile#${LSO_FS_ROOT:-}} — review it, then apply via: ${apply_cmd}"
    else
        log_success "panel-config: wrote ${outfile#${LSO_FS_ROOT:-}} — review it, then apply via: ${apply_cmd}"
    fi

    # 6. Live-only reminder (guarded behind empty LSO_FS_ROOT + not DRY_RUN): this
    #    tool NEVER runs the panel command or restarts anything — it is the
    #    operator's step to apply the artifact and rebuild.
    if [ -z "${LSO_FS_ROOT:-}" ] && [ "${DRY_RUN:-false}" != true ]; then
        log_info "panel-config: this tool never touches panel internals or triggers a rebuild — copy the artifact to the DESTINATION shown inside it and run the APPLY command yourself."
    fi
}

# Detected iff our artifact exists AND carries the managed marker (advisory
# artifact detection — this feature writes to our own staging file, so a marked
# file at our path is proof we generated guidance for this panel).
feature_detect_custom_panel_config() {
    local outfile
    outfile="$(_pc_outfile)"
    [ -f "$outfile" ] || return 1
    grep -q "Managed by litespeed-optimizer" "$outfile" 2>/dev/null || return 1
    return 0
}

FEATURE_ID="panel-config"
FEATURE_DISPLAY="Panel-specific server-config guidance"
FEATURE_DETECT_PATTERN="panel-config"
FEATURE_SCOPE="global"
FEATURE_ALIASES="panel"
feature_register
