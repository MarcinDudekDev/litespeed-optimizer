Build litespeed-optimizer v0.1 — Phase 1.

Full blueprint: /Users/cminds/claude-tmp/main/litespeed-research/SPEC.md — read it first, it is the single source of truth. Consolidated research: SYNTHESIS.md next to it; 7 raw research reports in the same dir if you need detail.

Reference architecture to mirror: /Users/cminds/Tools/nginx-optimizer (CLI conventions, module layout, backup/rollback pattern, tests).

Phase 1 scope per SPEC:
- git init + repo scaffold (litespeed-optimizer.sh entrypoint, lib/ modules, templates/, tests/)
- CLI skeleton with command dispatch: detect / check / analyze / optimize / rollback / benchmark / status, with --dry-run
- Environment detection module: LSWS Enterprise vs OpenLiteSpeed, panel detection (CyberPanel / cPanel / DirectAdmin / plain), config path resolution
- Timestamped backup + verified rollback (graceful restart + HTTP health check + auto-restore on failure)
- bats / golden-file tests for detection and backup (fixture config trees — no real LiteSpeed server needed)

Constraints:
- Bash 3.2+ compatible, like nginx-optimizer
- TEST everything before reporting (run the test suite); if something is untestable, say UNTESTED explicitly
- Do NOT implement phases 2–4 yet

When done, report what was built and the test results.
