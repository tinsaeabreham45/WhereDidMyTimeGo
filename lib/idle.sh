# shellcheck shell=bash
#
# Build and lifecycle for the tiny Wayland idle helper.
#
# Idle detection is optional: when the helper cannot be built or the compositor
# does not advertise ext-idle-notify-v1, tracking continues and `status` says
# that idle detection is unavailable.

idle_helper_source() {
    printf '%s/helpers/wdmtg-idle.c\n' "$WDMTG_ROOT_DIR"
}

idle_helper_path() {
    printf '%s/wdmtg-idle\n' "$WDMTG_LIBEXEC_DIR"
}

idle_protocol_xml() {
    local datadir=""

    if command_exists pkg-config; then
        datadir=$(pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || true)
    fi
    if [[ -z $datadir ]]; then
        datadir="/usr/share/wayland-protocols"
    fi
    printf '%s/staging/ext-idle-notify/ext-idle-notify-v1.xml\n' "$datadir"
}

idle_helper_needs_build() {
    local source binary xml

    source=$(idle_helper_source)
    binary=$(idle_helper_path)
    xml=$(idle_protocol_xml)

    [[ -f $source ]] || return 0
    [[ -x $binary ]] || return 0
    [[ $source -nt $binary ]] && return 0
    [[ -f $xml && $xml -nt $binary ]] && return 0
    return 1
}

build_idle_helper() {
    local source binary xml tmpdir client_header protocol_source output
    local -a cflags=() libs=()

    source=$(idle_helper_source)
    binary=$(idle_helper_path)
    xml=$(idle_protocol_xml)

    if [[ ! -f $source ]]; then
        printf 'idle helper source is missing: %s\n' "$source" >&2
        return 1
    fi
    if [[ ! -f $xml ]]; then
        printf 'Wayland idle protocol is missing: %s\n' "$xml" >&2
        printf 'install the wayland-protocols development package to enable idle detection\n' >&2
        return 1
    fi
    if ! require_commands gcc wayland-scanner pkg-config; then
        return 1
    fi
    if ! pkg-config --exists wayland-client 2>/dev/null; then
        printf 'wayland-client development files are missing (pkg-config wayland-client)\n' >&2
        return 1
    fi

    mkdir -p -- "$WDMTG_LIBEXEC_DIR" || return 1
    chmod 700 -- "$WDMTG_LIBEXEC_DIR" || return 1

    tmpdir=$(mktemp -d "${WDMTG_LIBEXEC_DIR}/build.XXXXXX") || return 1
    client_header="$tmpdir/ext-idle-notify-v1-client-protocol.h"
    protocol_source="$tmpdir/ext-idle-notify-v1-protocol.c"
    output="$tmpdir/wdmtg-idle"

    if ! wayland-scanner client-header "$xml" "$client_header" 2>"$tmpdir/errors"; then
        printf 'could not generate the idle protocol header:\n' >&2
        cat -- "$tmpdir/errors" >&2 || true
        rm -rf -- "$tmpdir"
        return 1
    fi
    if ! wayland-scanner private-code "$xml" "$protocol_source" 2>>"$tmpdir/errors"; then
        printf 'could not generate the idle protocol code:\n' >&2
        cat -- "$tmpdir/errors" >&2 || true
        rm -rf -- "$tmpdir"
        return 1
    fi

    # pkg-config can return an empty string or a trailing space. read -a both
    # splits the flags and keeps a non-zero status from tripping set -e.
    read -r -a cflags <<<"$(pkg-config --cflags wayland-client 2>/dev/null || true)" || true
    read -r -a libs <<<"$(pkg-config --libs wayland-client 2>/dev/null || true)" || true

    if ! gcc -O2 -Wall -Wextra -std=c11 \
        -I"$tmpdir" -o "$output" "$source" "$protocol_source" \
        "${cflags[@]}" "${libs[@]}" 2>"$tmpdir/errors"; then
        printf 'could not compile the idle helper:\n' >&2
        cat -- "$tmpdir/errors" >&2 || true
        rm -rf -- "$tmpdir"
        return 1
    fi

    chmod 755 -- "$output" || {
        rm -rf -- "$tmpdir"
        return 1
    }
    mv -f -- "$output" "$binary" || {
        rm -rf -- "$tmpdir"
        return 1
    }
    rm -rf -- "$tmpdir"
    return 0
}

ensure_idle_helper() {
    if ! idle_helper_needs_build; then
        return 0
    fi
    printf 'building idle helper...\n' >&2
    build_idle_helper
}

idle_start() {
    local binary timeout_ms

    WDMTG_IDLE_PID=""
    if ((WDMTG_CFG_IDLE_TIMEOUT <= 0)); then
        return 1
    fi

    binary=$(idle_helper_path)
    if [[ ! -x $binary ]]; then
        return 1
    fi

    timeout_ms=$((WDMTG_CFG_IDLE_TIMEOUT * 1000))
    (
        # The helper is long-lived and must not inherit the tracker lock.
        if [[ -n ${WDMTG_LOCK_FD:-} ]]; then
            exec {WDMTG_LOCK_FD}>&-
        fi
        exec "$binary" --timeout-ms "$timeout_ms" --parent "$$"
    ) >>"$WDMTG_DAEMON_LOG" 2>&1 &
    WDMTG_IDLE_PID=$!

    sleep 0.2
    if ! kill -0 "$WDMTG_IDLE_PID" 2>/dev/null; then
        WDMTG_IDLE_PID=""
        return 1
    fi
    return 0
}

idle_stop() {
    local pid=${WDMTG_IDLE_PID:-}
    local i

    [[ -n $pid ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for ((i = 0; i < 20; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
    WDMTG_IDLE_PID=""
    return 0
}
