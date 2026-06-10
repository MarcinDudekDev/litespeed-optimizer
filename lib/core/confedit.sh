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

# ols_get <file> <block> <key>
# Print the value of <key> inside top-level block <block> (first match).
# For the special block "server" the key is looked up at top level (outside
# any block). Returns 1 if not found.
ols_get() {
    local file="$1" block="$2" key="$3"
    [ -f "$file" ] || return 1

    local value
    if [ "$block" = "server" ]; then
        value=$(awk -v key="$key" '
            { sub(/\r$/, "") }
            /^[[:space:]]*#/ { next }
            /\{[[:space:]]*$/ { depth++; next }
            /^[[:space:]]*\}/ { if (depth > 0) depth--; next }
            depth == 0 && $1 == key { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }
        ' "$file")
    else
        value=$(awk -v block="$block" -v key="$key" '
            { sub(/\r$/, "") }
            /^[[:space:]]*#/ { next }
            # block start at top level: "name {" or "name arg {"
            depth == 0 && /\{[[:space:]]*$/ {
                if ($1 == block) inblock = 1
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
        ' "$file")
    fi

    [ -n "$value" ] || return 1
    echo "$value"
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

    local tmp
    tmp=$(secure_mktemp "$(dirname "$file")/.lso-confedit.XXXXXX") || return 1

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
                    split(stripped, parts, /[[:space:]]+/)
                    if (parts[1] == block) inblock = 1
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
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    copy_file_permissions "$file" "$tmp" 2>/dev/null || true
    copy_file_ownership "$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

# ols_ensure_include <file> <include-path>
# Ensure `include <include-path>` exists at top level of <file>; append if not.
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
