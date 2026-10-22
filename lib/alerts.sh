# shellcheck shell=bash
#
# Daily usage limits and desktop notifications.
#
# The daemon keeps no long-lived counters. It re-derives today's totals from the
# event log when checking, so midnight rollover and log edits stay consistent
# with reports. A cooldown stored in the state file prevents notification spam.

alerts_limit_seconds() {
    local type=${1:?type required}
    local name=${2:?name required}
    local aggregate=${3:?aggregate required}
    local -A app_seconds=()
    local -A category_seconds=()
    local kind item seconds app total=0

    while IFS=$'\t' read -r kind item seconds; do
        [[ $seconds =~ ^[0-9]+$ ]] || continue
        case $kind in
            A) app_seconds["$item"]=$seconds ;;
            C) category_seconds["$item"]=$seconds ;;
        esac
    done < <(awk -F'\t' '$1 == "A" || $1 == "C"' "$aggregate")

    if [[ $type == category ]]; then
        printf '%s' "${category_seconds[$name]:-0}"
        return 0
    fi

    for app in "${!app_seconds[@]}"; do
        # shellcheck disable=SC2053 # glob matching is intentional
        if [[ $app == $name ]]; then
            total=$((total + app_seconds[$app]))
        fi
    done
    printf '%s' "$total"
}

alerts_notify() {
    local title=${1:?title required}
    local body=${2-}

    if [[ ${WDMTG_CFG_NOTIFICATIONS:-1} != 1 ]]; then
        return 0
    fi
    if ! command_exists notify-send; then
        tracker_log WARN "limit reached but notify-send is not installed"
        return 0
    fi

    if ! notify-send -a "$WDMTG_APP_NAME" -u normal -- "$title" "$body" 2>/dev/null; then
        tracker_log WARN "notify-send failed for: $title"
    fi
    return 0
}

alerts_check() {
    local now today aggregate item type name seconds limit title body key last
    local cooldown
    local i

    # A fresh config read makes edits visible without restarting the tracker.
    config_load
    cooldown=${WDMTG_CFG_ALERT_COOLDOWN:-1800}
    ((${#WDMTG_LIMIT_TYPES[@]} > 0)) || return 0
    [[ ${WDMTG_PAUSED:-0} == 0 ]] || return 0
    [[ ${WDMTG_LOCKED:-0} == 0 ]] || return 0
    [[ ${WDMTG_IDLE:-0} == 0 ]] || return 0

    now=$(now_epoch)
    today=$(date '+%F')
    aggregate=$(mktemp "${TMPDIR:-/tmp}/wdmtg-alerts.XXXXXX") || return 1
    chmod 600 -- "$aggregate" || {
        rm -f -- "$aggregate"
        return 1
    }

    if ! report_today_aggregate >"$aggregate"; then
        rm -f -- "$aggregate"
        tracker_log WARN "could not calculate today's usage for alerts"
        return 1
    fi

    for i in "${!WDMTG_LIMIT_TYPES[@]}"; do
        type=${WDMTG_LIMIT_TYPES[$i]}
        name=${WDMTG_LIMIT_NAMES[$i]}
        limit=${WDMTG_LIMIT_MINUTES[$i]}
        seconds=$(alerts_limit_seconds "$type" "$name" "$aggregate")

        ((seconds >= limit)) || continue

        item=${name//[^A-Za-z0-9_-]/_}
        key="alert_last_${today}_${type}_${item}"
        last=$(state_get "$key" 2>/dev/null || true)
        [[ $last =~ ^[0-9]+$ ]] || last=0
        ((now - last >= cooldown)) || continue

        title="${name} limit reached"
        body="Today: $(human_duration "$seconds") (limit $(human_duration "$limit"))."
        tracker_log INFO "limit reached: ${type}:${name} ${seconds}s / ${limit}s"
        alerts_notify "$title" "$body"
        state_set "$key" "$now"
    done

    rm -f -- "$aggregate"
    return 0
}
