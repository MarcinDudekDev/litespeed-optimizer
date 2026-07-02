#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/modsec.sh - ModSecurity v3 + OWASP CRS, DetectionOnly (LIVE Item 2)
################################################################################
# OPT-IN (--modsec), default-off. OLS = libModSecurity v3 ONLY (CRS 4.x; 2.9-syntax
# rulesets will not load). This feature ships DetectionOnly and NEVER enforces —
# the enforce flip is a separate, gated flag (--modsec-enforce, Item 2's sibling
# Item 4) that refuses unless the engine is already DetectionOnly.
#
# Layout (all under the LSWS conf tree so backup/rollback covers it):
#   conf/modsec/modsec_includes.conf       <- modsecurity_rules_file target (ours)
#   conf/modsec/wp_exclusions_before.conf  <- enable CRS WP exclusion plugin
#   conf/modsec/wp_exclusions_after.conf   <- pre-seeded Woo/WP FP exclusions
# The httpd_config `module mod_security { }` block (via lso_conf_set) only carries
# ls_enabled / modsecurity on / modsecurity_rules_file. SecRuleEngine DetectionOnly
# lives in the includes file — so DetectionOnly is enforced by construction.
#
# CRS ruleset install (apt `ols-modsecurity`, .example templates) is a LIVE/package
# step and is NOT done here; if a CRS is already present under conf/owasp/ we wire
# its Includes. Live-only preflight (module .so load, CRS parse via error-log tail)
# is guarded behind empty-LSO_FS_ROOT so fixtures skip it. audit log is
# RelevantOnly + logrotate'd (disk exhaustion can down a store even in DetectionOnly).
################################################################################

_ms_conf_dir() { _lso_fs "${LSO_LSWS_ROOT#${LSO_FS_ROOT:-}}/conf/modsec"; }
_ms_crs_dir()  { _lso_fs "${LSO_LSWS_ROOT#${LSO_FS_ROOT:-}}/conf/owasp"; }
# Real (un-prefixed) LSWS root, for values written INTO config files (live paths).
_ms_real_lsws() { printf '%s' "${LSO_LSWS_ROOT#${LSO_FS_ROOT:-}}"; }

# Write a whole owned file atomically (DRY_RUN-aware). Args: <abs-path> <<heredoc via stdin>>
_ms_write_file() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write ${file#${LSO_FS_ROOT:-}}"
        cat >/dev/null
        return 0
    fi
    mkdir -p "$dir" || { log_warn "modsec: cannot create ${dir}"; return 1; }
    local tmp
    tmp=$(secure_mktemp "${dir}/.lso-modsec.XXXXXX") || return 1
    cat > "$tmp"
    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
    log_info "Wrote ${file#${LSO_FS_ROOT:-}}"
}

_ms_write_before_exclusions() {
    _ms_write_file "$(_ms_conf_dir)/wp_exclusions_before.conf" <<'EOF'
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Loaded BEFORE crs-setup.conf. Enables the official OWASP CRS 4.x WordPress
# rule-exclusion plugin, which pre-tunes CRS for WP core/admin/REST traffic.
SecAction "id:900130,phase:1,nolog,pass,t:none,setvar:tx.crs_exclusions_wordpress=1"
EOF
}

_ms_write_after_exclusions() {
    _ms_write_file "$(_ms_conf_dir)/wp_exclusions_after.conf" <<'EOF'
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# Loaded AFTER the CRS rules. Conservative, PRE-SEEDED WooCommerce/WordPress
# false-positive relief. DetectionOnly first — the operator reviews the audit log
# and approves further exclusions (analyze/report) before any enforce flip.
# WooCommerce Store API + wp-json + admin-ajax carry JSON/base64 payloads that trip
# libinjection SQLi/XSS and byte-range/charset rules. Scope the relief by path so it
# never weakens protection for the rest of the site.
SecRule REQUEST_URI "@rx (?:/wp-json/|/wp-admin/admin-ajax\.php|/\?wc-ajax=)" \
    "id:1000100,phase:1,pass,nolog,\
    ctl:ruleRemoveByTag=attack-sqli,\
    ctl:ruleRemoveByTag=attack-xss,\
    ctl:ruleRemoveById=920273,\
    ctl:ruleRemoveById=920420"
EOF
}

# The includes file that modsecurity_rules_file points at. <crs_present> ("1"/"0")
# controls whether the CRS Include lines are active (CRS present) or commented.
_ms_write_includes() {
    local crs_present="$1"
    local real conf_dir crs_dir crs_lines
    real="$(_ms_real_lsws)"
    conf_dir="${real}/conf/modsec"
    crs_dir="${real}/conf/owasp"

    if [ "$crs_present" = "1" ]; then
        crs_lines="Include ${crs_dir}/crs-setup.conf
Include ${crs_dir}/rules/*.conf"
    else
        crs_lines="# OWASP CRS not detected under ${crs_dir} — install it (ols-modsecurity /
# coreruleset .example templates), then re-run --modsec to wire these Includes:
#   Include ${crs_dir}/crs-setup.conf
#   Include ${crs_dir}/rules/*.conf"
    fi

    _ms_write_file "$(_ms_conf_dir)/modsec_includes.conf" <<EOF
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
# ModSecurity v3 core config. SecRuleEngine is DetectionOnly ONLY here — the
# enforce flip (SecRuleEngine On) is a separate, gated step (--modsec-enforce).
SecRuleEngine DetectionOnly
SecRequestBodyAccess On
SecResponseBodyAccess Off
# Audit: log only relevant (rule-matching) transactions, serial file, rotated.
SecAuditEngine RelevantOnly
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog ${real}/logs/modsec_audit.log
# WordPress/WooCommerce tuning around the CRS ruleset.
Include ${conf_dir}/wp_exclusions_before.conf
${crs_lines}
Include ${conf_dir}/wp_exclusions_after.conf
EOF
}

# logrotate drop-in for the audit log (disk exhaustion downs a store even in
# DetectionOnly). Path is /etc/logrotate.d, added to the backup drop-in loop.
_ms_write_logrotate() {
    local real
    real="$(_ms_real_lsws)"
    _ms_write_file "$(_lso_fs /etc/logrotate.d/lso-modsec)" <<EOF
# Managed by litespeed-optimizer — do not edit (regenerated on each run).
${real}/logs/modsec_audit.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

# True if the LIVE config's `module mod_security` block already enforces (an inline
# SecRuleEngine On, e.g. a hand-configured or migrated host). We only ever ship
# DetectionOnly, so we refuse rather than leave a surviving enforce in place.
_ms_block_enforces() {
    local conf="$1"
    [ -f "$conf" ] || return 1
    awk '/^[[:space:]]*module[[:space:]]+mod_security[[:space:]]*\{/,/^[[:space:]]*\}/' "$conf" 2>/dev/null \
        | grep -qiE 'SecRuleEngine[[:space:]]+On([[:space:]]|$|`)'
}

# True only if a USABLE CRS is present: crs-setup.conf AND at least one rules/*.conf.
# crs-setup alone (or an empty rules/) would make the rules Include a load error and
# fail module init on restart — even in DetectionOnly.
_ms_crs_usable() {
    local crs_dir rf
    crs_dir="$(_ms_crs_dir)"
    [ -f "${crs_dir}/crs-setup.conf" ] || return 1
    for rf in "${crs_dir}"/rules/*.conf; do
        [ -f "$rf" ] && return 0
    done
    return 1
}

# Live-only preflight: never runs in fixtures / dry-run. File-existence warnings for
# the operator (CRS presence). The module .so is a HARD pre-write gate in apply, not
# here; a real CRS parse check happens on the operator's next restart (error log).
_ms_preflight() {
    if [ -n "${LSO_FS_ROOT:-}" ] || [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would note CRS presence; the real CRS parse check is the operator's next restart"
        return 0
    fi
    if ! _ms_crs_usable; then
        log_warn "modsec: no usable OWASP CRS (crs-setup.conf + rules/*.conf) — DetectionOnly is active but"
        log_warn "  no CRS rules load yet. Install CRS 4.x, then re-run --modsec to wire the CRS Includes."
    fi
}

# Item 4: flip the DEPLOYED DetectionOnly config to enforcing (SecRuleEngine On).
# A distinct, deliberate step (--modsec-enforce). Refuses unless ModSecurity is
# already deployed by this tool in DetectionOnly. Rewrites ONLY the engine line in
# the owned includes file; the module block is untouched. Rides the existing
# verified restart-or-rollback chain, so a 403'd checkout / 5xx rolls back.
_ms_enforce_flip() {
    local conf inc real_inc v="" rf="" n_engine
    conf="${LSO_MAIN_CONF:-}"
    inc="$(_ms_conf_dir)/modsec_includes.conf"
    real_inc="$(_ms_real_lsws)/conf/modsec/modsec_includes.conf"

    # Prove this is a THIS-TOOL DetectionOnly deploy before flipping: module on, the
    # rules_file points at OUR includes, and the includes carries our managed marker.
    # (Never flip a hand-built / third-party / migrated ModSecurity config.)
    [ -n "$conf" ] && [ -f "$conf" ] && v=$(ols_get "$conf" "module mod_security" modsecurity 2>/dev/null)
    [ -n "$conf" ] && [ -f "$conf" ] && rf=$(ols_get "$conf" "module mod_security" modsecurity_rules_file 2>/dev/null)
    if [ "$v" != "on" ] || [ "$rf" != "$real_inc" ] || [ ! -f "$inc" ] \
        || ! grep -q "Managed by litespeed-optimizer" "$inc" 2>/dev/null; then
        log_error "modsec-enforce: no tool-managed DetectionOnly deploy found (need modsecurity on +"
        log_error "  modsecurity_rules_file -> our includes + the managed marker). Run --modsec first, review the"
        log_error "  audit log, apply any Woo/WP exclusions, then re-run --modsec-enforce."
        return 1
    fi

    # The engine mode must live ONLY in our includes file — refuse a mixed config with
    # an inline SecRuleEngine in the httpd_config module block.
    if _ms_block_enforces "$conf"; then
        log_error "modsec-enforce: the module block has an inline SecRuleEngine On — refusing (engine must live only"
        log_error "  in the includes file). Resolve the inline directive, re-run --modsec, then --modsec-enforce."
        return 1
    fi

    # Exactly ONE engine line, EOL-anchored (same shape the rewrite matches). Already On
    # -> idempotent no-op; a single clean DetectionOnly -> flip; anything else -> refuse
    # (a hand-edited / duplicated / commented-tail engine line could leave a mixed file).
    n_engine=$(grep -cE '^[[:space:]]*SecRuleEngine[[:space:]]+' "$inc" 2>/dev/null || true)
    if [ "$n_engine" != "1" ]; then
        log_error "modsec-enforce: expected exactly one SecRuleEngine line in the includes file (found ${n_engine}) — refusing."
        return 1
    fi
    if grep -qE '^SecRuleEngine[[:space:]]+On[[:space:]]*$' "$inc" 2>/dev/null; then
        log_info "modsec-enforce: already enforcing (SecRuleEngine On) — nothing to do."
        return 0
    fi
    if ! grep -qE '^SecRuleEngine[[:space:]]+DetectionOnly[[:space:]]*$' "$inc" 2>/dev/null; then
        log_error "modsec-enforce: the SecRuleEngine line is not a clean DetectionOnly — refusing (re-run --modsec)."
        return 1
    fi

    log_warn "modsec-enforce: flipping SecRuleEngine DetectionOnly -> On. Confirm FIRST:"
    log_warn "  - a DetectionOnly soak long enough to see real traffic;"
    log_warn "  - the audit log reviewed and Woo/WP false positives excluded + re-tested;"
    log_warn "  - the WooCommerce smoke gate passes (cart / checkout / Store API);"
    log_warn "  - a maintenance window + someone watching orders. Enforcing too early can 403 checkout."

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would flip SecRuleEngine to On in ${inc#${LSO_FS_ROOT:-}}"
        return 0
    fi

    # Write to a temp and VERIFY IT before swapping in — a bad rewrite never reaches disk.
    local dir tmp
    dir="$(dirname "$inc")"
    tmp=$(secure_mktemp "${dir}/.lso-modsec.XXXXXX") || return 1
    awk '{ if ($0 ~ /^SecRuleEngine[[:space:]]+DetectionOnly[[:space:]]*$/) print "SecRuleEngine On"; else print }' \
        "$inc" > "$tmp"
    if ! grep -qE '^SecRuleEngine On$' "$tmp" 2>/dev/null \
        || grep -qE '^[[:space:]]*SecRuleEngine[[:space:]]+DetectionOnly' "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        log_error "modsec-enforce: rewrite verification failed (staged temp) — no change made."
        return 1
    fi
    copy_file_permissions "$inc" "$tmp" 2>/dev/null || true
    mv "$tmp" "$inc"
    log_success "modsec-enforce: SecRuleEngine is now On (enforcing). Watch orders + 5xx; rollback restores DetectionOnly."
}

feature_apply_custom_modsec() {
    # Opt-in gate: never deploy ModSecurity config unless explicitly asked.
    if [ "${LSO_MODSEC:-}" != "1" ]; then
        log_info "modsec: not enabled — pass --modsec to deploy ModSecurity v3 in DetectionOnly (never enforces)"
        return 0
    fi

    # Item 4: the enforce flip is a DISTINCT, gated action. It runs BEFORE the
    # Enterprise / panel-restricted early returns so a requested enforce is never
    # silently reported as success — on those hosts the ownership check fails and
    # _ms_enforce_flip returns 1 with a clear error.
    if [ "${LSO_MODSEC_ENFORCE:-}" = "1" ]; then
        _ms_enforce_flip
        return $?
    fi

    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        log_warn "modsec: Enterprise uses the async 2.9-syntax engine (not libModSecurity v3) — manual-only here."
        log_info "  Enable ModSecurity + a v2.9 ruleset via WHM > LiteSpeed WebAdmin (XML is read-only for this tool)."
        return 0
    fi

    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        log_warn "modsec: ${LSO_PANEL} manages server config — the mod_security module block is manual-only."
        log_info "  Add via the panel/WebAdmin: module mod_security { ls_enabled 1; modsecurity on;"
        log_info "  modsecurity_rules_file <path>/conf/modsec/modsec_includes.conf } (DetectionOnly)."
        return 0
    fi

    local conf="${LSO_MAIN_CONF:-}"
    if [ -z "$conf" ] || [ ! -f "$conf" ]; then
        log_error "modsec: main config not found"
        return 1
    fi

    # SAFETY: refuse if the existing module block already enforces (inline
    # SecRuleEngine On). We only ship DetectionOnly and must not leave an enforce in
    # place. The operator removes the inline enforce first, then re-runs.
    if _ms_block_enforces "$conf"; then
        log_error "modsec: SAFETY — the existing 'module mod_security' block enforces (SecRuleEngine On)."
        log_error "  This tool only ships DetectionOnly. Remove the inline enforce from the config, then re-run --modsec."
        return 1
    fi

    # HARD live gate: never enable 'modsecurity on' without the module present — a
    # restart would fail. Live-only (fixtures set LSO_FS_ROOT and skip this).
    if [ -z "${LSO_FS_ROOT:-}" ] && [ "${DRY_RUN:-false}" != true ] \
        && [ ! -f "${LSO_LSWS_ROOT}/modules/mod_security.so" ]; then
        log_error "modsec: mod_security.so not found under the LSWS modules dir — refusing to enable 'modsecurity on'"
        log_error "  (a restart could fail). Install the OLS ModSecurity module (e.g. apt-get install ols-modsecurity),"
        log_error "  then re-run --modsec. Rollback restores config, NOT the package."
        return 1
    fi

    # CRS usable already? (install is a separate package step; detecting a present,
    # non-empty ruleset is filesystem-based and fixture-testable.)
    local crs_present=0
    _ms_crs_usable && crs_present=1

    _ms_write_before_exclusions || return 1
    _ms_write_after_exclusions || return 1
    _ms_write_includes "$crs_present" || return 1
    _ms_write_logrotate || return 1

    # Module block in httpd_config (transactional). DetectionOnly is in the includes
    # file, so we NEVER write SecRuleEngine On here.
    local real_inc
    real_inc="$(_ms_real_lsws)/conf/modsec/modsec_includes.conf"
    local block="module mod_security"
    lso_conf_set "$conf" "$block" ls_enabled 1
    lso_conf_set "$conf" "$block" modsecurity on
    lso_conf_set "$conf" "$block" modsecurity_rules_file "$real_inc"

    # Danger guard: the includes file must be DetectionOnly and must NOT enforce.
    if [ "${DRY_RUN:-false}" != true ]; then
        local inc
        inc="$(_ms_conf_dir)/modsec_includes.conf"
        if grep -qiE '^[[:space:]]*SecRuleEngine[[:space:]]+On' "$inc" 2>/dev/null; then
            log_error "modsec: SAFETY — includes file has 'SecRuleEngine On'; refusing (this feature is DetectionOnly)"
            return 1
        fi
        if ! grep -qE '^[[:space:]]*SecRuleEngine[[:space:]]+DetectionOnly' "$inc" 2>/dev/null; then
            log_error "modsec: includes file missing 'SecRuleEngine DetectionOnly' — aborting"
            return 1
        fi
    fi

    if [ "$crs_present" = "1" ]; then
        log_success "modsec: ModSecurity v3 staged in DetectionOnly with OWASP CRS + WP/Woo exclusions"
    else
        log_info "modsec: ModSecurity v3 staged in DetectionOnly (CRS not yet installed — see warnings)"
    fi
    log_info "modsec: review the audit log, then flip to enforce with the separate --modsec-enforce step"

    _ms_preflight
}

feature_detect_custom_modsec() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"
    [ -f "$config_file" ] || return 1
    local v
    v=$(ols_get "$config_file" "module mod_security" modsecurity 2>/dev/null) || return 1
    [ "$v" = "on" ] || return 1
    # Our OWNED includes managing the engine — DetectionOnly OR On (post-enforce).
    # Require the managed marker so a third-party ModSecurity at the same path isn't
    # mis-reported as this feature.
    local inc
    inc="$(_ms_conf_dir)/modsec_includes.conf"
    [ -f "$inc" ] && grep -q "Managed by litespeed-optimizer" "$inc" 2>/dev/null \
        && grep -qE '^[[:space:]]*SecRuleEngine[[:space:]]+(DetectionOnly|On)' "$inc" 2>/dev/null
}

FEATURE_ID="modsec"
FEATURE_DISPLAY="ModSecurity v3 + OWASP CRS (DetectionOnly)"
FEATURE_DETECT_PATTERN="module mod_security"
FEATURE_SCOPE="global"
FEATURE_ALIASES="modsecurity,waf"
feature_register
