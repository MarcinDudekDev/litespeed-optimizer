# litespeed-optimizer — LIVE-SERVER phase plan v2 (grok-reviewed; nothing applied yet)

**Status:** draft for Marcin's review, revised after an independent grok critique. NO changes to
`lsdemo` or any live box have been made. Offline roadmap is complete at v0.8.0. This plan covers the
deferred live-server items: ModSecurity/OWASP CRS, fail2ban, reCAPTCHA (lsrecaptcha), QUIC.cloud
onboarding, plus the Plesk/ADC panel gap and two SHARED code prerequisites the live items depend on.

## Context
Test box = the PUBLIC WooCommerce demo at litespeed-demo.marcindudek.dev (OLS 1.9.0 Open, Ubuntu 24.04,
lsphp82/83/84, wp-cli, LSWS root under usr/local/lsws). Memory: `lsdemo-live-server-access`. Because it
is a public store, every item is monitor-first, opt-in/default-off, DRY_RUN-honouring, and rides the
existing live-run safety chain — AND extends that chain where grok found it too shallow (below).

## Existing safety harness (reuse) + two gaps it must close first
`cmd_optimize` orders: root gate -> `snapshot_baseline` -> `create_backup` (rsyncs the conf tree) ->
`apply_optimizations` inside the transaction engine (atomic server-config edits) -> `ols_lint` before
restart -> `verified_restart_or_rollback` (restores backup on failure). Confirmed gaps to fix BEFORE any
live security item (these are shared prerequisites, shipped as their own PRs):

- **Prereq A — Woo smoke gate in the health check (CODE, not prose).** Today `health_check` only
  baselines the homepage + vhost home URL; a broken checkout (ModSec enforce, CAPTCHA wall, bad
  threshold) passes with a 200 on `/`. Extend the validator with a mandatory post-restart Woo gate:
  GET cart page, POST add-to-cart (`?wc-ajax=add_to_cart`), GET checkout page, GET the Store API
  products endpoint. Any non-2xx / 403 / redirect-to-captcha triggers `_auto_restore_and_die`. Gate is
  opt-in via a site being detected as WooCommerce; baselined pre-change so it is same-or-better, not
  absolute. This is the single most important fix — without it the rollback chain can't see a broken store.
- **Prereq B — backup scope beyond the conf tree.** `create_backup` rsyncs only the LSWS conf tree.
  fail2ban state (jail.local, jail.d/lso-*, custom filters) and the ModSec/CRS tree may live OUTSIDE it.
  Extend the backup manifest + `restore_backup_files` + `rollback <timestamp>` to include the fail2ban
  dir and the owned ModSec includes/exclusions, so a "successful" rollback can't leave a bad jail or a
  broken CRS include behind. Document that apt-installed PACKAGES are NOT rolled back (config is) — see
  the apt note below.

## Shared cross-cutting rules (non-negotiable on a public store)
1. **No same-run enforce — and it is per-mechanism, not one rule.**
   - ModSecurity: ship `SecRuleEngine DetectionOnly`; flipping to On is a separate `--modsec-enforce`
     run that refuses unless the current engine is DetectionOnly and a printed FP summary is acknowledged.
   - reCAPTCHA (lsrecaptcha has NO monitor mode): first run writes the block with `enabled 0`; a separate
     `--recaptcha-enable` run turns it on after the operator reviews thresholds against live peak.
2. **Real client IP before any host-firewall ban (Prereq + hard abort).** Behind Cloudflare/QUIC.cloud the
   access log shows the edge IP; banning it firewalls the CDN and takes the store offline. fail2ban refuses
   to arm host banning until real-IP restoration is verified (see Item 2, real-IP prerequisite).
3. **Never touch DNS automatically.** QUIC.cloud prints the CNAME/nameserver target and stops.
4. **Opt-in flags, default off** (`--modsec`, `--fail2ban`, `--recaptcha`, etc.), like `--badbots`.
5. **`--trusted-ip` is a prerequisite for live security items.** SPEC §6 calls for it; it is still
   unimplemented. Throttling (dynReqPerSec 2), the bad-bot blocker, fail2ban, and ModSec can compound to
   403 a NAT'd office or a crawler. Implement `--trusted-ip` (allowlist that exempts admin/office IPs from
   throttling + fail2ban + CAPTCHA) BEFORE arming fail2ban/ModSec/reCAPTCHA on the live store.
6. **Payment + bot webhooks are always allowlisted.** Stripe/PayPal/Mollie IPN/webhook paths and gateway
   UAs, plus Googlebot/Bingbot, are exempted from ModSec enforce, reCAPTCHA, and fail2ban — a blocked
   webhook silently breaks order completion.

## Defense-stack interaction (new — the items are NOT independent)
The live box will run, in front of WordPress: the shipped `perClientConnLimit` throttling (banPeriod 300s),
the opt-in bad-bot `.htaccess` blocker (PR #28), plus new fail2ban + ModSec + reCAPTCHA. Precedence and
interactions to document and guard:
- A single offender can be double-penalized (OLS banPeriod 300s AND a fail2ban ban). Default fail2ban
  `maxretry`/`findtime` looser when `perClientConnLimit` is active.
- `--badbots` + ModSec + fail2ban together can 403 legitimate crawlers/feeds — warn when more than one is
  enabled in a run and require `--trusted-ip` to be set for known-good sources.
- Real-IP restoration (Prereq for fail2ban) ALSO fixes throttling/badbots seeing the edge IP — do it once,
  early, and have all four layers consume the restored IP.

## Item 0 (offline) — Panel detection gap + `--trusted-ip` + Prereq A/B
- Panel: add Plesk / LiteSpeed Web ADC / Enhance markers; route them like DA/RunCloud (analyze fully,
  optimize prints manual steps). Add an explicit "unknown/ambiguous panel -> manual-only" fallback so a
  Cloudways/GridPane/aaPanel box can't silently get server-config writes.
- Implement `--trusted-ip` allowlist plumbing (rule 5).
- Ship Prereq A (Woo smoke gate in validator) and Prereq B (backup scope) — both fully fixture-testable
  offline. These are the foundation; nothing live runs until they are merged.

## Item 1 — fail2ban (now BEFORE reCAPTCHA; affects only offenders, dry-run first)
- New `lib/features/fail2ban.sh` (opt-in `--fail2ban`). Install fail2ban; deploy OLS-SPECIFIC filters
  (OLS access-log format differs from Apache combined) for POST floods on wp-login + xmlrpc and a
  repeated-4xx scanner jail. Capture a REAL litespeed-demo access-log line into fixtures and pin the
  field order + failregex; test with `fail2ban-regex` against the fixture before any live arm.
- **Real-IP prerequisite (hard abort):** detect CDN in front (response headers / known CF/QUIC ranges);
  verify OLS logs the real client IP (parse last N access-log lines vs known edge ranges; document the
  exact OLS directive — proxy-IP-in-header / trusted CDN CIDRs — and route it through `lso_conf_set`). If
  behind a CDN and real IP is NOT restored, ABORT (do not fall back to edge banning silently).
- First live run: jails DISABLED + `fail2ban-regex` dry-run only; a second `--fail2ban-enable` arms them.
  Auto-allowlist the server's own IP, the `--trusted-ip` set, and a detected admin IP; conservative
  thresholds. `fail2ban-client -t` must pass before reload; on failure restore the backed-up jail files.
- Cloudflare edge-ban action stays ADVISORY (print CF dashboard steps); only a separate
  `--fail2ban-cf-edge` with token validation would auto-deploy it — not default.
- **Needs user:** admin/office allowlist IPs, ban policy, CF API token only if edge-banning.
- **Top risk:** self-DoS (ban the CDN edge or the admin). Mitigations above + the smoke gate.

## Item 2 — ModSecurity v3 + OWASP CRS, DetectionOnly only (the big one)
- OLS = libModSecurity v3 ONLY (CRS 4.x; 2.9-syntax/Comodo rulesets will not load). Module file is the
  `mod_security.so` under the LSWS modules dir; loaded as a `module mod_security { ls_enabled 1;
  modsecurity on; SecRuleEngine DetectionOnly (backtick-wrapped inline); modsecurity_rules_file -> an
  OWNED includes file under the LSWS conf tree }` block in the main httpd config (never Enterprise XML).
  Note `apt-get install ols-modsecurity` package name is distro/version-fragile — preflight availability
  on Ubuntu 24.04 + OLS 1.9.0 and only install with explicit flag acceptance; record package state in the
  manifest and document that rollback restores config, not package removal.
- Preflight (DetectionOnly is NOT risk-free): module `.so` loads, CRS include chain PARSES (tail the OLS
  error log after reload — `ols_lint` checks brace grammar, not CRS semantics), set
  `SecAuditEngine RelevantOnly` with a sized/rotated audit log (audit-log disk exhaustion can take the
  store down even in DetectionOnly). Treat a post-restart 5xx or latency spike as a rollback trigger, not
  just a homepage 200.
- CRS: install via renamed `.example` templates (never edit CRS rule files — forking breaks updates),
  keep Paranoia Level 1, enable the official CRS WordPress rule-exclusions plugin
  (`setvar:tx.crs_exclusions_wordpress=1`), and PRE-SEED known Woo/WP exclusions (REST 949110, admin-ajax
  941xxx/942xxx, 920273) into the BEFORE/AFTER exclusion files.
- FP tuning loop is HUMAN-IN-THE-LOOP, not unattended: the CLI deploys DetectionOnly + CRS + WP exclusions
  + pre-seeds; `analyze`/`report` PARSES the audit log and SUGGESTS new exclusions; the operator approves
  before any exclusion is written. No auto-apply of harvested exclusions on a first live run.
- **Needs user:** sign-off on each Woo-plugin-specific exclusion and on the enforce flip.
- **Top risk:** enforcing too early -> silent 403 on checkout/cart AJAX + REST -> lost orders. Mitigations:
  DetectionOnly mandatory, PL1, smoke gate, verified rollback, separate enforce flag.

## Item 3 — reCAPTCHA (lsrecaptcha) — staged disabled first
- Promote the existing advisory stub to an apply path (the `--recaptcha` flag is documented but currently
  unparsed — arg-parse + registry wiring is part of THIS PR). First run writes the lsrecaptcha block with
  conservative connection-limit triggers (regConnLimit / sslConnLimit / maxTries) and a search-bot +
  payment-webhook whitelist (`botWhiteList` is a contains/regex UA match), but `enabled 0`, and prints the
  review steps. A separate `--recaptcha-enable` run turns it on after the operator confirms limits against
  live peak (access-log p95 / Real-Time Stats).
- **Needs user:** production Google reCAPTCHA v2 Site + Secret keys for the demo domain (task #246).
- **Top risk:** thresholds too low -> CAPTCHA wall in front of checkout during a sale, or a whitelist gap
  hiding Googlebot/product feeds/payment callbacks. Mitigations: staged-disabled first, conservative
  limits, explicit payment + crawler whitelist, keep off until tuned.

## Item 4 — ModSecurity enforce flip (separate, gated)
- `--modsec-enforce` is a DISTINCT flag; refuses unless the current engine is DetectionOnly. Gate on: a
  minimum DetectionOnly soak period, audit log reviewed, exclusions applied + re-tested, smoke gate
  re-passed, and the operator acknowledges a printed FP summary (`ENFORCE`/`--force`). Verified rollback on
  any restart/health/smoke failure.

## Item 5 — QUIC.cloud onboarding (assist-only; user does account + DNS)
- wp-cli assist: ensure LSCWP + baseline cache/crawler config, trigger the Domain Key request, read back
  link status — ONLY if the QUIC.cloud account already exists. Print the exact CNAME/nameserver target and
  STOP. Never auto-DNS.
- **Woo/cache preflight before recommending the CNAME switch** (OLS has no ESI — this is Vary-for-cart-cookie
  correctness, not Enterprise ESI): LSCWP active; the cart/session cookie is NOT in the do-not-cache list is
  wrong — it MUST be excluded from cache; crawler/role-sim handled; origin still serves the correct
  `Set-Cookie` through the CDN. BLOCK the assist if open `analyze` danger findings exist (server-wide
  cache-everything, guest optimization on a store, a Cloudflare cache-everything rule).
- **Cannot automate:** account registration/login/ToS, Domain Key handshake, dashboard CDN settings, and
  the registrar DNS change.
- **Top risk:** flipping DNS before cache rules/origin are validated -> broken/stale checkout or SSL-edge
  outage. Mitigation: never auto-DNS; validate cart-cookie cache exclusion first; keep origin reachable.

## Proposed sequencing (risk-ascending; each its own PR, COMMIT-BEFORE-GROK-REVIEW per the tree-wipe gotcha)
1. **Item 0** — panel detection + `--trusted-ip` + Prereq A (Woo smoke gate) + Prereq B (backup scope). All
   OFFLINE + fixture-tested. Safe to start immediately with no live access and no keys.
2. **Item 1** — fail2ban: real-IP prereq + filters + jails DISABLED + `fail2ban-regex` dry-run; then
   `--fail2ban-enable`.
3. **Item 2** — ModSecurity DetectionOnly + CRS + WP exclusions (monitor only, human-approved exclusions).
4. **Item 3** — reCAPTCHA staged `enabled 0`; then `--recaptcha-enable` after threshold review.
5. **Item 4** — ModSecurity `--modsec-enforce` after soak + FP review.
6. **Item 5** — QUIC.cloud assist after Woo/cache validation; user does account + DNS.

## Pre-live operator checklist (every live run)
- Low-traffic maintenance window agreed; gateways in test mode OR order monitoring on; rollback timestamp
  recorded; someone watching orders for ~15 min post-apply.
- `--dry-run` first; then a real run that backs up, applies in monitor/DetectionOnly/disabled, and the Woo
  smoke gate confirms home + cart + add-to-cart + checkout + Store API all same-or-better before success.

## What I need from you before any LIVE execution (Item 0 needs nothing — it's offline)
- Go/no-go and order; whether to start Item 0 offline now.
- reCAPTCHA Site + Secret keys (task #246); QUIC.cloud account; admin/office trusted IPs; Cloudflare API
  token only if you want edge-banning.
- Explicit confirmation I may run `optimize` against the live public store for Items 1-5 (each backs up +
  dry-runs first and rides verified restart-or-rollback + the new smoke gate).

## Verification strategy (every item)
1. Offline: `tests/run-tests.sh` green (fixtures for config/log/jail writers + the smoke-gate logic +
   real-IP detection); shellcheck error-clean; bash 3.2.
2. Live (when approved): `--dry-run`, then a real run gated by the Woo smoke gate (Prereq A).
3. Rollback proof: backup (now including fail2ban + ModSec trees, Prereq B) + `verified_restart_or_rollback`
   restores on any restart/health/smoke failure; ModSec DetectionOnly cannot 403 by construction; reCAPTCHA
   ships disabled.

## Sources
Primary docs (OpenLiteSpeed ModSecurity/reCAPTCHA, coreruleset.org FP tuning + WP exclusion plugin,
fail2ban + CDN, LSCWP/QUIC.cloud onboarding, LiteSpeed blog) — to be copied into docs/research/ before the
implementation PRs (grok LOW: scratch-dir citations aren't durable for reviewers). Verify exact default
numbers (connection limits, CRS anomaly thresholds, the `ols-modsecurity` package name) against the live
OLS 1.9.x WebAdmin and installed crs-setup before hardcoding — defaults shift across versions.

## Grok critique disposition (v1 -> v2)
All 7 must-fix items folded in: (1) Woo smoke gate tied to rollback = Prereq A; (2) fail2ban + CRS in
backup/rollback = Prereq B; (3) real-IP restore as an explicit hard-abort prerequisite; (4) reCAPTCHA
phased enable, hard-rule split per-mechanism; (5) reordered (fail2ban dry-run before active reCAPTCHA,
QUIC.cloud after Woo/cache validation); (6) defense-stack section + `--trusted-ip` prerequisite + payment
webhooks; (7) `--modsec-enforce` distinct flag with soak/review. MEDIUM/LOW: ModSec preflight + audit-log
rotation, apt side-effect note, human-in-the-loop FP tuning, unknown-panel fallback, concrete fail2ban
failregex in fixtures, `--recaptcha` arg-parse scheduled in its PR, CF edge-ban advisory-only, citations
into docs/research, maintenance-window checklist.
