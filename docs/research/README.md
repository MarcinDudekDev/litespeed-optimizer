# Research Archive — litespeed-optimizer

Multi-agent research conducted 2026-06-10 (4× WebSearch agents + Grok CLI + Gemini CLI + OpenRouter), synthesized into the v0.1 design.

## Read order

| File | What it is |
|------|------------|
| [SPEC.md](SPEC.md) | **v0.1 implementation blueprint** — single source of truth for the build (4 phases) |
| [SYNTHESIS.md](SYNTHESIS.md) | Consolidated findings; 11 cross-model conflicts resolved (see §1 conflict table) |
| [01-server-tuning.md](01-server-tuning.md) | LSWS/OLS server-level tuning params, RAM tiers, LSAPI sizing |
| [02-lscache-woocommerce.md](02-lscache-woocommerce.md) | LSCache plugin + WooCommerce: ESI, vary, purge, CVEs, wp-cli surface |
| [03-stack-tuning.md](03-stack-tuning.md) | lsphp/opcache, Redis, MariaDB, HPOS, OS limits, benchmark methodology |
| [04-landscape.md](04-landscape.md) | Competitive gap analysis — the niche is empty |
| [05-grok-research.md](05-grok-research.md) | Independent report from Grok (⚠ contains errors corrected in SYNTHESIS §1) |
| [06-gemini-research.md](06-gemini-research.md) | Independent report from Gemini 2.5 Flash (⚠ same caveat) |
| [07-openrouter-research.md](07-openrouter-research.md) | Executive summary via OpenRouter |
| [PHASE1-TASK.md](PHASE1-TASK.md) | Original Phase 1 delegation brief |

⚠ Where raw reports (01–07) disagree with SYNTHESIS.md, **SYNTHESIS.md wins** — it resolved the conflicts with sourced claims.

Original location: `/Users/cminds/claude-tmp/main/litespeed-research/` (claude-tmp is periodically cleaned; this copy is canonical).
