# litespeed-optimizer — agent notes

One command to make WordPress on LiteSpeed fast and secure. Sibling of ~/Tools/nginx-optimizer — mirror its conventions.

## Canonical spec
docs/research/SPEC.md (single source of truth; SYNTHESIS.md = consolidated research, 01-07 = raw reports).

## Hard rules
- Bash 3.2 compatible: NO `declare -A`, NO `flock`, NO `find -printf`, NO `${var,,}`.
- shellcheck --severity=error must pass on every .sh file.
- `set -euo pipefail` everywhere; mkdir-based locks; NO_COLOR support; `[DRY RUN] Would ...` logging.
- NEVER edit LSWS Enterprise httpd_config.xml — Apache includes / .htaccess only.
- NEVER set `enableCache 1` server-wide (cache poisoning across vhosts).
- maxConns == PHP_LSAPI_CHILDREN invariant (lsapi-tuning).
- All absolute paths go through the LSO_FS_ROOT prefix so fixtures work.

## Layout
- litespeed-optimizer.sh — entrypoint (arg parse, lock, dispatch)
- lib/registry.sh — feature registry (copied verbatim from nginx-optimizer; server-agnostic)
- lib/core/ — helpers, sysinfo (RAM tiers + lso_children), detect-env, confedit (OLS primitives), templates
- lib/features/ — one file per feature, feature_register at end (Phase 2+)
- litespeed-optimizer-lib/ — workflow modules: backup, validator (restart-or-rollback), detector, ui
- tests/run-tests.sh — plain-bash suite (no bats); fixtures in tests/configs/<env>/

## Testing
`tests/run-tests.sh` — must be green before reporting completion. Fixture trees simulate plain-ols, cyberpanel, cpanel-enterprise, directadmin, broken-edge. Use LSO_FS_ROOT + LSO_DATA_DIR + LSO_SKIP_RESTART=1.
