#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/recaptcha.sh - OLS lsrecaptcha (CAPTCHA Protection), STAGED DISABLED
#                         (LIVE-phase Item 3)
################################################################################
# OPT-IN (--recaptcha), default-off. reCAPTCHA has no "monitor" mode, so the
# staged deploy writes the server-level `lsrecaptcha { }` block with `enabled 0`
# (the analog of ModSecurity DetectionOnly) and NEVER arms it. Arming is a
# separate, gated step (--recaptcha-enable) that flips `enabled 1` and writes the
# site/secret keys — and REFUSES unless BOTH keys are supplied via env
# (LSO_RECAPTCHA_SITE_KEY / LSO_RECAPTCHA_SECRET_KEY). Offline (no keys) the arm
# path always refuses; that refusal is the fixture-testable path.
#
# The block lives in the server-level main conf (LSO_MAIN_CONF) — the same target
# modsec uses — via transactional lso_conf_set, so backup + restart-or-rollback
# already cover it. NEVER on Enterprise (httpd_config.xml is read-only for this
# tool) or panel-restricted hosts: those are manual-only.
#
# Directive names + the `type` enum (1=Checkbox/reCAPTCHA v2, 2=Invisible,
# 3=hCaptcha) verified against a live OpenLiteSpeed 1.9.0 WebAdmin schema
# (admin/html.open/lib/.../DTblDefBase.php + Ows/DTblDef.php). Conservative
# connection thresholds (OLS defaults 15000/10000) keep the CAPTCHA wall from
# appearing in front of checkout during a traffic spike; the botWhiteList (a
# per-line regex; one alternation line matches all) always allows search crawlers
# + payment webhooks so product feeds and Stripe/PayPal/Mollie callbacks never hit
# a CAPTCHA. Top risk if armed too early: a CAPTCHA wall on checkout — hence
# staged-disabled first and keys-required-to-arm.
################################################################################

# The server-level CAPTCHA block token in httpd_config.conf.
_rc_block() { printf '%s' "lsrecaptcha"; }

# Search-engine crawlers + payment-webhook user agents that must never be CAPTCHA'd.
# A single alternation regex is a valid one-entry Bot White List (OLS allows regex
# per line) and maps cleanly onto lso_conf_set's single-value write. The payment
# markers (Stripe/PayPal/Mollie) also serve as this tool's ownership fingerprint —
# see _rc_is_managed.
_rc_bot_whitelist() {
    printf '%s' 'Googlebot|Bingbot|DuckDuckBot|Slurp|Baiduspider|YandexBot|Applebot|Stripe|PayPal|Mollie'
}

# Ownership proof: our staged block always carries the distinctive payment-webhook
# whitelist. A hand-rolled / panel-created / third-party lsrecaptcha block won't, so
# we never ARM or CLAIM (detect) a config this tool didn't stage — the analog of
# modsec's "Managed by litespeed-optimizer" includes marker (OLS block syntax has no
# comments, so the whitelist signature is our marker).
_rc_is_managed() {
    local conf="$1" wl
    [ -n "$conf" ] && [ -f "$conf" ] || return 1
    wl=$(ols_get "$conf" "$(_rc_block)" botWhiteList 2>/dev/null) || return 1
    case "$wl" in
        *Stripe*PayPal*Mollie*) return 0 ;;
        *) return 1 ;;
    esac
}

# Arm the DEPLOYED staged block (enabled 0 -> enabled 1 + keys). A distinct,
# deliberate step (--recaptcha-enable). Refuses unless a staged block exists AND
# both keys are present in the environment. Rides the existing verified
# restart-or-rollback chain, so a CAPTCHA-walled checkout / 5xx rolls back.
_rc_enable_flip() {
    local conf staged site secret cur_site en_verify sk_verify
    conf="${LSO_MAIN_CONF:-}"

    # Manual-only hosts: arming must REFUSE loudly (never silently succeed, and never
    # touch Enterprise httpd_config.xml / a panel-managed config).
    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        log_error "recaptcha-enable: Enterprise config is manual-only (httpd_config.xml is read-only for this tool)."
        log_error "  Arm CAPTCHA via WHM > LiteSpeed WebAdmin > Security once your keys + limits are set."
        return 1
    fi
    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        log_error "recaptcha-enable: ${LSO_PANEL} manages server config — arm the lsrecaptcha block via the panel/WebAdmin, not this tool."
        return 1
    fi

    # Trim whitespace-only keys (Bash 3.2-compatible) so "   " can't pass as a key.
    site="${LSO_RECAPTCHA_SITE_KEY:-}"
    secret="${LSO_RECAPTCHA_SECRET_KEY:-}"
    site="${site#"${site%%[![:space:]]*}"}"; site="${site%"${site##*[![:space:]]}"}"
    secret="${secret#"${secret%%[![:space:]]*}"}"; secret="${secret%"${secret##*[![:space:]]}"}"

    # Prove a TOOL-STAGED block exists (our whitelist fingerprint) before arming —
    # never arm a hand-rolled / third-party / panel-created lsrecaptcha block.
    if ! _rc_is_managed "$conf"; then
        log_error "recaptcha-enable: no tool-staged lsrecaptcha block found. Run --recaptcha first (writes it"
        log_error "  disabled), review the connection limits against peak traffic, then re-run --recaptcha-enable."
        return 1
    fi

    # Keys are mandatory to arm and NEVER hardcoded — the operator supplies their
    # Google reCAPTCHA v2 (Checkbox) Site + Secret keys via env (task #266).
    if [ -z "$site" ] || [ -z "$secret" ]; then
        log_error "recaptcha-enable: both keys required. Export your Google reCAPTCHA v2 keys, e.g.:"
        log_error "  LSO_RECAPTCHA_SITE_KEY=... LSO_RECAPTCHA_SECRET_KEY=... litespeed-optimizer optimize --recaptcha-enable"
        log_error "  (keys come from https://www.google.com/recaptcha/admin — reCAPTCHA v2 'I'm not a robot' Checkbox)."
        return 1
    fi

    # Idempotent: already armed with a key set -> no-op.
    staged=$(ols_get "$conf" "$(_rc_block)" enabled 2>/dev/null || true)
    cur_site=$(ols_get "$conf" "$(_rc_block)" siteKey 2>/dev/null || true)
    if [ "$staged" = "1" ] && [ -n "$cur_site" ]; then
        log_info "recaptcha-enable: already armed (enabled 1 + siteKey set) — nothing to do."
        return 0
    fi

    log_warn "recaptcha-enable: arming CAPTCHA protection (enabled 0 -> 1). Confirm FIRST:"
    log_warn "  - the connection limits (regConnLimit/sslConnLimit) reviewed against your peak (access-log p95);"
    log_warn "  - the Bot White List covers your crawlers + payment webhooks (Stripe/PayPal/Mollie);"
    log_warn "  - a maintenance window + someone watching checkout. Too-low limits can CAPTCHA-wall a sale."

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would set lsrecaptcha enabled 1 + write siteKey/secretKey in ${conf#${LSO_FS_ROOT:-}}"
        return 0
    fi

    # Write keys via the raw confedit primitive (still transaction-routed) so the
    # SECRET NEVER hits the logs — lso_conf_set would echo "Set …secretKey = <value>".
    ols_set "$conf" "$(_rc_block)" siteKey "$site" || { log_error "recaptcha-enable: failed to write siteKey"; return 1; }
    log_info "Set $(_rc_block).siteKey = (redacted)"
    ols_set "$conf" "$(_rc_block)" secretKey "$secret" || { log_error "recaptcha-enable: failed to write secretKey"; return 1; }
    log_info "Set $(_rc_block).secretKey = (redacted)"
    lso_conf_set "$conf" "$(_rc_block)" enabled 1 || return 1

    # Post-write verification (reads the staged temp under an active transaction).
    # Refuse on a partial write rather than report a false success — never log the secret.
    en_verify=$(ols_get "$conf" "$(_rc_block)" enabled 2>/dev/null || true)
    sk_verify=$(ols_get "$conf" "$(_rc_block)" siteKey 2>/dev/null || true)
    if [ "$en_verify" != "1" ] || [ -z "$sk_verify" ]; then
        log_error "recaptcha-enable: post-write verification failed (enabled='${en_verify}', siteKey present=$([ -n "$sk_verify" ] && echo yes || echo no)) — no arm."
        return 1
    fi
    log_success "recaptcha-enable: CAPTCHA protection is now ARMED (enabled 1). Watch checkout + 5xx; rollback restores enabled 0."
}

feature_apply_custom_recaptcha() {
    # Opt-in gate: never write the lsrecaptcha block unless explicitly asked.
    if [ "${LSO_RECAPTCHA:-}" != "1" ]; then
        log_info "recaptcha: not enabled — pass --recaptcha to stage OLS CAPTCHA protection DISABLED (never arms)"
        return 0
    fi

    # The arm flip is a DISTINCT, gated action. It runs BEFORE the Enterprise /
    # panel early returns so a requested arm is never silently reported as success
    # — on those hosts no staged block exists, so _rc_enable_flip refuses loudly.
    if [ "${LSO_RECAPTCHA_ENABLE:-}" = "1" ]; then
        _rc_enable_flip
        return $?
    fi

    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        log_warn "recaptcha: Enterprise manages server config in httpd_config.xml (read-only for this tool) — manual-only here."
        log_info "  Enable via WHM > LiteSpeed WebAdmin > Security > CAPTCHA (lsrecaptcha): keep it disabled until keys + limits are set."
        return 0
    fi

    if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
        log_warn "recaptcha: ${LSO_PANEL} manages server config — the lsrecaptcha block is manual-only."
        log_info "  Add via the panel/WebAdmin: Security > CAPTCHA (lsrecaptcha), enabled OFF, Bot White List for crawlers + payment webhooks."
        return 0
    fi

    local conf="${LSO_MAIN_CONF:-}"
    if [ -z "$conf" ] || [ ! -f "$conf" ]; then
        log_error "recaptcha: main config not found"
        return 1
    fi

    # Note a prior armed state so re-staging clearly reports it disarmed CAPTCHA.
    local prior_enabled=""
    prior_enabled=$(ols_get "$conf" "$(_rc_block)" enabled 2>/dev/null || true)

    # Staged write: DISABLED, reCAPTCHA v2 Checkbox, conservative limits, crawler +
    # payment-webhook whitelist. Keys are NOT written here (staged-disabled needs
    # none; --recaptcha-enable writes them). enabled is written LAST so a mid-write
    # failure never leaves an armed-but-keyless block.
    lso_conf_set "$conf" "$(_rc_block)" type 1 || return 1
    lso_conf_set "$conf" "$(_rc_block)" maxTries 3 || return 1
    lso_conf_set "$conf" "$(_rc_block)" allowedRobotHits 3 || return 1
    lso_conf_set "$conf" "$(_rc_block)" regConnLimit 15000 || return 1
    lso_conf_set "$conf" "$(_rc_block)" sslConnLimit 10000 || return 1
    lso_conf_set "$conf" "$(_rc_block)" botWhiteList "$(_rc_bot_whitelist)" || return 1
    lso_conf_set "$conf" "$(_rc_block)" enabled 0 || return 1

    # Danger guard: the staged block must be DISABLED (live-only). This is the true
    # safety invariant — 'enabled 0' means inactive regardless of any leftover keys,
    # so re-running --recaptcha after an arm cleanly reverts to disabled.
    if [ "${DRY_RUN:-false}" != true ]; then
        local en
        en=$(ols_get "$conf" "$(_rc_block)" enabled 2>/dev/null || true)
        if [ "$en" != "0" ]; then
            log_error "recaptcha: SAFETY — staged block is not 'enabled 0' (found '${en}'); refusing (this stage never arms)"
            return 1
        fi
    fi

    log_success "recaptcha: OLS CAPTCHA protection staged DISABLED (reCAPTCHA v2 Checkbox, crawler + payment whitelist)"
    if [ "$prior_enabled" = "1" ]; then
        log_warn "recaptcha: re-staging DISARMED a previously armed block (enabled 1 -> 0). Any keys remain in the config until you remove them."
    fi
    log_info "recaptcha: review the connection limits, then arm with the separate --recaptcha-enable step"
    log_info "recaptcha: arming needs your Google reCAPTCHA v2 keys via LSO_RECAPTCHA_SITE_KEY / LSO_RECAPTCHA_SECRET_KEY (task #266)"
}

feature_detect_custom_recaptcha() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"
    [ -f "$config_file" ] || return 1
    # Detected iff a THIS-TOOL-staged block is present (our whitelist fingerprint) —
    # a third-party lsrecaptcha block must not be mis-credited to this feature. The
    # fingerprint survives an arm (arming leaves type/limits/whitelist untouched).
    _rc_is_managed "$config_file"
}

FEATURE_ID="recaptcha"
FEATURE_DISPLAY="OLS CAPTCHA protection (lsrecaptcha, staged disabled)"
FEATURE_DETECT_PATTERN="lsrecaptcha"
FEATURE_SCOPE="global"
FEATURE_ALIASES="captcha"
feature_register
