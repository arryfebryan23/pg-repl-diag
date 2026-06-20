#!/usr/bin/env bash
#
# lib/repl_common.sh
# -----------------------------------------------------------------------------
# Shared configuration loader and validation helpers for the toolkit.
#
# Every script under bin/ sources this file. It loads the two configuration
# files (repl.script.env for toolkit behaviour, repl.env for the environment)
# and exposes require()/require_all() so that any operation which depends on a
# variable can abort cleanly when that variable is not set.
# This file is meant to be SOURCED, not executed directly.
# -----------------------------------------------------------------------------

# Resolve toolkit layout: this file lives in <root>/lib, so the root is its parent.
__REPL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__REPL_ROOT="$(cd "$__REPL_LIB_DIR/.." && pwd)"

# Configuration is split across TWO files, by concern:
#   1. repl.script.env  — toolkit / script behaviour (output dirs, logging,
#      sampling cadence, thresholds, console appearance). Ships with the repo
#      and is the same on every node.
#   2. repl.env         — deployment environment (PostgreSQL connection, target
#      standby / peer IPs, link bandwidth). Site-specific; copied from
#      repl.env.example and git-ignored.
# Override either location with REPL_SCRIPT_ENV_FILE / REPL_ENV_FILE.
REPL_SCRIPT_ENV_FILE="${REPL_SCRIPT_ENV_FILE:-${__REPL_ROOT}/repl.script.env}"
REPL_ENV_FILE="${REPL_ENV_FILE:-${__REPL_ROOT}/repl.env}"

if [ ! -f "$REPL_SCRIPT_ENV_FILE" ]; then
    echo "ERROR: script configuration file not found: $REPL_SCRIPT_ENV_FILE" >&2
    echo "       This file ships with the toolkit; restore it from version control" >&2
    echo "       or set REPL_SCRIPT_ENV_FILE. Operation aborted." >&2
    exit 1
fi
if [ ! -f "$REPL_ENV_FILE" ]; then
    echo "ERROR: environment configuration file not found: $REPL_ENV_FILE" >&2
    echo "       Copy 'repl.env.example' to 'repl.env' and edit it, or set REPL_ENV_FILE." >&2
    echo "       Operation aborted." >&2
    exit 1
fi

# Export every value so that libpq (PGHOST/PGPORT/...) and child processes
# inherit it. Both files use the ${VAR:-default} form, so any value already
# present in the environment still takes precedence. Script defaults load first,
# then the site environment.
set -a
# shellcheck source=/dev/null
. "$REPL_SCRIPT_ENV_FILE"
# shellcheck source=/dev/null
. "$REPL_ENV_FILE"
set +a

# Shared presentation layer (colors, banners, sections, status tags, verdict
# blocks, timestamped logging). Sourcing it here gives EVERY script the same
# console look & feel. It is loaded BEFORE start_logging so that color is decided
# against the real terminal, not the tee pipe.
# shellcheck source=./repl_format.sh
if [ -f "${__REPL_LIB_DIR}/repl_format.sh" ]; then
    . "${__REPL_LIB_DIR}/repl_format.sh"
fi

# require VAR ["description"] — abort the operation if VAR is empty or unset.
require() {
    local name="$1" desc="${2:-}"
    if [ -z "${!name:-}" ]; then
        fail "required variable '$name' is not set${desc:+ — $desc}." >&2
        note "Set it in '$REPL_ENV_FILE' (or export it) and re-run. Operation aborted." >&2
        exit 1
    fi
}

# require_all VAR1 VAR2 ... — validate several variables at once.
require_all() {
    local v
    for v in "$@"; do require "$v"; done
}

# ensure_dir DIR [DIR...] — create output directories on demand.
ensure_dir() {
    local d
    for d in "$@"; do mkdir -p "$d"; done
}

# iostat_peak — from a single 1-second iostat sample, echo "max_%util device await"
# for the busiest disk. Echoes "0 - 0" when iostat is not installed. Self-contained
# (no globals), so every sampler/probe shares one implementation.
# NOTE: this call BLOCKS for ~1s, so a sampler's real cadence is INTERVAL + ~1s.
iostat_peak() {
    command -v iostat >/dev/null 2>&1 || { echo "0 - 0"; return; }
    iostat -dxy 1 1 2>/dev/null | awk '
      /^Device/ { for(i=1;i<=NF;i++){ if($i=="%util")u=i; if($i=="await")a=i; if($i=="w_await")w=i } next }
      NF>3 && u>0 { v=$u+0; if(v>m){m=v;d=$1;aw=(a?$a+0:(w?$w+0:0))} }
      END{ printf "%.1f %s %.1f", m+0,(d==""?"-":d),aw+0 }'
}

# single_instance NAME — guarantee only ONE copy of a long-running command runs.
# Takes a non-blocking flock on a per-NAME lockfile under LOG_DIR and aborts if it
# is already held (e.g. a forgotten background sampler). The lock is released
# automatically when the process exits (fd 9 stays open for its lifetime).
# Best-effort: if flock is unavailable the guard is skipped silently.
# Pass a NAME that is UNIQUE PER NODE (e.g. the CSV basename) so that nodes sharing
# a bind-mounted lock directory do not block each other.
single_instance() {
    local name="$1"
    local dir="${LOG_DIR:-${OUTPUT_DIR:-/tmp}}"
    mkdir -p "$dir" 2>/dev/null || dir="/tmp"
    local lock="${dir}/.${name}.lock"
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$lock" 2>/dev/null || return 0
    flock -n 9 || die "another '${name}' instance is already running (lock: ${lock})."
}

# -----------------------------------------------------------------------------
# Per-run logging
# -----------------------------------------------------------------------------
# Every command's console output (stdout + stderr) is mirrored to a log file
# INSIDE the project (LOG_DIR), instead of a system path such as /var/log that
# is frequently not writable by the running user (permission denied). The log is
# appended per script — restart-safe — with a banner separating each run. Output
# still appears on the terminal (via tee), so interactive runs are unchanged.
#
# Override the location with LOG_DIR, or disable entirely with REPL_NO_LOG=1.
LOG_DIR="${LOG_DIR:-${OUTPUT_DIR:-${__REPL_ROOT}/output}/log}"

start_logging() {
    # Run only once, and honour the opt-out switch.
    [ -n "${__REPL_LOGGING:-}" ] && return 0
    [ -n "${REPL_NO_LOG:-}" ]    && return 0

    local base
    base="$(basename "${0:-toolkit}" .sh)"

    # If the log directory cannot be created (e.g. read-only mount), skip logging
    # silently rather than aborting the diagnostic run.
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0

    REPL_LOG_FILE="${LOG_DIR}/${base}.log"
    __REPL_LOGGING=1

    {
        echo ""
        echo "===== $(date '+%Y-%m-%d %H:%M:%S') | start ${base} (pid $$) ====="
    } >> "$REPL_LOG_FILE" 2>/dev/null

    # Mirror everything from here on to the log file and the terminal.
    exec > >(tee -a "$REPL_LOG_FILE") 2>&1
}

# Enable logging automatically for every script that sources this file.
start_logging
