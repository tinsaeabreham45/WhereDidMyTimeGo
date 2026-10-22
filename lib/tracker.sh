# shellcheck shell=bash
#
# Tracker daemon and lifecycle commands for WhereDidMyTimeGo.
#
# One daemon owns the CSV writer, the KWin helper, the idle helper, and the
# session-bus monitor. Every boundary is an event in the log; reports derive
# durations from those events.

tracker_log() {
    local level=${1:-INFO}
    shift || true
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

tracker_start_monitor() {
    coproc WDMTG_MON {
        # Do not let the long-lived monitor keep the tracker lock after a crash.
        if [[ -n ${WDMTG_LOCK_FD:-} ]]; then
            exec {WDMTG_LOCK_FD}>&-
        fi
        exec busctl --user monitor --json=short \
            --match="type='method_call',interface='$WDMTG_INTERFACE'" \
            --match="type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'" \
            2>>"$WDMTG_DAEMON_LOG"
    }

    # Give busctl time to subscribe before the KWin helper emits its first
    # event. If it is still missed, tracker_loop reloads the helper.
    sleep 0.5

    if ! kill -0 "$WDMTG_MON_PID" 2>/dev/null; then
        tracker_log ERROR "busctl monitor exited during startup"
        return 1
    fi
    return 0
}

tracker_stop_monitor() {
    if [[ -n ${WDMTG_MON_PID:-} ]] && kill -0 "$WDMTG_MON_PID" 2>/dev/null; then
        kill -TERM "$WDMTG_MON_PID" 2>/dev/null || true
        wait "$WDMTG_MON_PID" 2>/dev/null || true
    fi
    WDMTG_MON_PID=""
}

tracker_write_event_at() {
    local epoch=${1:?epoch required}
    local event=${2:?event required}
    local app_id=${3-}
    local app_class=${4-}
    local desktop_file=${5-}
    local pid=${6:-0}
    local source=${7:-system}

    append_event_at "$epoch" "$event" "$app_id" "$app_class" "$desktop_file" \
        "$pid" "$source" "$WDMTG_RUN_ID" || {
        tracker_log ERROR "could not append '$event' event"
        state_set status error
        state_set message "log write failed"
        exit "$EX_SOFTWARE"
    }
    state_set last_event "$epoch"
    state_set log_file "$WDMTG_LAST_LOG"
    return 0
}

tracker_write_event() {
    local epoch

    epoch=$(now_epoch) || return 1
    tracker_write_event_at "$epoch" "$@"
}

tracker_clear_current() {
    WDMTG_CURRENT_APP=""
    WDMTG_CURRENT_SINCE=""
    state_set current_app ""
    state_set current_since ""
}

tracker_cancel_pending_none() {
    WDMTG_PENDING_NONE=0
    WDMTG_PENDING_NONE_AT=""
}

# KWin emits windowActivated(nullptr) while moving focus between windows.
# Queue the event and commit it only if no activation follows during the
# debounce interval.
tracker_queue_none() {
    if [[ -z ${WDMTG_CURRENT_APP:-} ]]; then
        return 0
    fi
    if [[ ${WDMTG_PENDING_NONE:-0} == 1 ]]; then
        return 0
    fi

    WDMTG_PENDING_NONE=1
    if ! WDMTG_PENDING_NONE_AT=$(now_millis); then
        WDMTG_PENDING_NONE_AT=0
    fi
    return 0
}

tracker_flush_pending_none() {
    local now=${1-}
    local debounce=${WDMTG_NONE_DEBOUNCE_MS:-500}
    local queued_at=${WDMTG_PENDING_NONE_AT:-0}

    [[ ${WDMTG_PENDING_NONE:-0} == 1 ]] || return 0
    [[ $queued_at =~ ^[0-9]+$ ]] || queued_at=0

    if [[ -z $now ]]; then
        if ! now=$(now_millis); then
            now=$((queued_at + debounce))
        fi
    fi
    if ((now - queued_at < debounce)); then
        return 0
    fi

    tracker_write_event none "" "" "" 0 kwin
    tracker_cancel_pending_none
    tracker_clear_current
    return 0
}

tracker_context_blocked() {
    [[ ${WDMTG_PAUSED:-0} == 1 ]] && return 0
    [[ ${WDMTG_LOCKED:-0} == 1 ]] && return 0
    [[ ${WDMTG_IDLE:-0} == 1 ]] && return 0
    return 1
}

tracker_handle_active() {
    local event=${1-}
    local app_class=${2-}
    local app_name=${3-}
    local desktop_file=${4-}
    local pid
    local app_id
    local now

    pid=$(normalize_pid "${5-0}")

    if [[ $event == "none" ]]; then
        tracker_context_blocked && return 0
        tracker_queue_none
        return 0
    fi
    [[ $event == "active" ]] || return 0

    app_id=$(normalize_app_id "$desktop_file" "$app_class" "$app_name" "$pid")
    [[ -n $app_id ]] || app_id="unknown"
    WDMTG_LAST_SEEN_APP=$app_id
    state_set last_seen_app "$app_id"

    # While paused, idle, or locked we remember the last window but do not
    # create usage. The resume path reloads the helper to get a fresh window.
    if tracker_context_blocked; then
        return 0
    fi

    tracker_cancel_pending_none

    if app_is_excluded "$app_id"; then
        if [[ ${WDMTG_EXCLUDED_APP:-} != "$app_id" || -n ${WDMTG_CURRENT_APP:-} ]]; then
            tracker_write_event excluded "$app_id" "$app_class" "$desktop_file" "$pid" kwin
        fi
        tracker_clear_current
        WDMTG_EXCLUDED_APP=$app_id
        state_set excluded_app "$app_id"
        return 0
    fi

    WDMTG_EXCLUDED_APP=""
    state_set excluded_app ""

    # Switching between two windows of the same application does not change
    # application usage.
    if [[ ${WDMTG_CURRENT_APP:-} == "$app_id" ]]; then
        return 0
    fi

    now=$(now_epoch)
    tracker_write_event_at "$now" app "$app_id" "$app_class" "$desktop_file" "$pid" kwin
    WDMTG_CURRENT_APP=$app_id
    WDMTG_CURRENT_SINCE=$now
    state_set current_app "$app_id"
    state_set current_since "$now"
    return 0
}

tracker_handle_lock() {
    [[ ${WDMTG_LOCKED:-0} == 1 ]] && return 0

    tracker_cancel_pending_none
    WDMTG_LOCKED=1
    state_set locked 1
    WDMTG_EXCLUDED_APP=""
    state_set excluded_app ""

    tracker_write_event lock "" "" "" 0 dbus
    if [[ -n ${WDMTG_CURRENT_APP:-} ]]; then
        tracker_clear_current
    fi
    tracker_log INFO "screen locked; usage paused"
    return 0
}

tracker_handle_unlock() {
    [[ ${WDMTG_LOCKED:-0} == 1 ]] || return 0

    WDMTG_LOCKED=0
    state_set locked 0
    tracker_write_event unlock "" "" "" 0 dbus
    tracker_log INFO "screen unlocked"

    if [[ ${WDMTG_PAUSED:-0} == 0 && ${WDMTG_IDLE:-0} == 0 ]]; then
        tracker_reload_detector || true
    fi
    return 0
}

tracker_handle_idle_event() {
    local event=${1-}

    case "$event" in
        idle)
            [[ ${WDMTG_IDLE:-0} == 1 ]] && return 0
            WDMTG_IDLE=1
            state_set idle 1
            if [[ ${WDMTG_PAUSED:-0} == 0 && ${WDMTG_LOCKED:-0} == 0 ]]; then
                tracker_cancel_pending_none
                tracker_write_event idle "" "" "" 0 idle
                tracker_clear_current
                tracker_log INFO "user idle; usage paused"
            fi
            ;;
        active)
            [[ ${WDMTG_IDLE:-0} == 0 ]] && return 0
            WDMTG_IDLE=0
            state_set idle 0
            if [[ ${WDMTG_PAUSED:-0} == 0 && ${WDMTG_LOCKED:-0} == 0 ]]; then
                tracker_write_event active "" "" "" 0 idle
                tracker_reload_detector || true
                tracker_log INFO "user active again"
            fi
            ;;
    esac
    return 0
}

tracker_handle_pause_change() {
    local wanted=0

    [[ -f $WDMTG_PAUSE_FILE ]] && wanted=1
    [[ ${WDMTG_PAUSED:-0} == "$wanted" ]] && return 0

    if ((wanted == 1)); then
        tracker_cancel_pending_none
        tracker_write_event pause "" "" "" 0 cli
        tracker_clear_current
        WDMTG_PAUSED=1
        state_set paused 1
        tracker_log INFO "tracking paused"
    else
        tracker_write_event unpause "" "" "" 0 cli
        WDMTG_PAUSED=0
        state_set paused 0
        tracker_log INFO "tracking resumed"
        if [[ ${WDMTG_LOCKED:-0} == 0 && ${WDMTG_IDLE:-0} == 0 ]]; then
            tracker_reload_detector || true
        fi
    fi
    return 0
}

tracker_sleep_gap_detected() {
    local wall_delta=${1:-0}
    local monotonic_delta=${2:-0}
    local threshold=${3:-5}

    [[ $wall_delta =~ ^-?[0-9]+$ ]] || return 1
    [[ $monotonic_delta =~ ^-?[0-9]+$ ]] || return 1
    ((wall_delta - monotonic_delta >= threshold))
}

tracker_handle_suspend() {
    local last_wall=${1:?last wall time required}
    local now=${2:?now required}

    tracker_log WARN "suspend or clock gap detected; closing the interval at $last_wall"
    tracker_cancel_pending_none
    tracker_write_event_at "$last_wall" sleep "" "" "" 0 system
    tracker_write_event_at "$now" wake "" "" "" 0 system
    tracker_clear_current

    if [[ ${WDMTG_PAUSED:-0} == 0 && ${WDMTG_LOCKED:-0} == 0 && ${WDMTG_IDLE:-0} == 0 ]]; then
        tracker_reload_detector || true
    fi
    return 0
}

tracker_reload_detector() {
    if detector_reload; then
        state_set detector loaded
        return 0
    fi
    state_set detector error
    state_set message "KWin helper reload failed"
    tracker_log ERROR "KWin helper reload failed"

    # We no longer know which window is focused. Close the open interval now
    # rather than attributing the detector gap to the last application.
    if [[ -n ${WDMTG_CURRENT_APP:-} ]]; then
        tracker_write_event none "" "" "" 0 system
        tracker_clear_current
    fi
    return 1
}

tracker_cleanup() {
    local status=${1:-0}

    if [[ ${WDMTG_CLEANING:-0} == 1 ]]; then
        return 0
    fi
    WDMTG_CLEANING=1

    trap - EXIT INT TERM HUP USR1 USR2
    set +e

    tracker_log INFO "cleanup requested (exit status $status)"

    if [[ ${WDMTG_LOG_READY:-0} == 1 ]]; then
        append_event stop "" "" "" 0 cli "$WDMTG_RUN_ID"
        state_set stopped_at "$(now_iso)"
        state_set last_exit "$status"
        state_set status stopped
    fi

    detector_stop
    idle_stop
    tracker_stop_monitor
    rm -f -- "$WDMTG_PID_FILE" "$WDMTG_READY_FILE" "$WDMTG_PAUSE_FILE"
    if [[ ${WDMTG_LOG_READY:-0} != 1 ]]; then
        state_set status stopped
        state_set stopped_at "$(now_iso)"
    fi
    state_set detector "stopped"
    state_set paused 0
    state_set idle 0
    state_set locked 0
    state_set idle_pid ""
    tracker_log INFO "cleanup complete"
    return 0
}

tracker_loop() {
    local raw fields
    local event app_class app_name desktop_file pid
    local now wall monotonic wall_delta mono_delta
    local last_check initial_deadline last_idle_check last_alert_check
    local initial_retries=0
    local got_event=0
    local rc
    local queued

    printf -v now '%(%s)T' -1
    wall=$now
    monotonic=$(monotonic_seconds 2>/dev/null || printf '0')
    last_check=$now
    last_idle_check=$now
    last_alert_check=0
    initial_deadline=$((now + 3))

    while :; do
        wall=$(now_epoch)
        monotonic=$(monotonic_seconds 2>/dev/null || printf '0')
        if ((monotonic > 0)); then
            wall_delta=$((wall - WDMTG_LAST_WALL))
            mono_delta=$((monotonic - WDMTG_LAST_MONOTONIC))
            if tracker_sleep_gap_detected "$wall_delta" "$mono_delta" "$WDMTG_CFG_SLEEP_GAP"; then
                tracker_handle_suspend "$WDMTG_LAST_WALL" "$wall"
            fi
            WDMTG_LAST_WALL=$wall
            WDMTG_LAST_MONOTONIC=$monotonic
        fi

        tracker_handle_pause_change

        # Idle helper signals are queued so a fast idle/resume pair is not lost.
        while ((${#WDMTG_IDLE_QUEUE[@]} > 0)); do
            queued=${WDMTG_IDLE_QUEUE[0]}
            WDMTG_IDLE_QUEUE=("${WDMTG_IDLE_QUEUE[@]:1}")
            tracker_handle_idle_event "$queued"
        done

        # A short timeout lets us commit a queued "none" event promptly.
        if IFS= read -r -t 0.25 -u "${WDMTG_MON[0]}" raw; then
            if fields=$(parse_monitor_line "$raw" "$WDMTG_RUN_ID"); then
                IFS=$'\t' read -r event app_class app_name desktop_file pid <<<"$fields"
                case "$event" in
                    active | none)
                        tracker_handle_active "$event" "$app_class" "$app_name" "$desktop_file" "$pid"
                        ;;
                    lock)
                        tracker_handle_lock
                        ;;
                    unlock)
                        tracker_handle_unlock
                        ;;
                esac
                got_event=1
            fi
        else
            rc=$?
            # 128+ means the read timed out, which is expected. EOF or a real
            # error means the monitor died and we must stop claiming to track.
            if ((rc <= 128)); then
                tracker_log ERROR "D-Bus monitor ended unexpectedly"
                state_set status error
                state_set message "D-Bus monitor ended"
                exit "$EX_SOFTWARE"
            fi
        fi

        tracker_flush_pending_none

        printf -v now '%(%s)T' -1

        if ((got_event == 0 && now >= initial_deadline)); then
            if ((initial_retries >= 3)); then
                tracker_log ERROR "no window events after repeated helper reloads"
                state_set detector degraded
                state_set message "no window events"
                initial_deadline=$((now + 3600))
            else
                tracker_log WARN "no initial window event; reloading KWin helper"
                if ! tracker_reload_detector; then
                    state_set detector error
                    state_set message "KWin helper reload failed"
                    exit "$EX_UNAVAILABLE"
                fi
                initial_retries=$((initial_retries + 1))
                initial_deadline=$((now + 5))
            fi
        fi

        # KWin restarts discard loaded scripts.
        if ((now - last_check >= 30)); then
            if ! kwin_script_loaded; then
                tracker_log WARN "KWin helper is no longer loaded; reloading"
                tracker_reload_detector || true
            fi
            last_check=$now
        fi

        # The idle helper is optional. If it dies, try one restart and fall
        # back to active-only tracking rather than leaving the daemon stuck.
        if ((now - last_idle_check >= 30)); then
            if [[ ${WDMTG_IDLE_AVAILABLE:-0} == 1 && -n ${WDMTG_IDLE_PID:-} ]] &&
                ! kill -0 "$WDMTG_IDLE_PID" 2>/dev/null; then
                tracker_log WARN "idle helper exited; restarting"
                WDMTG_IDLE_PID=""
                if idle_start; then
                    state_set idle_pid "$WDMTG_IDLE_PID"
                    state_set idle_available available
                else
                    WDMTG_IDLE_AVAILABLE=0
                    state_set idle_available unavailable
                    tracker_log WARN "idle helper could not be restarted; idle time will now be counted"
                    if [[ ${WDMTG_IDLE:-0} == 1 ]]; then
                        WDMTG_IDLE=0
                        state_set idle 0
                        tracker_reload_detector || true
                    fi
                fi
            fi
            last_idle_check=$now
        fi

        if ((now - last_alert_check >= 30)); then
            alerts_check || true
            last_alert_check=$now
        fi
    done
}

tracker_run() {
    set -Eeuo pipefail

    WDMTG_CLEANING=0
    WDMTG_LOG_READY=0
    WDMTG_SCRIPT_LOADED=0
    WDMTG_SCRIPT_ID=""
    WDMTG_MON_PID=""
    WDMTG_IDLE_PID=""
    WDMTG_CURRENT_APP=""
    WDMTG_CURRENT_SINCE=""
    WDMTG_PENDING_NONE=0
    WDMTG_PENDING_NONE_AT=""
    WDMTG_PAUSED=0
    WDMTG_LOCKED=0
    WDMTG_IDLE=0
    WDMTG_IDLE_AVAILABLE=0
    WDMTG_IDLE_QUEUE=()
    WDMTG_LAST_SEEN_APP=""
    WDMTG_EXCLUDED_APP=""

    wdmtg_init_paths
    wdmtg_ensure_dirs || exit "$EX_NOPERM"
    config_load

    exec {WDMTG_LOCK_FD}>"$WDMTG_LOCK_FILE" || exit "$EX_NOPERM"
    if ! flock -n "$WDMTG_LOCK_FD"; then
        tracker_log ERROR "another tracker instance already holds $WDMTG_LOCK_FILE"
        exit "$EX_TEMPFAIL"
    fi

    WDMTG_RUN_ID="$(now_epoch)-$$"
    WDMTG_LAST_WALL=$(now_epoch)
    WDMTG_LAST_MONOTONIC=$(monotonic_seconds 2>/dev/null || printf '0')

    trap 'tracker_cleanup $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap 'WDMTG_IDLE_QUEUE+=(idle)' USR1
    trap 'WDMTG_IDLE_QUEUE+=(active)' USR2

    write_pid_file || exit "$EX_NOPERM"

    state_set pid "$$"
    state_set run_id "$WDMTG_RUN_ID"
    state_set status starting
    state_set started_at "$(now_iso)"
    state_set current_app ""
    state_set current_since ""
    state_set detector starting
    state_set message ""
    state_set monitor_pid ""
    state_set paused 0
    state_set idle 0
    state_set idle_available unknown
    state_set locked 0
    state_set excluded_app ""
    state_set last_seen_app ""

    append_event start "" "" "" 0 cli "$WDMTG_RUN_ID" || {
        tracker_log ERROR "could not write the start event"
        state_set status error
        state_set message "log write failed"
        exit "$EX_NOPERM"
    }
    WDMTG_LOG_READY=1
    state_set log_file "$WDMTG_LAST_LOG"

    if ! tracker_start_monitor; then
        state_set status error
        state_set message "D-Bus monitor failed to start"
        exit "$EX_UNAVAILABLE"
    fi
    state_set monitor_pid "$WDMTG_MON_PID"

    if ((WDMTG_CFG_IDLE_TIMEOUT == 0)); then
        state_set idle_available disabled
        tracker_log INFO "idle detection disabled by configuration"
    elif ensure_idle_helper; then
        if idle_start; then
            WDMTG_IDLE_AVAILABLE=1
            state_set idle_available available
            state_set idle_pid "$WDMTG_IDLE_PID"
        else
            state_set idle_available unavailable
            tracker_log WARN "idle helper could not start; idle time will be counted"
        fi
    else
        state_set idle_available unavailable
        tracker_log WARN "idle helper unavailable; idle time will be counted"
    fi

    # Query the lock state once so a daemon started on a locked screen does
    # not record the lock screen as application usage.
    if qdbus6 org.freedesktop.ScreenSaver /ScreenSaver \
        org.freedesktop.ScreenSaver.GetActive 2>/dev/null | grep -qx 'true'; then
        WDMTG_LOCKED=1
        state_set locked 1
        tracker_write_event lock "" "" "" 0 dbus
    fi

    if ! detector_load; then
        state_set detector error
        state_set message "KWin detector failed"
        exit "$EX_UNAVAILABLE"
    fi
    state_set detector loaded
    state_set status running

    rm -f -- "$WDMTG_READY_FILE"
    printf '%s\n' "$$" >"$WDMTG_READY_FILE.tmp.$$" || exit "$EX_NOPERM"
    mv -f -- "$WDMTG_READY_FILE.tmp.$$" "$WDMTG_READY_FILE" || exit "$EX_NOPERM"

    tracker_log INFO "tracking started (run $WDMTG_RUN_ID)"
    tracker_loop
}

cmd_start() {
    local lock_state=0
    local pid=""
    local ready_pid=""
    local current_app=""
    local log_file=""
    local daemon_pid=""
    local i j
    local paused="" idle="" locked="" excluded="" last_seen=""

    wdmtg_init_paths
    wdmtg_ensure_dirs || die "$EX_NOPERM" "cannot create state/data directories"

    if ! require_commands busctl jq qdbus6 flock date awk sort sed tr nohup mktemp; then
        die "$EX_UNAVAILABLE" "install the missing tools or run 'detective.sh --help'"
    fi

    tracker_is_locked || lock_state=$?
    case "$lock_state" in
        0) die "$EX_TEMPFAIL" "another tracker instance is already running" ;;
        2) die "$EX_NOPERM" "cannot inspect the tracker lock: $WDMTG_LOCK_FILE" ;;
    esac

    if ! kwin_available; then
        die "$EX_UNAVAILABLE" "KWin is not available; this application requires KDE Plasma 6 on Wayland"
    fi

    config_load
    if ((WDMTG_CFG_IDLE_TIMEOUT > 0)); then
        if ! ensure_idle_helper; then
            warn "idle detection will be unavailable; tracking can still start"
        fi
    fi

    if pid=$(read_pid_file); then
        if is_pid_tracker "$pid"; then
            die "$EX_TEMPFAIL" "tracker process $pid exists but does not hold the lock; run 'detective.sh stop' first"
        fi
        rm -f -- "$WDMTG_PID_FILE"
    fi

    rm -f -- "$WDMTG_READY_FILE" "$WDMTG_PAUSE_FILE"
    printf '\n--- %s start requested ---\n' "$(now_iso)" >>"$WDMTG_DAEMON_LOG"

    WDMTG_INTERNAL=1 nohup "$WDMTG_ROOT_DIR/detective.sh" __tracker \
        </dev/null >>"$WDMTG_DAEMON_LOG" 2>&1 &
    daemon_pid=$!

    # Wait for the child to load the KWin helper and establish its state. If
    # it exits during startup, do not make the user wait for the full timeout.
    for ((i = 0; i < 150; i++)); do
        if [[ ! -f $WDMTG_READY_FILE ]] && ! kill -0 "$daemon_pid" 2>/dev/null; then
            break
        fi
        if [[ -f $WDMTG_READY_FILE ]]; then
            ready_pid=$(<"$WDMTG_READY_FILE") || ready_pid=""
            if [[ $ready_pid =~ ^[0-9]+$ ]] && is_pid_tracker "$ready_pid"; then
                current_app=$(state_get current_app 2>/dev/null || true)
                log_file=$(state_get log_file 2>/dev/null || true)
                paused=$(state_get paused 2>/dev/null || true)
                idle=$(state_get idle 2>/dev/null || true)
                locked=$(state_get locked 2>/dev/null || true)
                excluded=$(state_get excluded_app 2>/dev/null || true)
                last_seen=$(state_get last_seen_app 2>/dev/null || true)

                # The daemon writes the ready file just before KWin's first
                # callback arrives. Give that callback a short moment so start
                # can print the real application instead of a race-dependent
                # "waiting" message.
                for ((j = 0; j < 10; j++)); do
                    [[ -n $current_app || -n $excluded ]] && break
                    [[ $paused == 1 || $idle == 1 || $locked == 1 ]] && break
                    sleep 0.1
                    current_app=$(state_get current_app 2>/dev/null || true)
                    excluded=$(state_get excluded_app 2>/dev/null || true)
                    paused=$(state_get paused 2>/dev/null || true)
                    idle=$(state_get idle 2>/dev/null || true)
                    locked=$(state_get locked 2>/dev/null || true)
                    last_seen=$(state_get last_seen_app 2>/dev/null || true)
                done

                printf 'Started %s (PID %s).\n' "$WDMTG_APP_NAME" "$ready_pid"
                if [[ $locked == 1 ]]; then
                    printf 'Current app: locked screen\n'
                elif [[ $paused == 1 ]]; then
                    printf 'Current app: tracking paused\n'
                elif [[ $idle == 1 ]]; then
                    printf 'Current app: idle\n'
                elif [[ -n $current_app ]]; then
                    printf 'Current app: %s\n' "$current_app"
                elif [[ -n $excluded ]]; then
                    printf 'Current app: %s (excluded)\n' "$excluded"
                elif [[ -n $last_seen ]]; then
                    printf 'Current app: %s (not counted)\n' "$last_seen"
                else
                    printf 'Current app: waiting for the first window event\n'
                fi
                printf 'Log: %s\n' "${log_file:-$WDMTG_DATA_DIR}"
                return 0
            fi
        fi
        sleep 0.1
    done

    print_log_tail
    die "$EX_SOFTWARE" "tracker did not become ready; see the log above"
}

cmd_stop() {
    local pid=""
    local lock_state=0
    local i
    local log_file=""

    wdmtg_init_paths

    if ! pid=$(read_pid_file); then
        tracker_is_locked || lock_state=$?
        if ((lock_state == 0)); then
            die "$EX_SOFTWARE" "tracker lock is held but no valid PID file exists; refusing to guess"
        fi
        printf '%s is not running.\n' "$WDMTG_APP_NAME"
        return 0
    fi

    if ! is_pid_tracker "$pid"; then
        rm -f -- "$WDMTG_PID_FILE" "$WDMTG_READY_FILE" "$WDMTG_PAUSE_FILE"
        state_set status stopped
        state_set message "removed stale PID file"
        printf '%s is not running (removed stale PID %s).\n' "$WDMTG_APP_NAME" "$pid"
        return 0
    fi

    log_file=$(state_get log_file 2>/dev/null || true)

    if ! kill -TERM "$pid" 2>/dev/null; then
        rm -f -- "$WDMTG_PID_FILE" "$WDMTG_READY_FILE" "$WDMTG_PAUSE_FILE"
        state_set status stopped
        printf '%s is not running (process %s was already gone).\n' "$WDMTG_APP_NAME" "$pid"
        return 0
    fi

    for ((i = 0; i < 100; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f -- "$WDMTG_PID_FILE" "$WDMTG_READY_FILE" "$WDMTG_PAUSE_FILE"
            state_set status stopped
            state_set stopped_at "$(now_iso)"
            printf 'Stopped %s (PID %s).\n' "$WDMTG_APP_NAME" "$pid"
            if [[ -n $log_file ]]; then
                printf 'Log retained: %s\n' "$log_file"
            fi
            return 0
        fi
        sleep 0.1
    done

    die "$EX_SOFTWARE" "process $pid did not stop after 10 seconds; it was not force-killed"
}

cmd_pause() {
    local pid="" i

    wdmtg_init_paths

    if ! pid=$(tracker_running_pid); then
        die "$EX_STOPPED" "tracker is not running"
    fi

    if [[ -f $WDMTG_PAUSE_FILE ]]; then
        printf 'Tracking is already paused.\n'
        return 0
    fi

    printf '%s\n' "$(now_epoch)" >"$WDMTG_PAUSE_FILE" || die "$EX_NOPERM" "cannot create $WDMTG_PAUSE_FILE"
    chmod 600 -- "$WDMTG_PAUSE_FILE" 2>/dev/null || true

    for ((i = 0; i < 30; i++)); do
        [[ $(state_get paused 2>/dev/null || true) == 1 ]] && break
        sleep 0.1
    done
    printf 'Tracking paused. Foreground changes will not be recorded until resume.\n'
    return 0
}

cmd_resume() {
    local pid="" i

    wdmtg_init_paths

    if ! pid=$(tracker_running_pid); then
        die "$EX_STOPPED" "tracker is not running"
    fi

    if [[ ! -f $WDMTG_PAUSE_FILE ]]; then
        printf 'Tracking is not paused.\n'
        return 0
    fi

    rm -f -- "$WDMTG_PAUSE_FILE"
    for ((i = 0; i < 30; i++)); do
        [[ $(state_get paused 2>/dev/null || true) == 0 ]] && break
        sleep 0.1
    done
    printf 'Tracking resumed.\n'
    return 0
}

cmd_status() {
    local pid=""
    local running=0
    local status="" run_id="" started_at="" current_app=""
    local current_since="" last_event="" log_file="" detector="" monitor_pid=""
    local paused="" idle="" idle_available="" locked="" excluded="" last_seen="" idle_pid=""
    local events_today=0 tracked_today=0
    local app_display=""

    wdmtg_init_paths
    config_load

    if pid=$(tracker_running_pid); then
        running=1
    fi

    printf '%s %s\n' "$WDMTG_APP_NAME" "$WDMTG_VERSION"

    if ((running == 1)); then
        status=$(state_get status 2>/dev/null || true)
        run_id=$(state_get run_id 2>/dev/null || true)
        started_at=$(state_get started_at 2>/dev/null || true)
        current_app=$(state_get current_app 2>/dev/null || true)
        current_since=$(state_get current_since 2>/dev/null || true)
        last_event=$(state_get last_event 2>/dev/null || true)
        log_file=$(state_get log_file 2>/dev/null || true)
        detector=$(state_get detector 2>/dev/null || true)
        monitor_pid=$(state_get monitor_pid 2>/dev/null || true)
        paused=$(state_get paused 2>/dev/null || true)
        idle=$(state_get idle 2>/dev/null || true)
        idle_available=$(state_get idle_available 2>/dev/null || true)
        locked=$(state_get locked 2>/dev/null || true)
        excluded=$(state_get excluded_app 2>/dev/null || true)
        last_seen=$(state_get last_seen_app 2>/dev/null || true)
        idle_pid=$(state_get idle_pid 2>/dev/null || true)

        if [[ $locked == 1 ]]; then
            app_display="locked screen"
        elif [[ $paused == 1 ]]; then
            app_display="paused"
        elif [[ $idle == 1 ]]; then
            app_display="idle (not counted)"
        elif [[ -n $current_app ]]; then
            app_display=$current_app
        elif [[ -n $excluded ]]; then
            app_display="$excluded (excluded)"
        elif [[ -n $last_seen ]]; then
            app_display="$last_seen (not counted)"
        else
            app_display="none/unknown"
        fi

        printf 'Status: running (PID %s)\n' "$pid"
        printf 'Run: %s\n' "${run_id:-unknown}"
        printf 'Started: %s\n' "${started_at:-unknown}"
        printf 'Current app: %s\n' "$app_display"
        if [[ $current_since =~ ^[0-9]+$ ]] && [[ $locked != 1 && $paused != 1 && $idle != 1 ]]; then
            printf 'Current app since: %s\n' "$(format_epoch_iso "$current_since")"
        fi
        printf 'Last event: %s\n' "${last_event:-none yet}"
        printf 'Log: %s\n' "${log_file:-not created yet}"
        printf 'KWin detector: %s\n' "${detector:-unknown}"
        if [[ -n $monitor_pid ]] && kill -0 "$monitor_pid" 2>/dev/null; then
            printf 'D-Bus monitor: running (PID %s)\n' "$monitor_pid"
        else
            printf 'D-Bus monitor: not running\n'
        fi
        case "$idle_available" in
            available)
                if [[ -n $idle_pid ]] && kill -0 "$idle_pid" 2>/dev/null; then
                    printf 'Idle detection: active (helper PID %s, timeout %s)\n' \
                        "$idle_pid" "$(human_duration "$WDMTG_CFG_IDLE_TIMEOUT")"
                else
                    printf 'Idle detection: helper not running\n'
                fi
                ;;
            unavailable) printf 'Idle detection: unavailable\n' ;;
            disabled) printf 'Idle detection: disabled by configuration\n' ;;
            *) printf 'Idle detection: %s\n' "${idle_available:-unknown}" ;;
        esac
        if [[ -n $log_file && -f $log_file ]]; then
            events_today=$(count_events_today "$log_file" 2>/dev/null || printf '0')
        fi
        tracked_today=$(report_today_seconds 2>/dev/null || printf '0')
        printf 'Tracked today: %s (measured application time)\n' "$(human_duration "$tracked_today")"
        printf 'App changes today: %s\n' "$events_today"
        return 0
    fi

    printf 'Status: stopped\n'
    if [[ -f $WDMTG_PID_FILE ]]; then
        printf 'PID file: stale (%s); run stop to clean it up\n' "$WDMTG_PID_FILE"
    fi
    if [[ -f $WDMTG_STATE_FILE ]]; then
        current_app=$(state_get current_app 2>/dev/null || true)
        log_file=$(state_get log_file 2>/dev/null || true)
        detector=$(state_get detector 2>/dev/null || true)
        last_seen=$(state_get last_seen_app 2>/dev/null || true)
        printf 'Last app: %s\n' "${current_app:-${last_seen:-none/unknown}}"
        printf 'Last log: %s\n' "${log_file:-not created yet}"
        printf 'Last detector state: %s\n' "${detector:-unknown}"
    fi
    tracked_today=$(report_today_seconds 2>/dev/null || printf '0')
    printf 'Tracked today: %s\n' "$(human_duration "$tracked_today")"
    return "$EX_STOPPED"
}
