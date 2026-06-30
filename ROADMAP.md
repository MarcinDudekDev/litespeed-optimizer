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
- [x] **Block-vs-shortcode Cart/Checkout guard** (shipped, remote-analyzer.sh `_rm_woo_block_check`): a block-rendered cart/checkout renders the empty-cart fallback if a perf layer disables WC block rendering — checkout silently breaks while still returning HTTP 200 (confirmed on litespeed-demo 2026-06-16; fix was switching the pages to `[woocommerce_cart]`/`[woocommerce_checkout]`). Emits a non-scoring `warn` advisory.

## v0.2 — safety-model hardening (shipped, from independent cross-model audit)
- [x] LSCWP option **rollback** — `restore_backup_files` now `litespeed-option import`s the pre-change export back into its docroot (was: server files only).
- [x] **Real-vhost health check** — `snapshot_baseline` wired into `optimize`; `health_check` verifies the real vhost, not just `127.0.0.1` (a broken vhost masked by the default vhost now triggers rollback).
- [x] **No-eval restart** — metachar-guarded, `noglob` word-split (was `eval`, a root-RCE vector); empty restart command fails closed.
- [x] **Root gate** on `optimize`/`rollback`.
- [x] **Security response headers** — `security` feature deploys `X-Content-Type-Options`/`X-Frame-Options`/`Referrer-Policy` via `.htaccess` (the `headers` alias was previously a no-op).

## v0.3+ — remaining
Offline-implementable (no live server needed):
- k6/wrk load benchmarking (extend `benchmark.sh` to concurrency/saturation; meaningful thresholds still need a live box under load)
- honeypot/tarpit + bad-bot blocker via `.htaccess` (nginx-optimizer parity)
- transaction wiring into `apply_optimizations` (interrupt-safety; backup/rollback already covers recovery)
- multi-site `analyze`/optimize `TARGET_SITE` resolution; JSON escaping; `--netrc` for basic-auth (avoid creds in `ps`)

Needs a live LiteSpeed server and/or an external account (not verifiable offline):
- ModSecurity/OWASP CRS install, reCAPTCHA config, QUIC.cloud onboarding
- DirectAdmin/RunCloud server-config write paths; fail2ban
- LiteSpeed Web ADC, Plesk/Enhance panel detection + write paths
