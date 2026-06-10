# Roadmap

Canonical spec: docs/research/SPEC.md

## v0.1 (in progress)
- [x] Phase 1 — scaffold + detect + confedit + backup/rollback (foundation)
- [x] Phase 2 — server tuning: tuning{}, lsapi-tuning, opcache, security; golden tests per RAM tier; Docker OLS E2E
- [x] Phase 3 — WordPress/WooCommerce: lscache, LSCWP curated profiles, redis wiring, woocommerce (ESI policy/crawler)
- [x] Phase 4 — security feature, scored analyze audit (0-100), benchmark

## v0.2+
- Web-context OPcache probe (`probe-opcache`): runtime hit-rate/pool-fill is web-SAPI-only (CLI has opcache.enable_cli=0), so `analyze` can't read it via wp-cli. Add an opt-in probe — drop a random-named, token-guarded one-shot PHP status file in the docroot, fetch over HTTP, parse opcache_get_status, delete — to measure the real hit-rate delta (pilot confirmed pool SIZE but not runtime stats). **Don't reinvent**: agrido has a PROVEN token-guarded probe pattern (how the prod 128MB/69–74%/interned-full numbers were measured) and offered a snippet or to contribute it as the `probe-opcache` command — `msg agrido` when picking this up.
- ModSecurity/OWASP CRS install, reCAPTCHA config, QUIC.cloud onboarding
- DirectAdmin/RunCloud server-config write paths
- fail2ban, honeypot/tarpit, bad-bot blocker (nginx-optimizer parity)
- k6/wrk load benchmarking, LiteSpeed Web ADC, Plesk/Enhance panels
