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

## [0.4.0] - 2026-06-10 (Phase 4 — security, analyze, benchmark, E2E)

### Added
- security feature: OLS perClientConnLimit throttling (dynReqPerSec 2, staticReqPerSec 40, soft/hard 15/20, ban 300, blockBadReq 1); Enterprise WordPressProtect drop,10 via Apache include; reCAPTCHA report-only guidance; ModSec detect+report (3.x-only note on OLS)
- analyze command: weighted 0-100 audit with FIX hints across server/php/opcache/cache/object-cache/security; untestable checks excluded from denominator; danger findings (enableCache 1, debug log on, items_in_cart cache-kill) cap score at 59; --json support
- benchmark command: curl x10 TTFB (dns/connect/tls breakdown), first-vs-median warm comparison, x-litespeed-cache hit verification, cart no-cache probe, JSON persistence with before/after delta
- Docker E2E (tests/test-with-ols-docker.sh, skips cleanly without Docker): VERIFIED against live litespeedtech/openlitespeed — detect, check, dry-run, real optimize with restart+health check, HTTP 200 after, live invariant intact (7/7)
- LSCWP key validation against plugin 7.8.1 source from wordpress.org: caught and FIXED 3 wrong keys (cache-stale->purge-stale, guest-optm->guest_optm, crawler-role_sims->crawler-roles); key list vendored at tests/fixtures/, profile lint added to suite

### Changed
- Version 0.4.0; security feature added to all optimize profiles; golden files regenerated

## [0.5.0] - 2026-06-10 (v0.2 features — no-SSH workflows)

### Added
- `analyze --remote <url>`: HTTP-only scored audit with zero server access — LiteSpeed detection, repeat-request cache hit, TTL/age, TTFB median, HTTP/3 (alt-svc), Brotli/gzip, security headers, plus WooCommerce probes (product cacheability, cart/checkout/wc-ajax must not be cache-served, two-session cart isolation via Store API, vary-poisoning signature: no-cache + hit on one response). GET-only, anonymous, rate-limited (1s default), hard request cap (25), identifying User-Agent. Run ONLY on sites you own or manage. FIX hints phrased for no-SSH contexts; --json supported
- `export-profile --profile <name> [--out file]`: generates LSCWP-native .data import files (v4+ format verified against plugin 7.8.1 import.cls.php) for wp-admin > Toolbox > Import — no SSH needed. Companion README with import steps, verification checklist, and what the profile intentionally leaves off. Object-cache keys excluded by default (opt-in via LSO_EXPORT_REDIS_HOST) so an existing Redis setup is never silently disabled. E2E-verified: generated file imports through the REAL plugin and applies
- E2E additions: live-store remote audit + .data import round-trip

### Changed
- woocommerce profile: cache-rest = 0 — with REST caching on, the Woo Store API cart endpoint can serve cached (stale/foreign) cart JSON to cookieless visitors; reproduced empirically in the E2E. Remote analyzer flags cart-API cache hits as DANGER
- Version 0.5.0

## [Unreleased] - pilot harness

### Added
- tests/pilot-restore.sh: restore an arbitrary WordPress export (files+DB) into a local OLS+MariaDB+Redis stack, URL search-replace to a .loc domain, wp-cli admin access. Client data stays local (gitignored)
- tests/pilot-report.sh: drive analyze(before)/optimize/analyze(after)/benchmark/cart-isolation against the restore + generate the no-SSH export-profile artifact; writes docs/PILOT-REPORT.md (gitignored)
- .gitignore: exclude staging exports, DB dumps, pilot reports, and generated .data artifacts (client-data safety)

### Fixed
- analyze --remote: cart-page check now requires HTTP 200 before flagging a cache hit (a CACHED 404 on /cart/ for localized shops like Polish /koszyk/ was a false-positive DANGER) and follows the homepage cart link to the localized slug; cart Store API cacheability check made independent of product discovery so it runs deterministically. Validated against the real production shop mltools.pl (cart-API cache-rest finding reproduced; localized cart correctly clears)

### Added (pilot prep, cont.)
- Basic Auth for remote/benchmark requests: --basic-auth <user:pass> flag + LSO_HTTP_AUTH env (for staging behind a Basic Auth gate); applied to analyze --remote and benchmark curl calls
- analyze: runtime OPcache-pressure findings via wp-cli (opcache_get_status) — flags near-full pool, hit-rate <95%, and exhausted interned-strings buffer, each with a sizing FIX hint; LSO_OPCACHE_MB override to raise opcache.memory_consumption beyond the tier default when telemetry shows exhaustion
- pilot-restore.sh: pins lsphp to the live-confirmed PHP version (default 8.3, LSO_PILOT_PHP override) and repoints the extprocessor at it
- pilot-report.sh: plugin cache-safety/exclusions section; sets LSO_OPCACHE_MB=512 in staging to measure hit-rate headroom vs the live 128MB

### Fixed (pilot hardening — real mltools.pl staging restore)
- analyze: runtime OPcache block no longer aborts the whole audit under set -e when opcache_get_status returns null memory stats (the real CLI case: opcache.enable_cli=0). Non-numeric values are dropped before arithmetic; when stats are unreadable via CLI, analyze says so honestly and continues to the score. (Caught on the live restore — analyze was stopping before cache/security/score.)
- pilot-restore.sh: NUL-safe DB-dump discovery (pipefail/SIGPIPE), MariaDB import with --max-allowed-packet=512M + non-strict sql-mode (matches prod; large serialized rows + STRICT mode were failing import), innodb-buffer-pool-size=256M (512M OOM-killed the DB container on a shared Docker VM), and .htaccess strip now also disables the prod force-HTTPS redirect (was 301-looping local http).
- pilot-report.sh: probes via curl --resolve with the port in the Host header (WP canonical-redirects in a loop when Host omits the port that home_url carries); TTFB measured directly via --resolve.

### Fixed (opcache deployment — pilot gap caught by main)
- opcache feature: resolve the PHP ini scan dir from `php --ini` ("Scan for additional .ini files in:") instead of assuming conf.d/. OLS lsphp uses .../etc/php/<v>/mods-available/; cPanel ea-php uses php.d/ — the old code silently failed to deploy the drop-in. Fallbacks now try conf.d/php.d/mods-available.
- opcache feature: detect whether the Zend opcache extension is actually loaded (`php -m`). If opcache.so exists in extension_dir but isn't loaded, the drop-in now adds `zend_extension=opcache.so`; if the .so is absent, tune-but-warn (directives are inert without the extension — found on lsphp83 which shipped without it). Template gained an @ZEND_EXTENSION_LINE@ slot.
- pilot-restore.sh: install lsphp<v>-opcache so staging actually has the extension.
- Verified live on the mltools.pl staging: opcache now loaded, memory_consumption=512 (vs prod 128), analyze reports "drop-in deployed / memory >= tier".
