# Changelog

## [Unreleased]

### Fixed
- **`dynReqPerSec` 2 → 30 — the throttling default was banning real visitors.** Every OLS install got `perClientConnLimit { dynReqPerSec 2 }` regardless of RAM tier, but one logged-in WordPress pageview fires `admin-ajax` + REST + `wp-cron` and exceeds 2 dynamic req/s unaided, so ordinary users (and every NAT'd office) were banned for `banPeriod` 300s. Worse, OLS re-arms the ban on each rejected request, so anyone who hit reload extended their own ban — observed live on `litespeed-demo` as a climbing `overlimit: 214s → 229s → … → 290s` with `cur conns: 1`, surfacing publicly as Cloudflare 520s. The `--trusted-ip` escape hatch the header comment promised for "v0.2" never shipped, leaving no workaround. New default is 30, overridable via `LSO_DYN_REQ_PER_SEC`.
- **`feature_detect_custom_security` accepted only `dynReqPerSec` 1–5**, so a correctly throttled server was reported as unconfigured (and re-"fixed" on every run) once the default moved above 5. Now any positive cap counts as applied.

### Tests
- Golden fixtures (`plain-ols-1g/2g/4g/8g`) and the throttling-block assertion updated to 30. Suite green at **469 pass / 0 fail**; `shellcheck --severity=error` clean.

## [0.8.0] - 2026-06-30 (offline roadmap cleared — multi-site, bad-bot blocker, load testing, atomic optimize)

Five PRs (#24–#30) clearing every offline-implementable roadmap item, each independently grok-reviewed. Live-server work (ModSecurity/CRS, fail2ban, reCAPTCHA/QUIC.cloud) stays deferred.

### Added
- **Bad-bot / scraper UA blocker** (`--badbots` / `LSO_BADBOTS=1`, PR #28) — opt-in per-site `.htaccess` UA denylist via `mod_setenvif` with dual 2.4 (`mod_authz_core`) / 2.2 (`Order/Deny`) syntax, module-guarded so it no-ops rather than 500s. Conservative list that excludes every major search engine. Scored in `analyze` (marker + `lso_bad_bot` rule) and probed remotely (one benign scraper-UA request → 403/406/429/444 = blocked, informational, no over-attribution).
- **Concurrent load benchmarking** (`benchmark --load`, PR #29) — prefers `wrk` > `k6` > `ab`, falls back to a portable backgrounded parallel-curl generator so it always works. `--concurrency N` / `--duration N`; `LSO_LOAD_TOOL/_CONCURRENCY/_DURATION`. JSON persisted with concurrency fields; HTTP auth forces the curl path (only it plumbs `--config`). Offline measures the harness, not production capacity.

### Changed / Fixed
- **Atomic all-or-nothing optimize** (PR #30) — the transaction engine is finally wired into `apply_optimizations`: server-config edits stage to per-file temps and commit together; the EXIT/INT/TERM-trap rollback is now live (was dead code). Rollback is scoped to config-write failures (a non-config feature failure no longer discards earlier valid server config) and catches *swallowed* write failures via a write-error counter (a feature can't return success after a failed `ols_set` and commit partial config). `ols_get`/`ols_get_env` read-your-writes keeps feature self-verification guards (e.g. lscache's `enableCache=0`) working against staged values.
- **Multi-site `TARGET_SITE` resolution** (PR #27) — shared `_resolve_target_docroot` (exact-path / URL-host / parent-dir / unique-basename, all anchored or unique); replaced the loose substring vhost match in the lscwp/woocommerce apply loops that could target a `*-staging` sibling, and the hardcoded first-site in analyze/detect.
- **JSON escaping** (`json_escape`, PR #24) — every JSON string field is escaped, so a quote/backslash/newline in a path or header no longer produces invalid JSON.
- **HTTP basic-auth off the argv** (PR #25) — passed via a mode-600 curl `--config` file instead of `--user` (was visible in `ps`).

### Tests
- 259 → **315** (+56). New coverage: resolver ladder (exact/slug/URL/parent, ambiguous → fail); bad-bot apply (opt-out default, dual authz, no search-engine false positives, idempotent) + scored audit; load fallback + mock-`wrk` JSON validity + graceful degrade; transaction read-your-writes, all-or-nothing config-failure vs non-config-failure vs swallowed-write rollback, multi-feature commit, no-temps. `shellcheck --severity=error` clean (0 warnings) throughout; bash 3.2 compatible.

## [0.7.5] - 2026-06-18 (graceful lsphp recycle — prevent torn object-cache writes)

### Fixed
- **lsphp recycle is now graceful (SIGTERM → grace → SIGKILL stragglers), not a blanket `kill -9`.** The #112 recycle hard-killed every worker immediately. Caught live on lsdemo: a `-9` landing between WordPress committing an option to the DB and the object-cache (Redis) write of the updated `alloptions` blob completing left the two diverged — the DB had the correct active theme but Redis served the OLD one, so the site rendered the wrong (default) theme until the object cache was flushed. The recycle now sends SIGTERM so each worker finishes its current request (and any in-flight cache write) before exiting, waits `LSO_RECYCLE_GRACE` seconds (default 2), then SIGKILLs only workers still alive — so a busy/stuck worker is still guaranteed to recycle, but a normal request is never torn mid-write. LSWS respawns workers on demand either way.

### Tests
- +1 (259 total): the recycle unit test now asserts SIGTERM reaches every worker first and SIGKILL escalates ONLY to stragglers that ignored TERM (a worker that exits on TERM must not be -9'd).

## [0.7.4] - 2026-06-18 (probe correctness on multi-vhost + warming caches — live lsdemo)

Two bugs found running `probe-opcache` against the live lsdemo box right after the #112 recycle.

### Fixed
- **`probe-opcache` / `probe-redis` resolve the docroot from the requested URL.** On a multi-vhost box the probe dropped its token file in `LSO_WP_SITES[0]` (the first detected WP site) regardless of the URL, so the HTTP fetch 404'd whenever that wasn't the vhost serving the URL. `_probe_docroot` now prefers the WP site whose own `home` host matches the requested URL host (falls back to the first site when no URL is given; `LSO_PROBE_DOCROOT` still wins). Verified live: `probe-opcache https://litespeed-demo.marcindudek.dev` went from 404 to a correct read.
- **Low OPcache hit-rate no longer false-flags a mostly-free pool as "undersized".** The soft hit-rate trigger fired on `scripts>=200 && hit_rate<90` with no memory-pressure check, so a freshly-recycled / low-traffic pool (the exact optimize→probe workflow) reported "undersized — raise memory_consumption" against a pool that was 79% **free**. It now requires real eviction pressure: hit-rate `< 90` **and** `>= 50` (below 50 misses still dominate = warming) **and** the pool actually under pressure (`free < 30%` or OOM). The remediation for a genuine hit-rate trigger now recommends memory only (the misses are evictions), not a `max_accelerated_files` value that could sit below the current setting. The same memory-pressure gate is applied to the `analyze` opcache hit-rate check for consistency.

### Tests
- +6 (258 total): multi-vhost docroot selection (URL-host match / no-URL fallback / explicit override); probe healthy on a free pool with low hit-rate; probe healthy post-recycle (hit<50%); probe still undersized when low hit-rate coincides with memory pressure; analyze healthy on a free pool with low hit-rate.

## [0.7.3] - 2026-06-18 (lsphp recycle after php.ini/OPcache changes — lsdemo #112)

### Fixed
- **lsphp workers are now force-recycled after an OPcache/php.ini change.** Confirmed live on lsdemo: a graceful LiteSpeed restart (`lswsctrl restart` → SIGUSR1) does **NOT** recycle existing `lsphp` child processes — they keep serving the OLD php.ini/OPcache config (e.g. the default 128MB pool) for hundreds of seconds, so the just-deployed drop-in was a silent no-op in the **web SAPI**. The OPcache feature now calls a new `lso_recycle_lsphp` helper that kills the workers by PID (LSWS respawns them on demand, loading the new drop-in). Honors `DRY_RUN` (`[DRY RUN] Would recycle lsphp …`) and `LSO_SKIP_RESTART`/`LSO_FS_ROOT` (fixture/test mode). Gotcha baked in: workers are matched on `comm` (cmdline is just `lsphp`), **not** `pkill -f /lsphpNN/bin/lsphp`, which silently matches nothing.

### Tests
- +5 (252 total): dry-run prints the would-recycle line; a fixture run skips the recycle (never signals a real process); and a unit test of `lso_recycle_lsphp` (PID seam + shadowed `kill`) asserts every worker PID is signalled and the count is reported.

## [0.7.2] - 2026-06-17 (live E2E fixes — lsdemo)

Two bugs found running the probes against the real OpenLiteSpeed + WordPress stack on lsdemo (both probes otherwise worked first try and found genuine issues: no redis ext in the lsphp83 web SAPI, and an actually-undersized OPcache — pool 0% free, hit-rate 60% on a 3847-script cache).

### Fixed
- **`probe-redis` / `probe-opcache` now run environment detection first.** They previously didn't, so `LSO_PHP_INI` was empty and `probe-opcache` *always* took the "contact host" remediation branch — even when run on-box as root with a writable lsphp php.ini (the primary use case). Now they detect quietly + non-fatally (`LSO_PROBE_*` overrides still win), so the self-fixable branch prints the actual sizing snippet, and the docroot/URL auto-resolve without explicit env vars.
- **lsphp package hint stripped the patch version wrong.** On a real box `LSO_PHP_VER` is the full `8.3.31`, so the `analyze` redis-ext FIX said `apt install lsphp8331-redis` instead of `lsphp83-redis`. Now uses major.minor only (matches `probe-redis`, which was already correct). Regression test uses a 3-part version.



### Fixed
- **Warmth gate raised 50 → 200 `num_cached_scripts`** for the soft hit-rate trigger. A real WordPress caches hundreds of scripts within the first few page loads, so a just-restarted WP serving ~60 scripts at hit-rate 80% would false-flag as "undersized" while merely warming. The hard triggers (oom / pool / key-table / interned) remain ungated — they're true regardless of warmth.

### Changed
- **Trigger-specific remediation**: the fix now names the directive that actually fired — key-table → `opcache.max_accelerated_files`, pool-full → `opcache.memory_consumption`, interned → `opcache.interned_strings_buffer` — instead of a generic "increase opcache".
- **Fragmentation sub-branch**: low free **but** high `wasted_memory` (>20% of pool) means the pool is churned by recompiles, not genuinely too small — a bigger pool won't fix a thrashing one. It now recommends `opcache_reset()` + `opcache.validate_timestamps=0` FIRST. On non-writable (shared) hosting it notes `validate_timestamps` is `PHP_INI_ALL` and often settable via `.user.ini` even when `memory_consumption` is locked — a partial self-fix.
- `--json` adds `wasted_pct`, `num_cached_scripts`, `fragmented`.

### Tests
- +3 (246 total): warming-WP-not-flagged, trigger-specific knob naming, fragmentation branch.

### Credit
- All three refinements from the agrido project's PR review.

## [0.7.0] - 2026-06-17 (web-SAPI OPcache probe)

### Added
- `probe-opcache` command: reads **runtime** OPcache stats from the actual web SAPI (the only honest source — CLI has `opcache.enable_cli=0`) via the same token-guarded one-shot probe as `probe-redis`. Verdict on agrido's field thresholds — undersized if ANY of: `oom_restarts>0` · pool `<10%` free · key-table `>=95%` of max · interned buffer `<5%` free · hit-rate `<90%` **on a warm cache**. Hit-rate is the only soft trigger and is gated on cache warmth (`num_cached_scripts`), because it's cumulative-since-restart and reads low on a cold cache (normal, not a problem). Remediation is **host-aware** (detect-AND-fix split): if the serving lsphp's php.ini is writable it prints a sizing snippet (memory_consumption ~2×, max_accelerated_files next-pow2 above cached scripts, interned bump, prod `validate_timestamps=0`); otherwise — `opcache.*` is `PHP_INI_SYSTEM` and usually not raisable per-account on shared/managed hosting — it says "contact your host" rather than emit an unappliable snippet. `--json`, `--basic-auth`.
- Probe template now also reports `opcache_get_status(false)` fields (mem/hit-rate/keys/interned/oom).

### Changed
- Refactored the drop→fetch→self-delete probe flow into a shared `_probe_fetch_json` harness used by both `probe-redis` and `probe-opcache` (one hardened path, two consumers).

### Tests
- +8 (243 total): every opcache trigger (healthy / oom / pool<10% / key-table / interned / cold-vs-warm hit-rate / disabled), the host-aware contact-host branch, and `--json` shape — all via canned-JSON responders, deterministic and provider-independent.

### Credit
- OPcache verdict thresholds + warmth-gating + the host-aware split contributed by the agrido project.

## [0.6.0] - 2026-06-17 (web-SAPI redis-extension probe)

### Added
- `probe-redis` command: token-guarded one-shot web-SAPI probe. Renders a random-named PHP file with a per-run `hash_equals` token, drops it in the **docroot** (not wp-content — LiteSpeed `.htaccess` Denies PHP there), fetches it over HTTP with a cache-buster while the PHP emits `X-LiteSpeed-Cache-Control: no-cache` (so LSCache can't serve a stale HIT), parses `extension_loaded('redis')` + Redis server reachability in the **actual web SAPI**, then self-deletes (with a backstop filesystem rm). `--json` and `--basic-auth` supported; `LSO_PROBE_DOCROOT`/`LSO_PROBE_URL` override seams for tests. Probe mechanism contributed by the agrido project (token guard + LSCache-bust + self-delete, validated on Zenbox/LiteSpeed).
- `analyze` objcache check now flags when the **vhost's resolved lsphp** (per the b4fe352 fix, not wp-cli's php) lacks the `redis` extension — the silent "redis-server is up but LSCWP object cache falls back to MySQL" failure mode confirmed on lsdemo. CLI-context heuristic that points at `probe-redis` for web-context confirmation; stays silent (no score skew) when the binary can't be executed (e.g. fixture mode).
- `lso_php_ext_loaded` helper (lib/core/helpers.sh): does the vhost lsphp build load a given PHP extension? `LSO_PHP_MODULES` test seam.
- `templates/php/probe.php.tpl` + `litespeed-optimizer-lib/probe.sh`.

### Tests
- 12 new (235 total): redis-ext analyze findings (present/missing/undeterminable + FIX hint), and `probe-redis` end-to-end against PHP's built-in server (missing verdict, token-guard 404, no-cache header, self-delete) plus a canned-JSON path (present verdict, `--json` shape, backstop cleanup).

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
- `export-profile --profile <name> [--out file]`: generates LSCWP-native .data import files (v4+ format verified against plugin 7.8.1 import.cls.php) for wp-admin > Toolbox > Import — no SSH needed. Optional companion README (`--with-readme`) with import steps, verification checklist, and what the profile intentionally leaves off. Object-cache keys excluded by default (opt-in via LSO_EXPORT_REDIS_HOST) so an existing Redis setup is never silently disabled. E2E-verified: generated file imports through the REAL plugin and applies
- E2E additions: live-store remote audit + .data import round-trip

### Changed
- woocommerce profile: cache-rest = 0 — with REST caching on, the Woo Store API cart endpoint can serve cached (stale/foreign) cart JSON to cookieless visitors; reproduced empirically in the E2E. Remote analyzer flags cart-API cache hits as DANGER
- Version 0.5.0

## [Unreleased] - pilot harness

### Docs / findings
- LiteSpeed vs FrankenPHP benchmark (`docs/reports/`, Pass-2 + Pass-3 matched worker mode): LiteSpeed ~25% faster on uncached render and ~6.6× faster on the cart path; the gap is engine/SAPI-level, not a process-model artifact. The public LiteSpeed reference demo (litespeed-demo.marcindudek.dev) was rebuilt as a real-stack UltrafastWoo WooCommerce clone (LSCWP full-page cache + Redis, 500 products) to serve as the matched counterpart.
- ROADMAP v0.2+ — two new analyzer checks queued from the demo build: (1) **web-SAPI Redis-extension probe** — object-cache readiness must be judged in the *serving* lsphp (`extension_loaded('redis')` over HTTP), not from `redis-server` presence or CLI php; a web lsphp without the ext makes LSCWP object cache silently fall back to MySQL while `analyze` reports "on". (2) **block-vs-shortcode Cart/Checkout guard** — a block-based cart/checkout renders the empty-cart fallback when WC block rendering is stripped by a perf layer, so an HTTP-200 smoke test passes while checkout is broken; detect `wp:woocommerce/cart`/`checkout` and warn.

### Fixed (Grok review — feature-list honesty + dead code)
- `--feature`/`--exclude` no longer accept roadmap-only names (`http3`/`quic`/`redis`/`mariadb`/`db`/`mysql`/`os-limits`/`limits`/`sysctl`): `ALLOWED_FEATURES` now lists only the 7 registered features + real aliases, so e.g. `--feature http3` is rejected cleanly at validation ("Unknown feature … Valid features: …") instead of passing validation and then failing at apply.
- `--help` FEATURES block lists only the 7 real features (drops the "v0.1 roadmap" framing that implied http3/redis/mariadb/os were usable); roadmap items moved to a clearly-labeled "Planned (not yet implemented)" line; Redis wiring documented as part of `lscwp`.
- DirectAdmin/RunCloud panel warnings corrected: previously claimed "only php/redis/mariadb/os applied" (non-existent features); now state the real behavior (server-tuning/lsapi/lscache become manual steps; opcache/lscwp/woocommerce/security still apply).
- `registry.sh` `feature_remove`: removed the nginx-specific default-removal body (conf.d / sites-enabled / vhost.d — copied verbatim from nginx-optimizer, never valid for LiteSpeed). The custom `feature_remove_custom_<id>` hook is retained; the default now returns an honest "not supported — use `rollback`" error. (223 tests green, shellcheck clean.)

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
