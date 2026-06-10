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
