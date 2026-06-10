# Changelog

## [0.1.0] - 2026-06-10 (Phase 1)

### Added
- CLI skeleton: detect / check / analyze / optimize / rollback / status / benchmark with --dry-run, --json, --profile, --feature/--exclude, --no-color
- Environment detection: OLS vs LSWS Enterprise, panel (CyberPanel/cPanel/DirectAdmin/RunCloud/plain), config paths, PHP resolution, WP site discovery, firewall/Redis/MariaDB presence
- RAM-aware sizing: tier lookups (1g/2g/4g/8g) + lso_children formula
- OLS confedit primitives: ols_get/ols_set/ols_ensure_include/ols_lint (awk-based, CRLF-safe)
- Timestamped backup with manifest + verified rollback (restore, checksum verify, graceful restart, HTTP health check, auto-restore on failure)
- Transaction primitives for multi-file atomic edits with interrupt safety
- Test suite: shellcheck gate, bash 3.2 + portability checks, 5 fixture environments, confedit unit tests, backup/rollback round-trip

## [0.2.0-dev] - 2026-06-10 (Phase 2 — server tuning)

### Added
- Feature modules: server-tuning (tuning{} per RAM tier), lsapi-tuning (maxConns==PHP_LSAPI_CHILDREN invariant, LSAPI env incl. AVOID_FORK 0/200M/500M/1, PGRP_MAX_IDLE >=2GB only), opcache (drop-in ini via template, lsphp restart trigger), lscache (server-level safety block: enableCache 0, ignoreRespCacheCtrl 0, danger guard)
- optimizer.sh workflow: profile resolution (auto/generic/wordpress/woocommerce), --feature/--exclude, DirectAdmin/RunCloud manual-steps policy
- confedit: "name arg" block addressing (module cache, extprocessor lsphp), ols_get_env/ols_set_env for repeated env lines, dry-run-aware lso_conf_set wrappers
- Enterprise paths: tuning report-only (XML never touched), LSPHP_Workers via marker-delimited Apache include block
- Golden-file tests for 4 RAM tiers with explicit invariant + enableCache-0 + lint assertions; dry-run no-mutation, Enterprise XML-untouched, and idempotency tests (118 tests total)

## [0.3.0-dev] - 2026-06-10 (Phase 3 — WordPress/WooCommerce)

### Added
- lscwp feature: wp-cli wrapper (LSO_WP_BIN override), plugin install/activate when missing, CVE version gate >=6.5.1 (CVE-2024-28000/44000/47374) with auto-update, pre-change litespeed-option export backup, curated profile applied per-key via litespeed-option set, debug off, *.log access blocked via mod_rewrite (the only .htaccess mechanism OLS honors), purge all
- Curated profiles (templates/lscwp/): woocommerce / wordpress / generic — TTL pub 604800 / priv 1800, serve stale ON, guest optimization OFF, minify on (woo+wp) with combine/UCSS/JS-defer OFF, object cache placeholders
- Redis object-cache wiring: enabled only when Redis detected, lifetime 600, persistent, unix-socket preference
- woocommerce feature: ESI (+admin-bar/comment-form) on Enterprise ONLY, warn+QUIC.cloud/vary-fallback path on OLS; crawler enable with load limit 1.0 and role simulation OFF; cache-vary sanity checks (woocommerce_items_in_cart must NOT be in do-not-cache cookies; multi-currency vary-cookie warning)
- Profiles wired into optimizer: wordpress adds lscwp; woocommerce adds lscwp+woocommerce; auto detects active Woo via wp-cli
- Tests: mock wp-cli (call log + env-driven responses), 35 new assertions incl. golden profile payloads, ESI OLS-vs-Enterprise, CVE gate, dry-run makes zero mutating wp calls (153 total)

### Known limitations
- LSCWP option KEY NAMES follow 6.x naming but are UNTESTED against a live plugin (mock-only) — Docker E2E pending (Phase 3.5)
