# E2E Report: WordPress + WooCommerce on OpenLiteSpeed

- **Date**: 2026-06-10 15:40:36
- **Stack**: litespeedtech/openlitespeed:latest + mariadb:11 + Redis (in-container), WordPress + WooCommerce (real installs via wp-cli), lsphp82
- **Tool**: litespeed-optimizer 0.4.0
- **Result**: 23 passed, 0 failed

## Scores & timing

| Metric | Value |
|---|---|
| analyze score before optimize | 43/100 |
| analyze score after optimize | 90/100 |
| First-request TTFB (cache prime) | 1.5 ms |
| Warm median TTFB (5 requests) | 1.5 ms |

## Checks

| Status | Check |
|---|---|
| PASS | detect: OLS + WP site (Example/html) discovered |
| PASS | check passes with live WP stack |
| PASS | analyze (before): score 43/100 |
| PASS | optimize --profile woocommerce: all features applied |
| PASS | post-optimize restart + health check passed |
| PASS | OLS ESI warning surfaced during Woo optimize |
| PASS | analyze (after): score improved 43 -> 90 |
| PASS | LSCWP option cache-ttl_pub = 604800 (verified on real plugin) |
| PASS | LSCWP option cache-ttl_priv = 1800 (verified on real plugin) |
| PASS | LSCWP option purge-stale = 1 (verified on real plugin) |
| PASS | LSCWP option guest_optm = 0 (verified on real plugin) |
| PASS | LSCWP option object-life = 600 (verified on real plugin) |
| PASS | LSCWP option debug = 0 (verified on real plugin) |
| PASS | product page: x-litespeed-cache hit |
| PASS | cart page not served from cache (header: 'absent') |
| PASS | session A sees its cart item (Store API) |
| PASS | session B does NOT see session A's cart (isolation OK) |
| PASS | LSCWP object-cache.php drop-in installed |
| PASS | Redis object cache connected (139 keys) |
| PASS | benchmark: first 1.5 ms, warm median 1.5 ms |
| PASS | benchmark confirms x-litespeed-cache: hit |
| PASS | rollback 20260610-133653: restored + server verified healthy |
| PASS | store still serves HTTP 200 after rollback |

## Notable findings (from developing this E2E)

1. **Vhost `rewrite { enable 0 }` silently breaks LSCWP cookie vary on OLS** — LSCWP's vary rules live in the `# BEGIN LSCACHE` .htaccess rewrite block; with the vhost rewrite engine off they never execute, and a page cached for a cart-holding session was served to a fresh session (real cache poisoning, reproduced). The `analyze` command now flags this as a DANGER finding. Fix: `rewrite { enable 1, autoLoadHtaccess 1 }` in vhconf.conf.
2. The registered Woo cart page is correctly `no-cache` via LSCWP; ad-hoc pages containing `[woocommerce_cart]` outside the registered cart page are NOT excluded — don't duplicate cart shortcodes on cacheable pages.
3. The Docker image's Example vhost serves `index.html` ahead of `index.php` — WP appears installed (wp-cli works) while HTTP serves the static demo page.

## How to reproduce

```bash
tests/e2e-woo.sh   # needs Docker; ~5-10 min
```
