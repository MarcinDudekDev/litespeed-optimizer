#!/bin/bash
################################################################################
# ui.sh - Minimal UI Helpers
################################################################################
# Lightweight presentation layer; logging itself lives in the entrypoint.
################################################################################

ui_header() {
    [ "${QUIET:-false}" = true ] && return 0
    echo ""
    echo -e "${CYAN}litespeed-optimizer${NC} v${VERSION:-?} — LiteSpeed WordPress optimization"
    echo ""
}

ui_section() {
    [ "${QUIET:-false}" = true ] && return 0
    echo ""
    echo -e "${BLUE}=== $* ===${NC}"
}

ui_blank() {
    [ "${QUIET:-false}" = true ] && return 0
    echo ""
}

ui_step() {
    [ "${QUIET:-false}" = true ] && return 0
    echo -e "  ${GREEN}+${NC} $*"
}

ui_step_fail() {
    echo -e "  ${RED}x${NC} $*"
}
