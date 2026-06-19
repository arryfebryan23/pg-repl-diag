#!/usr/bin/env bash
#
# lib/repl_common.sh
# -----------------------------------------------------------------------------
# Shared configuration loader and validation helpers for the toolkit.
#
# Every script under bin/ sources this file. It loads the central configuration
# file (repl.env) and exposes require()/require_all() so that any operation
# which depends on a variable can abort cleanly when that variable is not set.
# This file is meant to be SOURCED, not executed directly.
# -----------------------------------------------------------------------------

# Resolve toolkit layout: this file lives in <root>/lib, so the root is its parent.
__REPL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__REPL_ROOT="$(cd "$__REPL_LIB_DIR/.." && pwd)"

# Central configuration file. Override its location by exporting REPL_ENV_FILE.
REPL_ENV_FILE="${REPL_ENV_FILE:-${__REPL_ROOT}/repl.env}"

if [ ! -f "$REPL_ENV_FILE" ]; then
    echo "ERROR: configuration file not found: $REPL_ENV_FILE" >&2
    echo "       Copy 'repl.env.example' to 'repl.env' and edit it, or set REPL_ENV_FILE." >&2
    echo "       Operation aborted." >&2
    exit 1
fi

# Export every value defined in the config so that libpq (PGHOST/PGPORT/...)
# and child processes inherit it. The config uses the ${VAR:-default} form, so
# any value already present in the environment still takes precedence.
set -a
# shellcheck source=/dev/null
. "$REPL_ENV_FILE"
set +a

# require VAR ["description"] — abort the operation if VAR is empty or unset.
require() {
    local name="$1" desc="${2:-}"
    if [ -z "${!name:-}" ]; then
        echo "ERROR: required variable '$name' is not set${desc:+ — $desc}." >&2
        echo "       Set it in '$REPL_ENV_FILE' (or export it) and re-run. Operation aborted." >&2
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
