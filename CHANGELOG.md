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
