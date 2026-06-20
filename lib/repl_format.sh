#!/usr/bin/env bash
#
# lib/repl_format.sh
# -----------------------------------------------------------------------------
# Presentation layer for the toolkit: colors, banners, section headers, aligned
# key/value output, status tags, verdict blocks, and timestamped log lines.
#
# Design goals:
#   * Consistent, enterprise-grade console output across every script.
#   * Color is semantic and AUTOMATICALLY DISABLED when stdout is not a
#     terminal (e.g. redirected to a log file) or when NO_COLOR is set, so log
#     files never contain ANSI escape codes. Force it with REPL_COLOR=always|never.
#   * ASCII-only glyphs for maximum portability over SSH and in log archives.
#
# This file is sourced by lib/repl_common.sh; do not execute it directly.
# -----------------------------------------------------------------------------

REPL_WIDTH="${REPL_WIDTH:-74}"

# --- Color initialization (TTY/NO_COLOR aware) -------------------------------
__repl_init_colors() {
    local enable=0
    case "${REPL_COLOR:-auto}" in
        always) enable=1 ;;
        never)  enable=0 ;;
        *)      if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then enable=1; fi ;;
    esac
    if [ "$enable" = "1" ]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
        C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
        C_BLU=$'\033[34m';  C_CYN=$'\033[36m'; C_GRY=$'\033[90m'
    else
        C_RESET=''; C_BOLD=''; C_DIM=''
        C_RED='';   C_GRN='';  C_YLW=''
        C_BLU='';   C_CYN='';  C_GRY=''
    fi
}
__repl_init_colors

# --- Primitives --------------------------------------------------------------
# rule [char] — full-width horizontal rule.
rule() {
    local ch="${1:-=}"
    printf '%s\n' "$(printf '%*s' "$REPL_WIDTH" '' | tr ' ' "$ch")"
}

# run_header "MODULE TITLE" — standard banner printed at the top of every script.
run_header() {
    local title="$1"
    printf '\n%s' "$C_CYN$C_BOLD"
    rule '='
    printf '  %s\n' "${REPL_TOOLKIT_NAME:-Replication Diagnostics Toolkit}"
    printf '  %s\n' "$title"
    rule '='
    printf '%s' "$C_RESET"
    kv "Version"   "${REPL_TOOLKIT_VERSION:-dev}"
    kv "Host"      "$(hostname 2>/dev/null || echo '-')"
    kv "Timestamp" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# section "TITLE" — major section heading with an underline rule.
section() {
    printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
    printf '%s' "$C_GRY"; rule '-'; printf '%s' "$C_RESET"
}

# subsection "text" — minor heading.
subsection() { printf '\n%s>> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# kv "key" "value" — aligned key/value pair.
kv() { printf '  %s%-26s%s %s\n' "$C_GRY" "$1" "$C_RESET" ": $2"; }

# --- Status tags -------------------------------------------------------------
info() { printf '  %s[INFO]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YLW" "$C_RESET" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
step() { printf '  %s[STEP]%s %s\n' "$C_CYN" "$C_RESET" "$*"; }

# note "msg" — dim, indented continuation line.
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# bullet / action — list items inside a verdict or recommendation block.
bullet() { printf '    %s-%s %s\n' "$C_GRY" "$C_RESET" "$*"; }
action() { printf '    %s=>%s %s\n' "$C_GRN" "$C_RESET" "$*"; }

# --- Verdict block -----------------------------------------------------------
# verdict LEVEL "headline"  (LEVEL = good|ok | warn | bad|crit)
verdict() {
    local lvl="$1"; shift
    local col
    case "$lvl" in
        ok|good)   col="$C_GRN" ;;
        warn)      col="$C_YLW" ;;
        bad|crit)  col="$C_RED" ;;
        *)         col="$C_BOLD" ;;
    esac
    printf '\n%s' "$col$C_BOLD"
    rule '='
    printf '  VERDICT: %s\n' "$*"
    rule '='
    printf '%s' "$C_RESET"
}

# --- Timestamped logging (for long-running samplers) -------------------------
__repl_log() {
    local tag="$1" col="$2"; shift 2
    printf '%s %s%-5s%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$col" "$tag" "$C_RESET" "$*"
}
log_info() { __repl_log "INFO" "$C_BLU" "$@"; }
log_ok()   { __repl_log "OK"   "$C_GRN" "$@"; }
log_warn() { __repl_log "WARN" "$C_YLW" "$@"; }
log_err()  { __repl_log "ERROR" "$C_RED" "$@"; }
log_evt()  { __repl_log "EVENT" "$C_CYN" "$@"; }

# die "msg" — report a fatal error and abort.
die() { fail "$*"; exit 1; }
