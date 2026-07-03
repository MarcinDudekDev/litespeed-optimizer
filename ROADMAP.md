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

## v0.8 — offline roadmap cleared (shipped)
- [x] **JSON escaping** (`json_escape`, PR #24) — all JSON string fields escaped; no more invalid JSON from a quote/backslash/newline in a path or header.
- [x] **Basic-auth off the argv** (PR #25) — `LSO_HTTP_AUTH` passed via a mode-600 curl `--config` file, not `--user` on the command line (was visible in `ps`).
- [x] **Multi-site `TARGET_SITE` resolution** (PR #27) — shared `_resolve_target_docroot` (exact-path / URL-host / parent-dir / unique-basename, all anchored); replaced the loose substring vhost match in the lscwp/woocommerce apply loops (could hit a `*-staging` sibling).
- [x] **Bad-bot / scraper UA blocker** (PR #28, nginx-optimizer parity) — opt-in `--badbots` `.htaccess` UA denylist (`mod_setenvif` + dual 2.4/2.2 authz), conservative list excluding major search engines; scored in both analyzers (local marker + remote 403 probe).
- [x] **k6/wrk/ab load benchmarking** (PR #29) — `benchmark --load` with tool detection and a portable parallel-curl fallback; `--concurrency`/`--duration`; JSON with concurrency fields. (Meaningful saturation thresholds still need a live box under load.)
- [x] **Transaction wiring into `apply_optimizations`** (PR #30) — server-config edits are staged and committed all-or-nothing; rollback scoped to config-write failures (incl. swallowed ones via a write-error counter); the EXIT-trap rollback is now live. Read-your-writes keeps feature self-verification guards working.

## v0.9 — live-server phase (offline scaffolding shipped, grok-reviewed, CI green)
- [x] **fail2ban** staged jails DISABLED + CDN real-IP guard (PR #37)
- [x] **ModSecurity v3 + OWASP CRS** DetectionOnly (PR #39) + **`--modsec-enforce`** gated flip (PR #40)
- [x] **reCAPTCHA (lsrecaptcha)** staged-disabled + `--recaptcha-enable` arm (PR #41)
- [x] **QUIC.cloud `quic-assist`** onboarding preflight (analyze danger gate, print CNAME + STOP) (PR #42)
- Activation only (operator-authorized, not code): arm fail2ban; reCAPTCHA v2 keys (task #266);
  QUIC.cloud account + registrar DNS (task #267).

## Remaining
**Offline-buildable next (SPEC §§ T2.3/T2.4/T3.4, lines 167–170 — standard OS/DB/OLS config paths,
RAM-tier values; no live panel box required, fixture-testable like server-tuning/opcache):**
- [x] **`os-limits`** (PR #45) — `/etc/systemd/system/lsws.service.d/override.conf` (LimitNOFILE=65535) +
  `/etc/sysctl.d/99-litespeed.conf` (somaxconn 4096, syn_backlog 8192, fin_timeout 15, tw_reuse 1,
  swappiness 10, bbr+fq if available)
- [x] **`mariadb`** (PR #46) — `99-woocommerce.cnf` drop-in (`/etc/mysql/mariadb.conf.d/` or `/etc/my.cnf.d/`):
  buffer pool 256M/512M/1–1.5G/2.5–3G per RAM tier, log_file 25% of pool, O_DIRECT, trx_commit=1,
  slow log 0.5s; restart mariadb only with `--force`/off-peak
- [x] **`http3`** (issue #47) — opt-in `--http3`; on OLS flips `quicEnable 1` in the server `tuning{}`
  block (LIVE-verified on OLS 1.9.0 — NOT `enableQuic` on a listener); Enterprise/panel manual-only;
  advises `ufw allow 443/udp`, warns CSF UDPFLOOD must be 0 (never edits csf.conf); guarded
  `curl --http3` verification hint when curl supports it
- [ ] **`redis`** server-side tuning (maxmemory + eviction policy) — include-based drop-in, issue #48

**Needs a live box / external account (not verifiable offline — parked on operator resources; tracked as issues #50–54):**
- DirectAdmin (#50) / RunCloud (#51) server-config write paths (panel regeneration clobbers direct edits — manual-steps only today)
- Plesk (#52) / Enhance (#53) panel detection + write paths; LiteSpeed Web ADC (#54)
