#!/usr/bin/env bash
#
# lib/repl_daemon.sh
# -----------------------------------------------------------------------------
# start / stop / restart / status control for the long-running background
# samplers (libexec/pg-repl-diag/sample-primary and sample-standby).
#
# Both control files live in the SAME FOLDER as the sampler script (the dir is
# passed in as RUN_DIR), so the lock and PID sit right next to the feature they
# guard:
#   $RUN_DIR/.<name>.lock   advisory flock, held for the sampler's whole lifetime
#   $RUN_DIR/.<name>.pid    PID of the running daemon, so 'stop' can signal it
#
# The lock is the source of truth for "is it running" (the PID file can go
# stale); single_instance() in repl_common.sh takes the very same lock from
# inside the daemon, so a manual foreground run and 'start' cannot both run.
#
# This file is sourced by lib/repl_common.sh; do not execute it directly.
# -----------------------------------------------------------------------------

# daemon_running LOCK PIDFILE
#   Echo the running daemon's PID (when known) and return 0 if an instance is
#   running, or return 1 if not. "Running" is decided by whether the advisory
#   lock can be taken non-blockingly: if we can grab it, nobody holds it.
daemon_running() {
    local lock="$1" pidf="$2" pid=""
    [ -f "$pidf" ] && pid="$(tr -dc '0-9' < "$pidf" 2>/dev/null)"
    if command -v flock >/dev/null 2>&1; then
        # Probe the lock in a subshell so fd 9 (and thus the lock) is released
        # the instant the test finishes — this never disturbs a real holder.
        if ( exec 9>"$lock" 2>/dev/null && flock -n 9 ); then
            return 1            # we acquired it -> no daemon holds it
        fi
        [ -n "$pid" ] && printf '%s' "$pid"
        return 0                # held by the running daemon
    fi
    # No flock available: fall back to the PID file alone.
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$pid"; return 0
    fi
    return 1
}

# daemon_start NAME LABEL SELF LOCK PIDFILE
#   Launch "<SELF> run" detached in the background and record its PID. Idempotent:
#   refuses to start a second copy. Verifies the daemon survives initialisation
#   (DB connect, role check, lock acquisition) before reporting success.
daemon_start() {
    local name="$1" label="$2" self="$3" lock="$4" pidf="$5" pid=""
    if pid="$(daemon_running "$lock" "$pidf")"; then
        log_warn "${label} is already running${pid:+ (pid ${pid})}."
        note "lock: $lock"
        return 0
    fi

    local logf="${LOG_DIR}/$(basename "$self").log"
    # Detach from the controlling terminal so the daemon outlives this shell.
    # The sampler mirrors its own output to $logf via start_logging, so the
    # launch streams are sent to /dev/null here.
    if command -v setsid >/dev/null 2>&1; then
        setsid "$self" run >/dev/null 2>&1 </dev/null &
    else
        nohup  "$self" run >/dev/null 2>&1 </dev/null &
    fi
    pid=$!
    printf '%s\n' "$pid" > "$pidf"

    # Give it a moment to initialise; if it dies, surface why.
    local i=0
    while [ "$i" -lt 6 ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_ok "${label} started (pid ${pid})."
        note "log:  $logf"
        note "lock: $lock"
        return 0
    fi

    rm -f "$pidf"
    log_err "${label} exited during start-up — see the log for the reason."
    note "log: $logf"
    [ -f "$logf" ] && tail -n 15 "$logf" 2>/dev/null
    return 1
}

# daemon_stop NAME LABEL LOCK PIDFILE
#   SIGTERM the running daemon, wait up to ~10s for a clean exit, then SIGKILL.
daemon_stop() {
    local name="$1" label="$2" lock="$3" pidf="$4" pid=""
    if ! pid="$(daemon_running "$lock" "$pidf")"; then
        log_info "${label} is not running."
        rm -f "$pidf"
        return 0
    fi
    if [ -z "$pid" ]; then
        log_warn "${label} is running but its PID file is missing ($pidf); cannot signal it."
        note "Find it manually, e.g.: ps -ef | grep '${name}'"
        return 1
    fi

    log_info "stopping ${label} (pid ${pid})..."
    kill -TERM "$pid" 2>/dev/null
    local i=0
    while [ "$i" -lt 20 ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "still alive after 10s; sending SIGKILL."
        kill -KILL "$pid" 2>/dev/null
        sleep 0.5
    fi
    rm -f "$pidf"
    log_ok "${label} stopped."
    return 0
}

# daemon_status NAME LABEL LOCK PIDFILE  — LSB-style status (0 running, 3 stopped).
daemon_status() {
    local name="$1" label="$2" lock="$3" pidf="$4" pid=""
    if pid="$(daemon_running "$lock" "$pidf")"; then
        log_ok "${label} is RUNNING${pid:+ (pid ${pid})}."
        note "lock: $lock"
        return 0
    fi
    log_info "${label} is STOPPED."
    return 3
}

# daemon_dispatch ACTION NAME LABEL SELF RUN_DIR
#   Single entry point used by the samplers. Resolves the lock/PID paths inside
#   RUN_DIR (the sampler's own folder) and routes to the handler.
daemon_dispatch() {
    local action="$1" name="$2" label="$3" self="$4" dir="$5"
    local lock="${dir}/.${name}.lock"
    local pidf="${dir}/.${name}.pid"
    ensure_dir "$dir"
    case "$action" in
        start)   daemon_start  "$name" "$label" "$self" "$lock" "$pidf" ;;
        stop)    daemon_stop   "$name" "$label" "$lock" "$pidf" ;;
        restart) daemon_stop   "$name" "$label" "$lock" "$pidf" && \
                 daemon_start  "$name" "$label" "$self" "$lock" "$pidf" ;;
        status)  daemon_status "$name" "$label" "$lock" "$pidf" ;;
        *)       die "unknown action '$action' (use start|stop|restart|status)" ;;
    esac
}
