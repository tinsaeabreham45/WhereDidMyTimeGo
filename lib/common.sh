# shellcheck shell=bash
#
# Shared constants and helpers for WhereDidMyTimeGo.
# This file is sourced by detective.sh and by the test harness. It deliberately
# does not call `set -e`; the entry point decides which shell options to use.

readonly WDMTG_APP_NAME="WhereDidMyTimeGo"
readonly WDMTG_VERSION="1.0.0"
readonly WDMTG_SERVICE="org.wheredidmytimego.Tracker"
readonly WDMTG_OBJECT="/org/wheredidmytimego/Tracker"
readonly WDMTG_INTERFACE="org.wheredidmytimego.Tracker"
readonly WDMTG_KWIN_PLUGIN="wheredidmytimego"
readonly WDMTG_CSV_HEADER="epoch,iso8601,event,app_id,app_class,desktop_file,pid,source,run_id"

# Exit codes. These are conventional sysexits(3) values where possible.
readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_TEMPFAIL=75
readonly EX_NOPERM=77
readonly EX_CONFIG=78
readonly EX_STOPPED=3

die() {
    local code=${1:-$EX_SOFTWARE}
    shift || true
    printf '%s: error: %s\n' "$WDMTG_APP_NAME" "$*" >&2
    exit "$code"
}

warn() {
    printf '%s: warning: %s\n' "$WDMTG_APP_NAME" "$*" >&2
}

now_epoch() {
    printf '%(%s)T' -1
}

now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

# Milliseconds since the epoch. Used only for sub-second debouncing, so it
# does not need to be perfectly monotonic. The decimal separator can vary by
# locale, hence the removal of both '.' and ','.
now_millis() {
    local value=${EPOCHREALTIME:-}

    value=${value//[.,]/}
    [[ $value =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$((value / 1000))"
}

# Monotonic seconds from /proc/uptime. Comparing this with wall-clock time
# lets the daemon detect suspend/hibernate without a logind dependency.
monotonic_seconds() {
    local up ignored

    IFS=' ' read -r up ignored </proc/uptime || return 1
    up=${up%%.*}
    [[ $up =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$up"
}

# Human-readable duration for status and notifications: 2h 05m, 12m 30s.
human_duration() {
    local total=${1:-0}
    local hours minutes seconds

    [[ $total =~ ^[0-9]+$ ]] || total=0
    hours=$((total / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))

    if ((hours > 0)); then
        printf '%dh %02dm' "$hours" "$minutes"
    elif ((minutes > 0)); then
        printf '%dm %02ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

# Accept only a real ISO calendar date. date(1) normalizes impossible dates
# (2026-02-30 becomes March 2), so compare the canonical result.
valid_date() {
    local value=${1-}
    local canonical

    [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    canonical=$(date -d "$value 00:00:00" '+%F' 2>/dev/null) || return 1
    [[ $canonical == "$value" ]]
}

day_start_epoch() {
    local value=${1:?date required}
    date -d "$value 00:00:00" '+%s'
}

day_end_epoch() {
    local value=${1:?date required}
    date -d "$value 00:00:00 +1 day" '+%s'
}

format_epoch_iso() {
    local epoch=${1:-0}
    date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf '%s' "$epoch"
}

command_exists() {
    command -v -- "$1" >/dev/null 2>&1
}

# require_commands NAME... -> prints all missing commands and returns 1.
require_commands() {
    local -a missing=()
    local cmd

    for cmd in "$@"; do
        command_exists "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} > 0)); then
        printf '%s: missing required command(s): %s\n' \
            "$WDMTG_APP_NAME" "${missing[*]}" >&2
        return 1
    fi
    return 0
}

# Resolve XDG paths and allow tests or advanced users to override them.
# Must be called before any function that touches storage.
wdmtg_init_paths() {
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
    local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    local runtime_root="${XDG_RUNTIME_DIR:-}"

    if [[ -z $runtime_root ]]; then
        runtime_root="${TMPDIR:-/tmp}/wheredidmytimego-$(id -u)"
    fi

    WDMTG_DATA_DIR="${WDMTG_DATA_DIR:-$data_home/wheredidmytimego}"
    WDMTG_STATE_DIR="${WDMTG_STATE_DIR:-$state_home/wheredidmytimego}"
    WDMTG_CONFIG_DIR="${WDMTG_CONFIG_DIR:-$config_home/wheredidmytimego}"
    WDMTG_RUNTIME_DIR="${WDMTG_RUNTIME_DIR:-$runtime_root/wheredidmytimego}"

    WDMTG_CONFIG_FILE="$WDMTG_CONFIG_DIR/config"
    WDMTG_DAEMON_LOG="$WDMTG_STATE_DIR/tracker.log"
    WDMTG_LOCK_FILE="$WDMTG_STATE_DIR/tracker.lock"
    WDMTG_PID_FILE="$WDMTG_STATE_DIR/tracker.pid"
    WDMTG_READY_FILE="$WDMTG_STATE_DIR/tracker.ready"
    WDMTG_STATE_FILE="$WDMTG_STATE_DIR/state"
    WDMTG_SCRIPT_FILE="$WDMTG_RUNTIME_DIR/kwin-agent.js"
    WDMTG_PAUSE_FILE="$WDMTG_RUNTIME_DIR/paused"
    WDMTG_LIBEXEC_DIR="$WDMTG_DATA_DIR/libexec"
    WDMTG_LAST_LOG=""
}

wdmtg_ensure_dirs() {
    local dir

    for dir in "$WDMTG_DATA_DIR" "$WDMTG_STATE_DIR" "$WDMTG_CONFIG_DIR" "$WDMTG_RUNTIME_DIR"; do
        if ! mkdir -p -- "$dir"; then
            printf '%s: cannot create directory: %s\n' "$WDMTG_APP_NAME" "$dir" >&2
            return 1
        fi
        if ! chmod 700 -- "$dir"; then
            printf '%s: cannot restrict permissions on: %s\n' "$WDMTG_APP_NAME" "$dir" >&2
            return 1
        fi
    done
    return 0
}

sanitize_csv_field() {
    local value=${1-}

    # We do not store window titles, so commas and newlines are the only
    # realistic CSV hazards. Replace them instead of introducing a fragile
    # Bash CSV parser. Control characters are removed too.
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//,/;}
    value=${value//$'\t'/ }
    value=${value//[[:cntrl:]]/}
    printf '%s' "$value"
}

normalize_pid() {
    local pid=${1-}

    if [[ $pid =~ ^[0-9]+$ ]]; then
        printf '%s' "$pid"
    else
        printf '0'
    fi
}

# Prefer the desktop file, then the window class, then the process name.
# The process name is used only as a fallback; it is not proof of focus.
# KWin occasionally supplies a numeric window id in desktopFileName (Telegram
# does this on some versions), so numeric candidates are rejected.
normalize_app_id() {
    local desktop_file=${1-}
    local app_class=${2-}
    local app_name=${3-}
    local pid
    local app_id=""
    local candidate

    pid=$(normalize_pid "${4-}")

    if [[ -n $desktop_file ]]; then
        candidate=${desktop_file,,}
        candidate=${candidate%.desktop}
        candidate=${candidate// /_}
        if [[ -n $candidate && ! $candidate =~ ^[0-9]+$ ]]; then
            app_id=$candidate
        fi
    fi
    if [[ -z $app_id && -n $app_class ]]; then
        # A resource class is already an identifier. Do not strip a trailing
        # ".desktop" here: for Flatpak applications such as Telegram that
        # suffix is part of the ID (org.telegram.desktop).
        app_id=$app_class
    fi
    if [[ -z $app_id && -n $app_name ]]; then
        app_id=$app_name
    fi

    app_id=${app_id,,}
    app_id=${app_id// /_}

    if [[ -z $app_id || $app_id =~ ^[0-9]+$ ]]; then
        if [[ $pid != 0 && -r /proc/$pid/comm ]]; then
            app_id=$(<"/proc/$pid/comm") || app_id=""
        else
            app_id=""
        fi
    fi

    [[ -n $app_id ]] || app_id="unknown"
    app_id=${app_id,,}
    app_id=${app_id// /_}
    sanitize_csv_field "$app_id"
}

log_file_for_epoch() {
    local epoch=${1:-$(now_epoch)}
    local month

    month=$(date -d "@$epoch" '+%Y-%m') || return 1
    printf '%s/events-%s.csv\n' "$WDMTG_DATA_DIR" "$month"
}

ensure_log_header() {
    local file=${1:?log file required}

    if [[ ! -e $file ]]; then
        : >"$file" || return 1
        chmod 600 -- "$file" || return 1
    fi

    if [[ ! -s $file ]]; then
        printf '%s\n' "$WDMTG_CSV_HEADER" >>"$file" || return 1
    fi
    return 0
}

# append_event EVENT APP_ID APP_CLASS DESKTOP_FILE PID SOURCE RUN_ID
# The timestamp is taken once, so one line has one coherent time.
append_event() {
    local epoch

    epoch=$(now_epoch) || return 1
    append_event_at "$epoch" "$@"
}

# append_event_at EPOCH EVENT APP_ID APP_CLASS DESKTOP_FILE PID SOURCE RUN_ID
# Used for events reconstructed after a suspend gap, where the closing
# timestamp is earlier than "now".
append_event_at() {
    local epoch=${1-}
    local event=${2-}
    local app_id=${3-}
    local app_class=${4-}
    local desktop_file=${5-}
    local pid
    local source=${7:-cli}
    local run_id=${8-}
    local iso file line

    [[ $epoch =~ ^[0-9]+$ ]] || return 1
    pid=$(normalize_pid "${6-0}")
    iso=$(date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z') || return 1
    file=$(log_file_for_epoch "$epoch") || return 1

    ensure_log_header "$file" || return 1

    line=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s' \
        "$epoch" \
        "$iso" \
        "$(sanitize_csv_field "$event")" \
        "$(sanitize_csv_field "$app_id")" \
        "$(sanitize_csv_field "$app_class")" \
        "$(sanitize_csv_field "$desktop_file")" \
        "$pid" \
        "$(sanitize_csv_field "$source")" \
        "$(sanitize_csv_field "$run_id")")

    printf '%s\n' "$line" >>"$file" || return 1
    WDMTG_LAST_LOG=$file
    return 0
}

state_set() {
    local key=${1:?state key required}
    local value=${2-}
    local tmp="${WDMTG_STATE_FILE}.tmp.$$"

    value=${value//$'\n'/ }

    {
        if [[ -f $WDMTG_STATE_FILE ]]; then
            awk -v k="$key" -v v="$value" -F'=' '
                $1 == k { print k "=" v; found = 1; next }
                { print }
                END { if (!found) print k "=" v }
            ' "$WDMTG_STATE_FILE"
        else
            printf '%s=%s\n' "$key" "$value"
        fi
    } >"$tmp" || return 1

    mv -f -- "$tmp" "$WDMTG_STATE_FILE" || return 1
    chmod 600 -- "$WDMTG_STATE_FILE" 2>/dev/null || true
    return 0
}

state_get() {
    local key=${1:?state key required}

    [[ -f $WDMTG_STATE_FILE ]] || return 1
    awk -F'=' -v k="$key" '
        $1 == k { sub(/^[^=]*=/, ""); print; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$WDMTG_STATE_FILE"
}

write_pid_file() {
    local tmp="${WDMTG_PID_FILE}.tmp.$$"

    printf '%s\n' "$$" >"$tmp" || return 1
    mv -f -- "$tmp" "$WDMTG_PID_FILE" || return 1
}

read_pid_file() {
    [[ -f $WDMTG_PID_FILE ]] || return 1
    local pid
    pid=$(<"$WDMTG_PID_FILE") || return 1
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid"
}

# Verify that a PID really is our daemon before sending it a signal.
is_pid_tracker() {
    local pid=${1-}
    local cmdline

    [[ $pid =~ ^[0-9]+$ ]] || return 1
    [[ -d /proc/$pid ]] || return 1
    [[ -n ${WDMTG_ROOT_DIR:-} ]] || return 1

    cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ $cmdline == *"$WDMTG_ROOT_DIR/detective.sh"* ]] || return 1
    [[ $cmdline == *"__tracker"* ]] || return 1
    return 0
}

# Print the running tracker PID and return 0, or return 1. A PID file alone is
# not trusted; the process command line and the lock are the sources of truth.
tracker_running_pid() {
    local pid

    if pid=$(read_pid_file) && is_pid_tracker "$pid"; then
        printf '%s\n' "$pid"
        return 0
    fi
    return 1
}

# Return 0 if another process holds the tracker lock, 1 if free, 2 on error.
tracker_is_locked() {
    local fd

    exec {fd}>"$WDMTG_LOCK_FILE" || return 2
    if flock -n "$fd"; then
        flock -u "$fd" 2>/dev/null || true
        exec {fd}>&-
        return 1
    fi

    exec {fd}>&-
    return 0
}

kwin_available() {
    command_exists qdbus6 || return 1
    qdbus6 org.kde.KWin /KWin org.kde.KWin.currentDesktop >/dev/null 2>&1
}

kwin_script_loaded() {
    local result

    command_exists qdbus6 || return 1
    if ! result=$(qdbus6 org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.isScriptLoaded "$WDMTG_KWIN_PLUGIN" 2>&1); then
        return 1
    fi
    [[ $result == "true" ]]
}

# Count app changes recorded for today. This is a small status aid, not the
# reporting engine; malformed lines are ignored rather than repaired.
count_events_today() {
    local file=${1-}
    local today_start

    [[ -f $file ]] || {
        printf '0\n'
        return 0
    }
    today_start=$(date -d 'today 00:00' '+%s') || return 1

    awk -F',' -v t="$today_start" '
        NR == 1 && $1 == "epoch" { next }
        $1 ~ /^[0-9]+$/ && $1 >= t && $3 == "app" { count++ }
        END { print count + 0 }
    ' "$file"
}

print_log_tail() {
    if [[ -f $WDMTG_DAEMON_LOG ]]; then
        printf '\nLast tracker log lines (%s):\n' "$WDMTG_DAEMON_LOG" >&2
        tail -n 20 -- "$WDMTG_DAEMON_LOG" >&2 || true
    fi
}
