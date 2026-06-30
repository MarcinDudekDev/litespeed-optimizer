#!/bin/bash
################################################################################
# core/helpers.sh - Common Helper Functions
################################################################################
# Consolidates reusable patterns used across feature modules:
# - run_cmd dry-run wrapper
# - smart sudo file copy
# - cross-platform checksum / mtime
# - secure mktemp
################################################################################

################################################################################
# Dry-Run Command Wrapper
################################################################################

# Run a command, or log what would run under --dry-run
# Args: $@ = command and arguments
# Uses global: DRY_RUN
run_cmd() {
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would run: $*"
        return 0
    fi
    "$@"
}

# Write content to a file, or log under --dry-run
# Args: $1 = target path; content on stdin
run_write() {
    local target="$1"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write: $target"
        cat > /dev/null
        return 0
    fi
    cat > "$target"
}

################################################################################
# File Operations
################################################################################

# Copy file with automatic sudo handling
# Args: $1 = source path, $2 = destination path
smart_copy() {
    local src="$1"
    local dst="$2"
    local dst_dir

    [ -z "$src" ] || [ -z "$dst" ] && return 1
    [ ! -f "$src" ] && return 1

    dst_dir=$(dirname "$dst")

    if [ -w "$dst_dir" ]; then
        cp "$src" "$dst"
    else
        sudo cp "$src" "$dst"
    fi
}

# Create a temp file with restrictive permissions
# Args: $1 = mktemp template (e.g., /path/.lso-txn.XXXXXX)
secure_mktemp() {
    local template="$1"
    local old_umask
    old_umask=$(umask)
    umask 077
    mktemp "$template"
    umask "$old_umask"
}

# Copy permissions from one file to another (BSD/GNU portable)
copy_file_permissions() {
    local src="$1" dst="$2"
    local mode
    mode=$(stat -f '%Lp' "$src" 2>/dev/null || stat -c '%a' "$src" 2>/dev/null) || return 1
    chmod "$mode" "$dst"
}

# Copy ownership from one file to another (BSD/GNU portable; best-effort)
copy_file_ownership() {
    local src="$1" dst="$2"
    local owner
    owner=$(stat -f '%Su:%Sg' "$src" 2>/dev/null || stat -c '%U:%G' "$src" 2>/dev/null) || return 1
    chown "$owner" "$dst" 2>/dev/null || true
}

################################################################################
# HTTP basic-auth via curl --config (keeps creds off the curl argv / out of `ps`)
################################################################################

# Credentials in ${LSO_HTTP_AUTH} ("user:pass") must NOT go on the curl command
# line, where any local user could read them via `ps`. Instead we write them to
# a mode-600 curl config file ONCE and pass `--config <path>`. A `user = "..."`
# directive behaves EXACTLY like `--user` (so creds are dropped on a cross-host
# redirect, unlike a netrc `default` entry which would forward them), and the
# quoted form is whitespace-safe (unlike a bare argv token).
#
# IMPORTANT: _lso_auth_init must run in the PARENT shell (e.g. once from main),
# NOT inside a `$(...)` — every call site reads the path via command
# substitution (a subshell), so a mutation made there would be lost and each
# curl would leak a fresh temp. Creation is therefore separated from reading:
#   _lso_auth_init    — create the config temp once, in the parent (idempotent)
#   _lso_auth_args    — pure read; echoes `--config <path>` (subshell-safe)
#   _lso_auth_cleanup — remove the temp (call from the EXIT trap)
LSO_AUTH_FILE=""
_lso_auth_init() {
    [ -n "${LSO_HTTP_AUTH:-}" ] || return 0
    [ -n "$LSO_AUTH_FILE" ] && [ -f "$LSO_AUTH_FILE" ] && return 0
    LSO_AUTH_FILE=$(secure_mktemp "${LSO_DATA_DIR:-${TMPDIR:-/tmp}}/.lso-auth.XXXXXX" 2>/dev/null) \
        || { LSO_AUTH_FILE=""; return 1; }
    chmod 600 "$LSO_AUTH_FILE" 2>/dev/null || true
    # curl config quoted-string escaping: backslash and double-quote.
    local esc=$LSO_HTTP_AUTH
    esc=${esc//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf 'user = "%s"\n' "$esc" > "$LSO_AUTH_FILE"
}

_lso_auth_args() {
    [ -n "$LSO_AUTH_FILE" ] && printf '%s' "--config $LSO_AUTH_FILE"
    return 0
}

_lso_auth_cleanup() {
    [ -n "$LSO_AUTH_FILE" ] && rm -f "$LSO_AUTH_FILE" 2>/dev/null
    LSO_AUTH_FILE=""
}

################################################################################
# PHP environment probes
################################################################################

# Does the vhost's resolved lsphp build load a given PHP extension?
# Checks the lsphp the VHOST actually runs (LSO_PHP_BIN, resolved per the
# b4fe352 fix) — NOT wp-cli's php. The two can be different binaries/builds,
# which is exactly how an object cache silently falls back to MySQL: redis-server
# is up and CLI php has the ext, but the serving lsphp does not.
# Test seam: LSO_PHP_MODULES (space-separated module list), when set, short-
# circuits execution so fixture runs (whose php stubs are non-executable) are
# deterministic — mirrors the LSO_RAM_MB / WP_MOCK_* override convention.
# Returns: 0 = loaded, 1 = not loaded, 2 = undeterminable (cannot exec binary)
lso_php_ext_loaded() {
    local ext="$1"
    if [ -n "${LSO_PHP_MODULES+x}" ]; then
        case " $LSO_PHP_MODULES " in
            *" $ext "*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    [ -n "${LSO_PHP_BIN:-}" ] && [ -x "${LSO_PHP_BIN}" ] || return 2
    if "$LSO_PHP_BIN" -m 2>/dev/null | grep -qiE "^${ext}$"; then
        return 0
    fi
    return 1
}

# List PIDs of running lsphp worker processes (one per line).
# Test/override seam: redefine this function to feed deterministic PIDs without
# touching real processes. Matches on `comm` (the worker cmdline is just `lsphp`,
# NOT the full /lsphpNN/bin/lsphp path — so `pkill -f .../lsphp` would miss it).
_lso_lsphp_pids() {
    ps -eo pid,comm 2>/dev/null | awk '$2 ~ /(^|\/)lsphp$/ { print $1 }'
}

# Force-recycle lsphp worker processes so a freshly-written php.ini/OPcache
# drop-in takes effect in the WEB SAPI immediately. A graceful LiteSpeed restart
# (SIGUSR1) does NOT recycle existing lsphp children — they keep serving the OLD
# config until they cycle on their own. We recycle them by PID; LSWS respawns on
# demand, loading the new config. (Confirmed live on lsdemo 2026-06-17.)
#
# CRITICAL — recycle GRACEFULLY (SIGTERM first, SIGKILL only stragglers):
# a hard SIGKILL mid-request can tear an in-flight write. Observed live on lsdemo
# (2026-06-18): a -9 between WordPress committing an option to the DB and the
# object-cache (Redis) write of the updated `alloptions` blob completing left the
# two diverged — DB had the right active theme, Redis served the OLD one, so the
# site rendered the wrong (default) theme until the object cache was flushed.
# SIGTERM lets each worker finish its current request (and any in-flight cache
# write) before exiting; only workers still alive after the grace window are
# SIGKILLed, so the recycle stays guaranteed without tearing requests.
# Honors DRY_RUN and LSO_SKIP_RESTART/LSO_FS_ROOT (fixture/test mode).
# Grace window: LSO_RECYCLE_GRACE seconds (default 2).
lso_recycle_lsphp() {
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would gracefully recycle lsphp worker(s) to load new php.ini/OPcache config"
        return 0
    fi
    if [ "${LSO_SKIP_RESTART:-0}" = "1" ] || [ -n "${LSO_FS_ROOT:-}" ]; then
        log_info "lsphp recycle skipped (fixture/test mode)"
        return 0
    fi

    local pids pid count=0
    pids=$(_lso_lsphp_pids)
    if [ -z "$pids" ]; then
        log_info "No lsphp workers running to recycle"
        return 0
    fi

    # Phase 1 — SIGTERM: ask each worker to finish its current request and exit.
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
        count=$((count + 1))
    done

    # Let workers drain in-flight requests before we force anything.
    sleep "${LSO_RECYCLE_GRACE:-2}"

    # Phase 2 — SIGKILL only the stragglers still alive (busy/stuck), so the
    # recycle is still guaranteed even if a worker ignored SIGTERM.
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    log_success "Recycled ${count} lsphp worker(s) gracefully — new php.ini/OPcache config now live in web SAPI"
}

################################################################################
# Checksums / Timestamps (cross-platform)
################################################################################

# Cross-platform checksum helper (prefers SHA-256, falls back to MD5)
file_checksum() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1
    elif command -v md5sum &>/dev/null; then
        md5sum "$file" 2>/dev/null | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        md5 -q "$file" 2>/dev/null
    else
        stat -f '%z-%m' "$file" 2>/dev/null || stat -c '%s-%Y' "$file" 2>/dev/null || echo "unknown"
    fi
}

# Get directory modification time (cross-platform), epoch on stdout
get_dir_mtime() {
    local dir="$1"
    local mtime

    mtime=$(stat -f '%m' "$dir" 2>/dev/null)
    if [ -n "$mtime" ]; then
        echo "$mtime"
        return 0
    fi

    mtime=$(stat -c '%Y' "$dir" 2>/dev/null)
    if [ -n "$mtime" ]; then
        echo "$mtime"
        return 0
    fi

    echo "0"
}

################################################################################
# Transaction Primitives (multi-file atomic edits)
################################################################################

TRANSACTION_FILES=()
TRANSACTION_TEMPS=()
TRANSACTION_ACTIVE=false
# Count of staged confedit WRITES this transaction (incremented per ols_set/
# ols_set_env routed to staging). Unlike the file count it rises on EVERY staged
# write, even repeated edits to the same already-staged file — so callers can tell
# whether a given feature actually wrote config (the file count can't, due to
# same-file dedup).
# shellcheck disable=SC2034  # mutated in confedit.sh (_confedit_route), read in optimizer.sh
TRANSACTION_WRITES=0
# Count of FAILED staged confedit writes this transaction (secure_mktemp/awk/mv
# failure inside ols_set/ols_set_env). The optimize loop checks this AFTER each
# feature even when feature_apply returned 0 — a feature can swallow a write
# failure (errexit is off inside `if feature_apply`), and committing its partial
# config would be worse than a false rollback.
# shellcheck disable=SC2034  # mutated in confedit.sh, read in optimizer.sh
TRANSACTION_WRITE_ERRORS=0

# Start transaction: prepare to modify multiple files atomically
transaction_start() {
    TRANSACTION_FILES=()
    TRANSACTION_TEMPS=()
    # shellcheck disable=SC2034  # read cross-file in confedit.sh/optimizer.sh
    TRANSACTION_WRITES=0
    # shellcheck disable=SC2034  # read cross-file in confedit.sh/optimizer.sh
    TRANSACTION_WRITE_ERRORS=0
    TRANSACTION_ACTIVE=true
}

# Stage a file in the transaction: creates temp copy, sets TXN_TEMP_FILE.
# IMPORTANT: do NOT call via $(...) — command substitution runs in a subshell
# and the parent's TRANSACTION_* arrays would never see the staged file.
# Usage: transaction_stage <original_path>; edit "$TXN_TEMP_FILE"
TXN_TEMP_FILE=""
transaction_stage() {
    local original_path="$1"
    TXN_TEMP_FILE=""

    if [ ! "$TRANSACTION_ACTIVE" = true ]; then
        log_error "No active transaction. Call transaction_start first."
        return 1
    fi

    # Dedup by path: if this file is already staged (an earlier feature edited it
    # in this same run), reuse its existing temp so successive edits accumulate
    # onto the staged copy — NOT a fresh copy of the untouched original (which
    # would discard the earlier edits on commit).
    if [ "${#TRANSACTION_FILES[@]}" -gt 0 ]; then
        local j
        for ((j=0; j<${#TRANSACTION_FILES[@]}; j++)); do
            if [ "${TRANSACTION_FILES[$j]}" = "$original_path" ]; then
                # shellcheck disable=SC2034  # Consumed by callers after transaction_stage
                TXN_TEMP_FILE="${TRANSACTION_TEMPS[$j]}"
                return 0
            fi
        done
    fi

    local target_dir
    target_dir=$(dirname "$original_path")
    local temp_file
    temp_file=$(secure_mktemp "${target_dir}/.lso-txn.XXXXXX")

    if [ -f "$original_path" ]; then
        cp "$original_path" "$temp_file"
        copy_file_permissions "$original_path" "$temp_file" 2>/dev/null || true
        copy_file_ownership "$original_path" "$temp_file" 2>/dev/null || true
    fi

    TRANSACTION_FILES+=("$original_path")
    TRANSACTION_TEMPS+=("$temp_file")

    # shellcheck disable=SC2034  # Consumed by callers after transaction_stage
    TXN_TEMP_FILE="$temp_file"
}

# Commit transaction: atomically move all temp files to originals
transaction_commit() {
    if [ ! "$TRANSACTION_ACTIVE" = true ]; then
        log_error "No active transaction to commit"
        return 1
    fi

    local count=${#TRANSACTION_FILES[@]}
    local i
    for ((i=0; i<count; i++)); do
        local original="${TRANSACTION_FILES[$i]}"
        local temp="${TRANSACTION_TEMPS[$i]}"
        if [ -f "$temp" ]; then
            mv "$temp" "$original"
        fi
    done

    TRANSACTION_FILES=()
    TRANSACTION_TEMPS=()
    TRANSACTION_ACTIVE=false
    return 0
}

# Rollback transaction: delete all temp files, abort changes
transaction_rollback() {
    if [ ! "$TRANSACTION_ACTIVE" = true ]; then
        return 0
    fi

    if [ "${#TRANSACTION_TEMPS[@]}" -gt 0 ]; then
        local temp
        for temp in "${TRANSACTION_TEMPS[@]}"; do
            rm -f "$temp"
        done
    fi

    TRANSACTION_FILES=()
    TRANSACTION_TEMPS=()
    TRANSACTION_ACTIVE=false
}

################################################################################
# JSON
################################################################################

# Escape a string for safe inclusion inside a JSON double-quoted value.
# Handles backslash, double-quote, and the common control chars (tab/CR/LF).
# Pure bash 3.2 parameter expansion; prints the escaped string (no quotes).
# Args: $1 = raw string
json_escape() {
    local s=$1
    s=${s//\\/\\\\}     # backslash first, so later additions aren't doubled
    s=${s//\"/\\\"}     # double quote
    s=${s//$'\t'/\\t}   # tab
    s=${s//$'\r'/\\r}   # carriage return
    s=${s//$'\n'/\\n}   # newline
    printf '%s' "$s"
}
