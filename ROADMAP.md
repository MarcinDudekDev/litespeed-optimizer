# Roadmap

Canonical spec: docs/research/SPEC.md

## v0.1 (in progress)
- [x] Phase 1 — scaffold + detect + confedit + backup/rollback (foundation)
- [x] Phase 2 — server tuning: tuning{}, lsapi-tuning, opcache, security; golden tests per RAM tier; Docker OLS E2E
- [x] Phase 3 — WordPress/WooCommerce: lscache, LSCWP curated profiles, redis wiring, woocommerce (ESI policy/crawler)
- [x] Phase 4 — security feature, scored analyze audit (0-100), benchmark

## v0.2+
- Web-context OPcache probe (`probe-opcache`): runtime hit-rate/pool-fill is web-SAPI-only (CLI has opcache.enable_cli=0), so `analyze` can't read it via wp-cli. Add an opt-in probe — drop a random-named, token-guarded one-shot PHP status file in the docroot, fetch over HTTP, parse opcache_get_status, delete — to measure the real hit-rate delta (pilot confirmed pool SIZE but not runtime stats). **Don't reinvent**: agrido has a PROVEN token-guarded probe pattern (how the prod 128MB/69–74%/interned-full numbers were measured) and offered a snippet or to contribute it as the `probe-opcache` command — `msg agrido` when picking this up.
- Web-SAPI Redis-extension probe before claiming object-cache readiness: `analyze` decides on Redis from `redis-server` presence (analyzer.sh ~L386), but the **serving lsphp can lack the `redis` PHP extension even when the daemon runs and the CLI php has it** (confirmed on lsdemo 2026-06-16: lsphp83 web SAPI had no redis ext → LSCWP object cache silently fell back to MySQL while `analyze` would still report "object cache on"). Extend the existing "tune the lsphp the *vhost* runs, not the highest installed" detection (commit b4fe352) into the extension dimension — probe `extension_loaded('redis')` in the **web** context (same token-guarded HTTP-probe mechanism as `probe-opcache`), not via wp-cli/CLI php.
- Block-vs-shortcode Cart/Checkout guard (distinct from the existing cart cache-poisoning check at remote-analyzer.sh ~L310): if WC **block** rendering is disabled/stripped by a perf layer, a block-based cart/checkout page renders the empty-cart fallback **regardless of real cart contents** — checkout becomes impossible while the mini-cart badge still shows the count, so an HTTP-200 smoke test passes (confirmed on litespeed-demo 2026-06-16; fix was switching the pages to `[woocommerce_cart]`/`[woocommerce_checkout]`). Detect `wp:woocommerce/cart`/`wp:woocommerce/checkout` in the page content and warn — especially when recommending/applying any block-disabling optimization.
- ModSecurity/OWASP CRS install, reCAPTCHA config, QUIC.cloud onboarding
- DirectAdmin/RunCloud server-config write paths
- fail2ban, honeypot/tarpit, bad-bot blocker (nginx-optimizer parity)
- k6/wrk load benchmarking, LiteSpeed Web ADC, Plesk/Enhance panels
