#!/bin/bash
################################################################################
# core/confedit.sh - OpenLiteSpeed Config Edit Primitives
################################################################################
# OLS httpd_config.conf is line-oriented `block { key value }`. These awk-based
# primitives read/write keys inside NAMED TOP-LEVEL blocks, create blocks when
# absent, and manage include lines.
#
# LSWS Enterprise note: NEVER edit httpd_config.xml — Enterprise writes go via
# Apache includes / .htaccess (handled by feature modules, not here).
#
# All functions tolerate CRLF input and preserve comments/indentation of
# untouched lines.
################################################################################

# Resolve which path to READ for <file> under a transaction: the staged temp if
# this file already has pending (uncommitted) edits, else the live file. This
# gives read-your-writes consistency — a feature that re-reads a value it just
# wrote (e.g. lscache's enableCache safety guard) sees the staged value, not the
# stale live one. Read-only: never stages, only inspects the arrays, so it is
# safe to call from inside $(...) (the subshell inherits the arrays).
_confedit_read_src() {
    local file="$1"
    if [ "${TRANSACTION_ACTIVE:-false}" = true ] && [ "${#TRANSACTION_FILES[@]}" -gt 0 ]; then
        local k
        for ((k=0; k<${#TRANSACTION_FILES[@]}; k++)); do
            if [ "${TRANSACTION_FILES[$k]}" = "$file" ]; then
                printf '%s' "${TRANSACTION_TEMPS[$k]}"
                return 0
            fi
        done
    fi
    printf '%s' "$file"
}

# ols_get <file> <block> <key>
# Print the value of <key> inside top-level block <block> (first match).
# For the special block "server" the key is looked up at top level (outside
# any block). Returns 1 if not found.
ols_get() {
    local file="$1" block="$2" key="$3"
    [ -f "$file" ] || return 1
    local rfile
    rfile=$(_confedit_read_src "$file")

    local value
    if [ "$block" = "server" ]; then
        value=$(awk -v key="$key" '
            { sub(/\r$/, "") }
            /^[[:space:]]*#/ { next }
            /\{[[:space:]]*$/ { depth++; next }
            /^[[:space:]]*\}/ { if (depth > 0) depth--; next }
            depth == 0 && $1 == key { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }
        ' "$rfile")
    else
        value=$(awk -v block="$block" -v key="$key" '
            { sub(/\r$/, "") }
            /^[[:space:]]*#/ { next }
            # block start at top level: "name {" or "name arg {"
            # block may be given as "name" or "name arg" (e.g. "module cache")
            depth == 0 && /\{[[:space:]]*$/ {
                hdr = $0
                sub(/^[[:space:]]+/, "", hdr)
                sub(/[[:space:]]*\{[[:space:]]*$/, "", hdr)
                if (hdr == block || $1 == block) inblock = 1
                depth++
                next
            }
            /\{[[:space:]]*$/ { depth++; next }
            /^[[:space:]]*\}/ {
                if (depth > 0) depth--
                if (depth == 0) inblock = 0
                next
            }
            inblock && depth == 1 && $1 == key {
                $1 = ""; sub(/^[[:space:]]+/, ""); print; exit
            }
        ' "$rfile")
    fi

    [ -n "$value" ] || return 1
    echo "$value"
}

# When a transaction is active, route confedit writes through the staged temp
# (edit-in-place, commit later) instead of writing the live file directly; when
# inactive, read+write the live file (legacy immediate-write, byte-for-byte
# unchanged). Sets the caller's _CE_SRC (awk input) + _CE_DEST (final mv target)
# via bash dynamic scoping — the caller must `local _CE_SRC _CE_DEST` first.
# Returns 1 if staging fails. MUST be called statement-level (transaction_stage
# mutates module arrays — never inside $(...)).
_confedit_route() {
    local file="$1"
    if [ "${TRANSACTION_ACTIVE:-false}" = true ] && type -t transaction_stage >/dev/null 2>&1; then
        transaction_stage "$file" || return 1
        _CE_SRC="$TXN_TEMP_FILE"
        _CE_DEST="$TXN_TEMP_FILE"
        # Count every staged write (rises even when the file was already staged),
        # so the optimize loop can attribute a config write to the running feature.
        TRANSACTION_WRITES=$(( ${TRANSACTION_WRITES:-0} + 1 ))
    else
        _CE_SRC="$file"
        _CE_DEST="$file"
    fi
    return 0
}

# ols_set <file> <block> <key> <value>
# Set <key> to <value> inside top-level block <block>:
# - key exists in block      -> replace value (preserve indentation)
# - block exists, key absent -> insert before block's closing brace
# - block absent             -> append block at end of file
# Writes via temp file + atomic mv; preserves perms/ownership.
ols_set() {
    local file="$1" block="$2" key="$3" value="$4"
    [ -f "$file" ] || return 1

    local _CE_SRC _CE_DEST
    _confedit_route "$file" || return 1

    local tmp
    tmp=$(secure_mktemp "$(dirname "$_CE_DEST")/.lso-confedit.XXXXXX") || return 1

    awk -v block="$block" -v key="$key" -v value="$value" '
        BEGIN { done = 0; inblock = 0; depth = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            # Track block scope (ignore comment lines for scoping)
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)
            is_comment = (stripped ~ /^#/)

            if (!is_comment && line ~ /\{[[:space:]]*$/) {
                if (depth == 0) {
                    hdr = stripped
                    sub(/[[:space:]]*\{[[:space:]]*$/, "", hdr)
                    split(stripped, parts, /[[:space:]]+/)
                    if (hdr == block || parts[1] == block) inblock = 1
                }
                depth++
                print line
                next
            }
            if (!is_comment && stripped ~ /^\}/) {
                if (inblock && depth == 1 && !done) {
                    printf "  %-30s %s\n", key, value
                    done = 1
                }
                if (depth > 0) depth--
                if (depth == 0) inblock = 0
                print line
                next
            }
            if (!is_comment && inblock && depth == 1) {
                split(stripped, kv, /[[:space:]]+/)
                if (kv[1] == key && !done) {
                    # Preserve leading whitespace of the original line
                    match(line, /^[[:space:]]*/)
                    indent = substr(line, 1, RLENGTH)
                    printf "%s%-30s %s\n", indent, key, value
                    done = 1
                    next
                }
            }
            print line
        }
        END {
            if (!done) {
                print ""
                print block " {"
                printf "  %-30s %s\n", key, value
                print "}"
            }
        }
    ' "$_CE_SRC" > "$tmp" || { rm -f "$tmp"; return 1; }

    copy_file_permissions "$_CE_SRC" "$tmp" 2>/dev/null || true
    copy_file_ownership "$_CE_SRC" "$tmp" 2>/dev/null || true
    mv "$tmp" "$_CE_DEST"
}

# ols_ensure_include <file> <include-path>
# Ensure `include <include-path>` exists at top level of <file>; append if not.
# NOTE: NOT transaction-aware — writes the live file immediately and is not
# covered by the optimize transaction. No feature calls it during optimize today
# (tests only). If a future feature needs it mid-optimize, route it through
# _confedit_route / _confedit_read_src like ols_set first.
ols_ensure_include() {
    local file="$1" include_path="$2"
    [ -f "$file" ] || return 1

    if grep -E "^[[:space:]]*include[[:space:]]+${include_path}[[:space:]]*$" "$file" >/dev/null 2>&1; then
        return 0
    fi

    local tmp
    tmp=$(secure_mktemp "$(dirname "$file")/.lso-confedit.XXXXXX") || return 1
    cp "$file" "$tmp"
    {
        echo ""
        echo "# Added by litespeed-optimizer"
        echo "include ${include_path}"
    } >> "$tmp"

    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    copy_file_ownership "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

# ols_remove_include <file> <include-path>
# Remove a previously added include line (and our marker comment above it).
ols_remove_include() {
    local file="$1" include_path="$2"
    [ -f "$file" ] || return 1

    local tmp
    tmp=$(secure_mktemp "$(dirname "$file")/.lso-confedit.XXXXXX") || return 1

    awk -v inc="include ${include_path}" '
        {
            line = $0
            sub(/\r$/, "", line)
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)
            if (stripped == inc) { skip_marker = 0; next }
            if (stripped == "# Added by litespeed-optimizer") {
                held = line; have_held = 1; next
            }
            if (have_held) { print held; have_held = 0 }
            print line
        }
        END { if (have_held) print held }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    copy_file_ownership "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

# ols_lint <file>
# Grammar pre-check before touching a live config: balanced braces, no
# obviously broken block headers. OLS has no `-t`, so this catches garbage
# before the restart-and-verify step does.
# Returns: 0 = OK, 1 = problem (message on stderr)
ols_lint() {
    local file="$1"
    [ -f "$file" ] || { echo "ols_lint: no such file: $file" >&2; return 1; }

    local result
    result=$(awk '
        BEGIN { depth = 0; err = "" }
        {
            line = $0
            sub(/\r$/, "", line)
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)
            if (stripped ~ /^#/) next
            # Count braces on the line
            n_open = gsub(/\{/, "{", line)
            n_close = gsub(/\}/, "}", line)
            depth += n_open - n_close
            if (depth < 0 && err == "") {
                err = "unbalanced closing brace at line " NR
                exit 1
            }
        }
        END {
            if (err != "") { print err; exit 1 }
            if (depth != 0) { print "unbalanced braces: " depth " unclosed block(s)"; exit 1 }
            print "OK"
        }
    ' "$file")

    if [ "$result" != "OK" ]; then
        echo "ols_lint: $file: $result" >&2
        return 1
    fi
    return 0
}

# ols_get_env <file> <block> <VARNAME>
# Print the value of a repeated `env VAR=value` line inside a block
# (extprocessor blocks carry many env lines, so plain ols_get cannot address them).
ols_get_env() {
    local file="$1" block="$2" var="$3"
    local rfile
    rfile=$(_confedit_read_src "$file")
    local line
    line=$(awk -v block="$block" -v var="$var" '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next }
        depth == 0 && /\{[[:space:]]*$/ {
            hdr = $0
            sub(/^[[:space:]]+/, "", hdr)
            sub(/[[:space:]]*\{[[:space:]]*$/, "", hdr)
            if (hdr == block || $1 == block) inblock = 1
            depth++
            next
        }
        /\{[[:space:]]*$/ { depth++; next }
        /^[[:space:]]*\}/ {
            if (depth > 0) depth--
            if (depth == 0) inblock = 0
            next
        }
        inblock && depth == 1 && $1 == "env" {
            split($2, kv, "=")
            if (kv[1] == var) {
                sub(/^[^=]*=/, "", $2)
                print $2
                exit
            }
        }
    ' "$rfile")

    [ -n "$line" ] || return 1
    echo "$line"
}

# ols_set_env <file> <block> <VARNAME> <value>
# Set `env VAR=value` inside a block: replace the matching env line, or insert
# before the block's closing brace. Creates the block if absent.
ols_set_env() {
    local file="$1" block="$2" var="$3" value="$4"
    [ -f "$file" ] || return 1

    local _CE_SRC _CE_DEST
    _confedit_route "$file" || return 1

    local tmp
    tmp=$(secure_mktemp "$(dirname "$_CE_DEST")/.lso-confedit.XXXXXX") || return 1

    awk -v block="$block" -v var="$var" -v value="$value" '
        BEGIN { done = 0; inblock = 0; depth = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)
            is_comment = (stripped ~ /^#/)

            if (!is_comment && line ~ /\{[[:space:]]*$/) {
                if (depth == 0) {
                    hdr = stripped
                    sub(/[[:space:]]*\{[[:space:]]*$/, "", hdr)
                    split(stripped, parts, /[[:space:]]+/)
                    if (hdr == block || parts[1] == block) inblock = 1
                }
                depth++
                print line
                next
            }
            if (!is_comment && stripped ~ /^\}/) {
                if (inblock && depth == 1 && !done) {
                    printf "  %-30s %s=%s\n", "env", var, value
                    done = 1
                }
                if (depth > 0) depth--
                if (depth == 0) inblock = 0
                print line
                next
            }
            if (!is_comment && inblock && depth == 1) {
                split(stripped, kv, /[[:space:]]+/)
                if (kv[1] == "env") {
                    split(kv[2], ev, "=")
                    if (ev[1] == var && !done) {
                        match(line, /^[[:space:]]*/)
                        indent = substr(line, 1, RLENGTH)
                        printf "%s%-30s %s=%s\n", indent, "env", var, value
                        done = 1
                        next
                    }
                }
            }
            print line
        }
        END {
            if (!done) {
                print ""
                print block " {"
                printf "  %-30s %s=%s\n", "env", var, value
                print "}"
            }
        }
    ' "$_CE_SRC" > "$tmp" || { rm -f "$tmp"; return 1; }

    copy_file_permissions "$_CE_SRC" "$tmp" 2>/dev/null || true
    copy_file_ownership "$_CE_SRC" "$tmp" 2>/dev/null || true
    mv "$tmp" "$_CE_DEST"
}

################################################################################
# Dry-Run-Aware Wrappers (used by feature modules)
################################################################################

# lso_conf_set <file> <block> <key> <value>
lso_conf_set() {
    local file="$1" block="$2" key="$3" value="$4"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would set ${block}.${key} = ${value} in ${file}"
        return 0
    fi
    # Propagate a write failure so the feature returns non-zero (the transaction
    # then rolls back cleanly) instead of relying solely on set -e killing the
    # shell into the EXIT-trap rollback.
    ols_set "$file" "$block" "$key" "$value" || return 1
    log_info "Set ${block}.${key} = ${value}"
}

# lso_conf_set_env <file> <block> <VAR> <value>
lso_conf_set_env() {
    local file="$1" block="$2" var="$3" value="$4"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would set ${block} env ${var}=${value} in ${file}"
        return 0
    fi
    ols_set_env "$file" "$block" "$var" "$value" || return 1
    log_info "Set ${block} env ${var}=${value}"
}
