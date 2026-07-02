# GOAL: clear the live-server phase (Items 1–5)

**Objective:** drive `docs/research/LIVE-PHASE-PLAN.md` to zero — every remaining item either
merged (offline code) or explicitly parked on a named user blocker. One item = one grok-reviewed PR,
following the proven workflow below.

> **✅ STATUS (2026-07-02): OFFLINE PHASE CLEARED.** All five items are merged, grok-reviewed, CI green:
> Item 1 fail2ban (PR #37), Item 2 ModSecurity DetectionOnly (#39), Item 4 `--modsec-enforce` (#40),
> Item 3 reCAPTCHA staged-disabled (#41), Item 5 QUIC.cloud `quic-assist` (#42). Suite 405/0/0 on
> bash 3.2 + 5. Nothing further is buildable offline. The only residue is the user-authorized live
> ACTIVATIONS below (arm fail2ban; reCAPTCHA v2 keys; QUIC.cloud account + registrar DNS).

## Honest scope: what CAN vs CANNOT be auto-cleared
The list is NOT fully closable without you. Split:

**Autonomously buildable NOW (offline, no keys, fixture-tested):**
- **Item 2 — ModSecurity v3 + OWASP CRS, DetectionOnly.** The next PR. Pure offline.
- **Item 4 — ModSecurity enforce flip (`--modsec-enforce`).** The flag + refuse-unless-DetectionOnly
  gate + soak/FP-acknowledge logic can be BUILT and fixture-tested offline (depends on Item 2 code).
  The actual flip is a live action, but the mechanism ships here.
- **Item 3 arg-parse + staged-disabled writer + Item 5 wp-cli assist scaffolding** can be built
  offline too; they just cannot be *activated* without your inputs.

**Hard-blocked on YOU (cannot close autonomously):**
- **Item 1 arming** — needs a maintenance window + go-ahead on the live public Woo store.
- **Item 3 activation** — Google reCAPTCHA v2 Site + Secret keys (your task #246).
- **Item 5** — QUIC.cloud account + a registrar DNS change (never auto-DNS).
- Any live apply to lsdemo — needs explicit re-approval each time.

So "clear the list" autonomously = ship Items 2, 4, and the offline scaffolding of 3 & 5 as merged
PRs; then the residue is a short, named checklist of live actions that only you can authorize.

## Definition of Done (per item)
Merged to main, all CI green (Bash Syntax macos and ubuntu, Shellcheck, Portability, Test Suite
macos and ubuntu, Docker E2E), grok-reviewed with findings folded, test count only rising, opt-in
and default-off, DetectionOnly/disabled on first apply, backup+rollback covers any new state.

## Ordered execution (each its own PR) — ALL DONE
1. ✅ **Item 2 (PR #39)** — `lib/features/modsec.sh`, opt-in `--modsec`, DetectionOnly + CRS 4.x + WP
   exclusion plugin + pre-seeded Woo exclusions; preflight (module .so load, CRS parse via error-log
   tail, sized+rotated audit log); package state in manifest; logrotate drop-in in the backup loop.
2. ✅ **Item 4 (PR #40)** — `--modsec-enforce` flag, refuses unless engine is already DetectionOnly,
   gated on a printed FP summary acknowledge; verified rollback on any restart/health/smoke failure.
3. ✅ **Item 3 (PR #41)** — promoted the reCAPTCHA stub to an apply path writing `enabled 0` + a separate
   `--recaptcha-enable`; arg-parse + registry wired. Parks on your keys (task #266).
4. ✅ **Item 5 (PR #42)** — read-only `quic-assist` subcommand (LSCWP baseline preflight, analyze danger
   gate, print the CNAME/nameserver target and STOP; never auto-DNS). Parks on your account + DNS (#267).
   (Also ✅ **Item 1 (PR #37)** fail2ban, built earlier in the arc.)
5. **Live residue (all that's left)** — a checklist for you: window + arm Item 1, provide reCAPTCHA keys
   (#266), QUIC.cloud account + DNS (#267), and authorize each live `optimize` run (backs up + dry-runs first).

## Proven workflow (FOLLOW EXACTLY — ~15 PRs, incl. #37)
- Implement, mirroring `lib/features/fail2ban.sh` (newest template: opt-in gate, guarded live-only
  blocks behind empty `LSO_FS_ROOT` or `DRY_RUN`, `_lso_fs` paths). Register in `ALLOWED_FEATURES`.
- COMMIT TO A BRANCH FIRST. Then ONE grok-analyzer on the committed diff, ANALYSIS ONLY — forbid it
  from running any git-mutating command, shellcheck, tests, or execution (it has wiped the tree
  twice; memory `grok-analyzer-tree-wipe`). Never two grok procs at once.
- Fold fixes. `tests/run-tests.sh` green under BOTH bash 3.2 and bash 5 (count only rises).
  shellcheck error and warning clean on changed files.
- PR, wait for ALL CI, squash-merge, pull main.

## bash 3.2 landmines (both bit us this session — memory has them)
- No `case` block defined lexically inside a command substitution (breaks bash-3.2 parse and the
  macos CI Bash-Syntax job; also aborts the suite under bash 3.2). Use if/elif.
- `stat -c` (GNU) BEFORE `stat -f` (BSD) — `stat -f` succeeds with wrong output on Linux.
- No associative arrays, no parameter-case-lowering, no flock, no find-printf. `set -euo pipefail`.
- Absolute paths through `_lso_fs`. Tests non-root with `LSO_FS_ROOT` + `LSO_SKIP_RESTART=1`.

## Context/memory to consult
`litespeed-optimizer-v080-offline-roadmap`, `grok-analyzer-tree-wipe`,
`credential-hook-false-positive-pathrefs` (keep code refs in prose; the write hook trips on
slash-joined tokens), `lsdemo-live-server-access`, `autonomous-fix-until-zero`.
