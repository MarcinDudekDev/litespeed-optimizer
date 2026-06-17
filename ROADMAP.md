# Roadmap

Canonical spec: docs/research/SPEC.md

## v0.1 — MVP (complete; shipped through v0.4.0–v0.5.0)
- [x] Phase 1 — scaffold + detect + confedit + backup/rollback (foundation)
- [x] Phase 2 — server tuning: tuning{}, lsapi-tuning, opcache, security; golden tests per RAM tier; Docker OLS E2E
- [x] Phase 3 — WordPress/WooCommerce: lscache, LSCWP curated profiles, redis wiring, woocommerce (ESI policy/crawler)
- [x] Phase 4 — security feature, scored analyze audit (0-100), benchmark

## v0.2+
- [x] **Web-SAPI Redis-extension probe** (shipped v0.6.0): `probe-redis` command verifies `extension_loaded('redis')` in the **web** context via a token-guarded one-shot HTTP probe; `analyze` additionally flags when the vhost's resolved lsphp (b4fe352) lacks the ext (the silent "redis up but object cache falls back to MySQL" case from lsdemo 2026-06-16). Built on agrido's contributed token-guarded probe harness.
- [x] **Web-context OPcache probe** (`probe-opcache`, shipped v0.7.0): reads runtime hit-rate/pool-fill/interned/key-table/oom from the web SAPI via the shared `_probe_fetch_json` harness; undersized verdict on agrido's thresholds (oom>0 · free<10% · keys>=95% · interned<5% · hit_rate<90% warm-gated); host-aware remediation (writable ini → sizing snippet, else contact-host). Thresholds captured in team memory 2026-06-17.
- Block-vs-shortcode Cart/Checkout guard (distinct from the existing cart cache-poisoning check at remote-analyzer.sh ~L310): if WC **block** rendering is disabled/stripped by a perf layer, a block-based cart/checkout page renders the empty-cart fallback **regardless of real cart contents** — checkout becomes impossible while the mini-cart badge still shows the count, so an HTTP-200 smoke test passes (confirmed on litespeed-demo 2026-06-16; fix was switching the pages to `[woocommerce_cart]`/`[woocommerce_checkout]`). Detect `wp:woocommerce/cart`/`wp:woocommerce/checkout` in the page content and warn — especially when recommending/applying any block-disabling optimization.
- ModSecurity/OWASP CRS install, reCAPTCHA config, QUIC.cloud onboarding
- DirectAdmin/RunCloud server-config write paths
- fail2ban, honeypot/tarpit, bad-bot blocker (nginx-optimizer parity)
- k6/wrk load benchmarking, LiteSpeed Web ADC, Plesk/Enhance panels
