# Roadmap

Canonical spec: docs/research/SPEC.md

## v0.1 — MVP (complete; shipped through v0.4.0–v0.5.0)
- [x] Phase 1 — scaffold + detect + confedit + backup/rollback (foundation)
- [x] Phase 2 — server tuning: tuning{}, lsapi-tuning, opcache, security; golden tests per RAM tier; Docker OLS E2E
- [x] Phase 3 — WordPress/WooCommerce: lscache, LSCWP curated profiles, redis wiring, woocommerce (ESI policy/crawler)
- [x] Phase 4 — security feature, scored analyze audit (0-100), benchmark

## v0.2+
- [x] **Web-SAPI Redis-extension probe** (shipped v0.6.0): `probe-redis` command verifies `extension_loaded('redis')` in the **web** context via a token-guarded one-shot HTTP probe; `analyze` additionally flags when the vhost's resolved lsphp (b4fe352) lacks the ext (the silent "redis up but object cache falls back to MySQL" case from lsdemo 2026-06-16). Built on agrido's contributed token-guarded probe harness.
- Web-context OPcache probe (`probe-opcache`): runtime hit-rate/pool-fill is web-SAPI-only (CLI has opcache.enable_cli=0), so `analyze` can't read it via wp-cli. The **token-guarded HTTP-probe harness now exists** (`litespeed-optimizer-lib/probe.sh` + `templates/php/probe.php.tpl`, shipped with `probe-redis`); `probe-opcache` reuses the same drop→fetch→self-delete flow — add the `opcache_get_status(false)` block to the probe template (agrido's full template at `~/claude-tmp/agrido/probe-harness/probe.php.tmpl` already has it) and a parse/report layer. agrido contributed the harness (how the prod 128MB/69–74%/interned-full numbers were measured) AND the verdict thresholds (captured in team memory 2026-06-17): FULL if any of oom_restarts>0 · free<~10% · num_cached_keys>=95% of max · interned_free<~5% · hit_rate<~90% sustained — but hit_rate is cumulative-since-restart so gate it on cache warmth (don't alarm on a cold cache). Remediation MUST branch on host: opcache.* are PHP_INI_SYSTEM, often not raisable per-account on shared/managed hosting → emit "contact host", not an unappliable php.ini snippet.
- Block-vs-shortcode Cart/Checkout guard (distinct from the existing cart cache-poisoning check at remote-analyzer.sh ~L310): if WC **block** rendering is disabled/stripped by a perf layer, a block-based cart/checkout page renders the empty-cart fallback **regardless of real cart contents** — checkout becomes impossible while the mini-cart badge still shows the count, so an HTTP-200 smoke test passes (confirmed on litespeed-demo 2026-06-16; fix was switching the pages to `[woocommerce_cart]`/`[woocommerce_checkout]`). Detect `wp:woocommerce/cart`/`wp:woocommerce/checkout` in the page content and warn — especially when recommending/applying any block-disabling optimization.
- ModSecurity/OWASP CRS install, reCAPTCHA config, QUIC.cloud onboarding
- DirectAdmin/RunCloud server-config write paths
- fail2ban, honeypot/tarpit, bad-bot blocker (nginx-optimizer parity)
- k6/wrk load benchmarking, LiteSpeed Web ADC, Plesk/Enhance panels
