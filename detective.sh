#!/usr/bin/env bash
#
# WhereDidMyTimeGo — local-first foreground application tracker.
# Tracks focused applications on KDE Plasma 6 Wayland, derives durations,
# reports on them, and keeps all data on this machine.

set -Eeuo pipefail
umask 077

WDMTG_ROOT_DIR=$(cd -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")" && pwd -P)
WDMTG_LIB_DIR="$WDMTG_ROOT_DIR/lib"

# shellcheck source=lib/common.sh
source "$WDMTG_LIB_DIR/common.sh"
# shellcheck source=lib/config.sh
source "$WDMTG_LIB_DIR/config.sh"
# shellcheck source=lib/detector.sh
source "$WDMTG_LIB_DIR/detector.sh"
# shellcheck source=lib/idle.sh
source "$WDMTG_LIB_DIR/idle.sh"
# shellcheck source=lib/reports.sh
source "$WDMTG_LIB_DIR/reports.sh"
# shellcheck source=lib/alerts.sh
source "$WDMTG_LIB_DIR/alerts.sh"
# shellcheck source=lib/tracker.sh
source "$WDMTG_LIB_DIR/tracker.sh"
# shellcheck source=lib/data.sh
source "$WDMTG_LIB_DIR/data.sh"

usage() {
    cat <<'EOF'
WhereDidMyTimeGo — local-first foreground application tracker

Usage:
  detective.sh <command> [options]

Tracking:
  start                 Start tracking in the background
  stop                  Stop tracking and unload helpers
  restart               Stop, then start again
  status                Show state (exit 0 if running, 3 if stopped)
  pause                 Stop recording foreground changes
  resume                Resume recording after pause

Reports:
  report [--date DATE] [--no-color]
                        Daily report (default: today)
  weekly [--date DATE] [--no-color]
                        Weekly report (default: this week, Monday-Sunday)

Configuration:
  config [show|path|edit|init]
                        Show settings, print the path, or edit the file
  build                 Compile the optional Wayland idle helper

Data:
  export [--format csv|json] [--output PATH] [--force]
                        Export events to stdout or a file
  delete [--before DATE] [--yes]
                        Show data files; delete them only with --yes

General:
  help, -h, --help      Show this help
  version, -V, --version
                        Show the version

Options:
  --date DATE           ISO date, for example 2026-10-22
  --no-color            Disable ANSI colors
  --format csv|json     Export format (default: csv)
  --output PATH         Export destination, or - for stdout

Data locations (XDG):
  config   ${XDG_CONFIG_HOME:-$HOME/.config}/wheredidmytimego
  data     ${XDG_DATA_HOME:-$HOME/.local/share}/wheredidmytimego
  state    ${XDG_STATE_HOME:-$HOME/.local/state}/wheredidmytimego
  runtime  ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/wheredidmytimego
           (without XDG_RUNTIME_DIR: ${TMPDIR:-/tmp}/wheredidmytimego-UID/wheredidmytimego)

Privacy:
  Only application identifiers, timestamps, and event types are logged.
  Window titles, window contents, keystrokes, screenshots, clipboard data,
  and browsing history are never collected. Nothing is transmitted over the
  network. Data stays in the XDG directories above.

Exit codes:
  0 success, 3 status=stopped, 64 usage error, 69 unavailable dependency,
  70 internal error, 75 already running, 77 permission/path error.
EOF
}

require_no_args() {
    if (($# > 0)); then
        die "$EX_USAGE" "unexpected argument: $1 (try --help)"
    fi
}

main() {
    local cmd=${1:-}

    if [[ -z $cmd ]]; then
        usage >&2
        exit "$EX_USAGE"
    fi
    shift

    case "$cmd" in
        start)
            require_no_args "$@"
            cmd_start
            ;;
        stop)
            require_no_args "$@"
            cmd_stop
            ;;
        restart)
            require_no_args "$@"
            cmd_stop
            cmd_start
            ;;
        status)
            require_no_args "$@"
            cmd_status
            ;;
        pause)
            require_no_args "$@"
            cmd_pause
            ;;
        resume)
            require_no_args "$@"
            cmd_resume
            ;;
        report)
            cmd_report "$@"
            ;;
        weekly)
            cmd_weekly "$@"
            ;;
        config)
            cmd_config "$@"
            ;;
        export)
            cmd_export "$@"
            ;;
        delete)
            cmd_delete "$@"
            ;;
        build)
            require_no_args "$@"
            cmd_build
            ;;
        help | -h | --help)
            require_no_args "$@"
            usage
            ;;
        version | -V | --version)
            require_no_args "$@"
            printf '%s %s\n' "$WDMTG_APP_NAME" "$WDMTG_VERSION"
            ;;
        __tracker)
            [[ ${WDMTG_INTERNAL:-0} == 1 ]] || die "$EX_USAGE" "internal command; use 'detective.sh start'"
            require_no_args "$@"
            tracker_run
            ;;
        *)
            die "$EX_USAGE" "unknown command: $cmd (try --help)"
            ;;
    esac
}

main "$@"
