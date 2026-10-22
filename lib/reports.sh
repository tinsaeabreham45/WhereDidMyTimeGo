# shellcheck shell=bash
#
# Interval extraction and terminal reports.
#
# The CSV log is an event stream, not a list of durations. A segment starts at
# an "app" event and ends at the next boundary event: another app, none, idle,
# lock, sleep, pause, excluded, or stop. Reports derive durations from those
# segments, so the raw log stays append-only and easy to audit.

report_event_files() {
    local file

    for file in "$WDMTG_DATA_DIR"/events-*.csv; do
        [[ -f $file ]] && printf '%s\n' "$file"
    done
}

# report_build_segments [CLOSE_OPEN_AT]
# Prints start<TAB>end<TAB>app_id. A non-zero CLOSE_OPEN_AT closes a trailing
# open segment at that time; otherwise it is omitted. A "start" event discards
# an open segment from a previous crashed run instead of attributing the gap.
report_build_segments() {
    local close_open_at=${1:-0}

    {
        local file
        for file in "$WDMTG_DATA_DIR"/events-*.csv; do
            [[ -f $file ]] || continue
            cat -- "$file" || return 1
        done
    } | awk -F',' -v cutoff="$close_open_at" '
        function close_segment(at) {
            if (active != "" && at >= started) {
                print started "\t" at "\t" active
            }
            active = ""
            started = 0
        }

        $1 == "epoch" { next }
        NF < 9 { next }
        $1 !~ /^[0-9]+$/ { next }
        {
            sub(/\r$/, "")
            epoch = $1 + 0
            event = $3
            app = $4

            if (event == "app") {
                if (app == "") next
                close_segment(epoch)
                active = app
                started = epoch
            } else if (event == "start") {
                # A new run begins here. If the previous run crashed without a
                # stop event, do not count the unknown gap.
                active = ""
                started = 0
            } else if (event == "stop" || event == "none" || event == "idle" ||
                       event == "lock" || event == "sleep" || event == "pause" ||
                       event == "excluded") {
                close_segment(epoch)
            }
        }
        END {
            if (active != "" && cutoff > 0) {
                close_segment(cutoff + 0)
            }
        }
    '
}

# Build an app -> category map for the apps present in a segment file.
# Excluded apps are marked __EXCLUDED__ and dropped during aggregation.
report_map_apps() {
    local segments=${1:?segments file required}
    local map=${2:?map file required}
    local app

    while IFS=$'\t' read -r _ _ app; do
        [[ -n $app ]] && printf '%s\n' "$app"
    done <"$segments" | LC_ALL=C sort -u | while IFS= read -r app; do
        if app_is_excluded "$app"; then
            printf '%s\t__EXCLUDED__\n' "$app"
        else
            printf '%s\t%s\n' "$app" "$(category_for_app "$app")"
        fi
    done >"$map"
}

# report_aggregate SEGMENTS MAP START END DAY_STARTS BROWSING_CATEGORY
#
# TSV output types:
#   T   total seconds
#   A   app, seconds
#   C   category, seconds
#   S   app, category, start epoch, seconds       (every clipped segment)
#   B   app, start epoch, seconds                 (longest browsing segment)
#   D   day index, seconds
#   DA  day index, app, seconds
#   DC  day index, category, seconds
report_aggregate() {
    local segments=${1:?segments required}
    local map=${2:?map required}
    local start=${3:?start required}
    local end=${4:?end required}
    local days=${5-}
    local browsing=${6:-Browsing}

    awk -F'\t' -v OFS='\t' -v start="$start" -v end="$end" -v days="$days" \
        -v browsing="$browsing" '
        BEGIN {
            OFS = "\t"
            n = split(days, day, ",")
        }

        FILENAME == ARGV[1] {
            if ($1 != "") category[$1] = $2
            next
        }

        {
            s = $1 + 0
            e = $2 + 0
            app = $3
            if (app == "") next
            if (category[app] == "__EXCLUDED__") next
            if (s < start) s = start
            if (e > end) e = end
            if (e <= s) next

            cat = category[app]
            if (cat == "") cat = "Other"
            secs = e - s

            total += secs
            appsec[app] += secs
            catsec[cat] += secs
            print "S", app, cat, s, secs

            if (secs > longest_browse &&
                tolower(cat) == tolower(browsing)) {
                longest_browse = secs
                browse_app = app
                browse_start = s
            }

            if (n == 0) next
            for (i = 1; i <= n; i++) {
                ds = day[i] + 0
                de = (i < n ? day[i + 1] + 0 : end + 0)
                a = (s > ds ? s : ds)
                b = (e < de ? e : de)
                if (b > a) {
                    idx = i - 1
                    daysec[idx] += b - a
                    dayapp[idx, app] += b - a
                    daycat[idx, cat] += b - a
                }
            }
        }

        END {
            print "T", total + 0
            for (app in appsec) print "A", app, appsec[app]
            for (cat in catsec) print "C", cat, catsec[cat]
            for (i = 0; i < n; i++) print "D", i, daysec[i] + 0
            for (key in dayapp) {
                split(key, p, SUBSEP)
                print "DA", p[1], p[2], dayapp[key]
            }
            for (key in daycat) {
                split(key, p, SUBSEP)
                print "DC", p[1], p[2], daycat[key]
            }
            if (longest_browse > 0) {
                print "B", browse_app, browse_start, longest_browse
            }
        }
    ' "$map" "$segments"
}

report_style() {
    local code=${1:?code required}
    shift
    if [[ ${WDMTG_REPORT_COLOR:-0} == 1 ]]; then
        printf '\033[%sm%s\033[0m' "$code" "$*"
    else
        printf '%s' "$*"
    fi
}

report_heading() {
    report_style "1;36" "$*"
    printf '\n'
}

report_print_breakdown() {
    local aggregate=${1:?aggregate required}
    local kind=${2:?kind required}
    local total=${3:-0}
    local title=${4:-Breakdown}
    local limit=${5:-0}
    local color=${6:-0}

    printf '\n'
    report_heading "$title"

    awk -F'\t' -v kind="$kind" '$1 == kind { print $2 "\t" $3 }' "$aggregate" |
        LC_ALL=C sort -t$'\t' -k2,2nr |
        awk -F'\t' -v total="$total" -v limit="$limit" -v color="$color" '
            function fmt(secs, h, m) {
                h = int(secs / 3600)
                m = int((secs % 3600) / 60)
                if (h > 0) return h "h " sprintf("%02dm", m)
                if (m > 0) return m "m"
                return secs "s"
            }
            function paint(idx, text) {
                if (!color) return text
                code = (idx % 6)
                if (code == 0) c = "\033[36m"
                else if (code == 1) c = "\033[32m"
                else if (code == 2) c = "\033[33m"
                else if (code == 3) c = "\033[35m"
                else if (code == 4) c = "\033[34m"
                else c = "\033[31m"
                return c text "\033[0m"
            }
            {
                if (limit > 0 && NR > limit) next
                secs = $2 + 0
                pct = (total > 0 ? (100 * secs / total) : 0)
                bar_len = (total > 0 ? int(secs * 24 / total + 0.5) : 0)
                if (bar_len < 1 && secs > 0) bar_len = 1
                bar = ""
                for (i = 0; i < bar_len; i++) bar = bar "#"
                name = substr($1, 1, 28)
                printf "  %-28s %8s %5.1f%%  %s\n", name, fmt(secs), pct, paint(NR, bar)
            }
        '
}

# Read a single numeric field from an aggregate file: report_agg_field AGG TYPE [INDEX]
report_agg_field() {
    local aggregate=${1:?aggregate required}
    local type=${2:?type required}
    local index=${3-}

    if [[ -n $index ]]; then
        awk -F'\t' -v t="$type" -v i="$index" \
            '$1 == t && $2 == i { print $3; found = 1; exit } END { if (!found) print 0 }' \
            "$aggregate"
    else
        awk -F'\t' -v t="$type" \
            '$1 == t { print $2; found = 1; exit } END { if (!found) print 0 }' \
            "$aggregate"
    fi
}

report_seconds() {
    local value=${1:-0}
    [[ $value =~ ^[0-9]+$ ]] || value=0
    printf '%s' "$value"
}

report_daily_limits() {
    local aggregate=${1:?aggregate required}
    local total=${2:-0}
    local -A app_seconds=()
    local -A category_seconds=()
    local kind name seconds i app matched

    ((${#WDMTG_LIMIT_TYPES[@]} > 0)) || return 0

    while IFS=$'\t' read -r kind name seconds; do
        [[ $seconds =~ ^[0-9]+$ ]] || continue
        case $kind in
            A) app_seconds["$name"]=$seconds ;;
            C) category_seconds["$name"]=$seconds ;;
        esac
    done < <(awk -F'\t' '$1 == "A" || $1 == "C"' "$aggregate")

    printf '\n'
    report_heading "Limits"
    for i in "${!WDMTG_LIMIT_TYPES[@]}"; do
        name=${WDMTG_LIMIT_NAMES[$i]}
        seconds=0
        if [[ ${WDMTG_LIMIT_TYPES[$i]} == category ]]; then
            seconds=${category_seconds[$name]:-0}
        else
            for app in "${!app_seconds[@]}"; do
                # shellcheck disable=SC2053 # glob matching is intentional
                if [[ $app == $name ]]; then
                    seconds=$((seconds + app_seconds[$app]))
                fi
            done
        fi
        local limit=${WDMTG_LIMIT_MINUTES[$i]}
        printf '  %-28s %8s / %-8s' \
            "${WDMTG_LIMIT_TYPES[$i]}:$name" \
            "$(human_duration "$seconds")" "$(human_duration "$limit")"
        if ((seconds >= limit)); then
            printf ' %s\n' "$(report_style "1;31" "limit reached")"
        else
            printf ' %s\n' "$(report_style "2" "ok")"
        fi
    done
}

report_daily() (
    local date=${1:-$(date '+%F')}
    local color=${2:-0}
    local start end prev_start prev_end today close_open=0 running=0
    local tmpdir segments map aggregate prev_aggregate total prev_total
    local longest_line browse_line app started seconds delta

    export WDMTG_REPORT_COLOR=$color

    if ! valid_date "$date"; then
        printf 'invalid date: %s (expected YYYY-MM-DD)\n' "$date" >&2
        exit "$EX_USAGE"
    fi

    config_load
    today=$(date '+%F')
    start=$(day_start_epoch "$date") || exit "$EX_SOFTWARE"
    end=$(day_end_epoch "$date") || exit "$EX_SOFTWARE"
    prev_start=$(day_start_epoch "$(date -d "$date -1 day" '+%F')") || exit "$EX_SOFTWARE"
    prev_end=$start

    if tracker_running_pid >/dev/null 2>&1; then
        running=1
        close_open=$(now_epoch)
    fi

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wdmtg-report.XXXXXX") || exit "$EX_SOFTWARE"
    chmod 700 -- "$tmpdir" || {
        rm -rf -- "$tmpdir"
        exit "$EX_SOFTWARE"
    }
    trap 'rm -rf -- "$tmpdir"' EXIT

    segments="$tmpdir/segments"
    map="$tmpdir/map"
    aggregate="$tmpdir/aggregate"
    prev_aggregate="$tmpdir/prev-aggregate"

    report_build_segments "$close_open" >"$segments" || exit "$EX_SOFTWARE"
    report_map_apps "$segments" "$map" || exit "$EX_SOFTWARE"
    report_aggregate "$segments" "$map" "$start" "$end" "$start" \
        "$WDMTG_CFG_BROWSING_CATEGORY" >"$aggregate" || exit "$EX_SOFTWARE"
    report_aggregate "$segments" "$map" "$prev_start" "$prev_end" "$prev_start" \
        "$WDMTG_CFG_BROWSING_CATEGORY" >"$prev_aggregate" || exit "$EX_SOFTWARE"

    total=$(report_seconds "$(report_agg_field "$aggregate" T)")
    prev_total=$(report_seconds "$(report_agg_field "$prev_aggregate" T)")

    report_heading "WhereDidMyTimeGo — Daily report — $date"
    printf 'Total tracked: %s\n' "$(human_duration "$total")"

    if ((prev_total > 0)); then
        if ((total >= prev_total)); then
            delta="+$(human_duration $((total - prev_total)))"
        else
            delta="-$(human_duration $((prev_total - total)))"
        fi
        printf 'Previous day: %s (%s)\n' "$(human_duration "$prev_total")" "$delta"
    else
        printf 'Previous day: no tracked activity\n'
    fi

    if ((total == 0)); then
        printf '\nNo tracked activity for this date.\n'
        if ((running == 1)); then
            printf 'The tracker is running; switch applications to create events.\n'
        fi
        exit 0
    fi

    report_print_breakdown "$aggregate" A "$total" "Applications" 15 "$color"
    report_print_breakdown "$aggregate" C "$total" "Categories" 15 "$color"
    report_daily_limits "$aggregate" "$total"

    printf '\n'
    report_heading "Longest sessions"
    longest_line=$(awk -F'\t' '$1 == "S" && $5 > max { max = $5; line = $2 "\t" $4 "\t" $5 } END { if (line != "") print line }' "$aggregate")
    if [[ -n $longest_line ]]; then
        IFS=$'\t' read -r app started seconds <<<"$longest_line"
        printf '  Application: %-24s %8s (started %s)\n' \
            "$app" "$(human_duration "$seconds")" "$(date -d "@$started" '+%H:%M')"
    else
        printf '  Application: none\n'
    fi

    browse_line=$(awk -F'\t' '$1 == "B" { print $2 "\t" $3 "\t" $4 }' "$aggregate")
    if [[ -n $browse_line ]]; then
        IFS=$'\t' read -r app started seconds <<<"$browse_line"
        printf '  %-12s %-24s %8s (started %s)\n' \
            "$WDMTG_CFG_BROWSING_CATEGORY:" "$app" "$(human_duration "$seconds")" \
            "$(date -d "@$started" '+%H:%M')"
    else
        printf '  %-12s none\n' "$WDMTG_CFG_BROWSING_CATEGORY:"
    fi

    printf '\n'
    printf 'Measured from foreground-window events. Idle, lock, suspend, and pause gaps are excluded.\n'
    exit 0
)

report_monday() {
    local date=${1:?date required}
    local dow

    dow=$(date -d "$date 00:00:00" '+%u') || return 1
    if ((dow == 1)); then
        date -d "$date" '+%F'
    else
        date -d "$date -$((dow - 1)) days" '+%F'
    fi
}

report_weekly() (
    local date=${1:-$(date '+%F')}
    local color=${2:-0}
    local week_start_date week_end_date start end today close_open=0
    local tmpdir segments map aggregate prev_aggregate total prev_total
    local -a day_dates=() day_starts=()
    local i epoch seconds max_day future label delta
    local days_csv=""

    export WDMTG_REPORT_COLOR=$color

    if ! valid_date "$date"; then
        printf 'invalid date: %s (expected YYYY-MM-DD)\n' "$date" >&2
        exit "$EX_USAGE"
    fi

    config_load
    week_start_date=$(report_monday "$date") || exit "$EX_SOFTWARE"
    week_end_date=$(date -d "$week_start_date +7 days" '+%F') || exit "$EX_SOFTWARE"
    start=$(day_start_epoch "$week_start_date") || exit "$EX_SOFTWARE"
    end=$(day_start_epoch "$week_end_date") || exit "$EX_SOFTWARE"
    today=$(date '+%F')

    if tracker_running_pid >/dev/null 2>&1; then
        close_open=$(now_epoch)
    fi

    for i in 0 1 2 3 4 5 6; do
        label=$(date -d "$week_start_date +$i days" '+%F')
        day_dates+=("$label")
        epoch=$(day_start_epoch "$label") || exit "$EX_SOFTWARE"
        day_starts+=("$epoch")
        days_csv+="${epoch},"
    done
    days_csv=${days_csv%,}

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wdmtg-weekly.XXXXXX") || exit "$EX_SOFTWARE"
    chmod 700 -- "$tmpdir" || {
        rm -rf -- "$tmpdir"
        exit "$EX_SOFTWARE"
    }
    trap 'rm -rf -- "$tmpdir"' EXIT

    segments="$tmpdir/segments"
    map="$tmpdir/map"
    aggregate="$tmpdir/aggregate"
    prev_aggregate="$tmpdir/prev-aggregate"

    report_build_segments "$close_open" >"$segments" || exit "$EX_SOFTWARE"
    report_map_apps "$segments" "$map" || exit "$EX_SOFTWARE"
    report_aggregate "$segments" "$map" "$start" "$end" "$days_csv" \
        "$WDMTG_CFG_BROWSING_CATEGORY" >"$aggregate" || exit "$EX_SOFTWARE"

    local prev_start prev_end prev_start_date
    prev_start_date=$(date -d "$week_start_date -7 days" '+%F') || exit "$EX_SOFTWARE"
    prev_start=$(day_start_epoch "$prev_start_date") || exit "$EX_SOFTWARE"
    prev_end=$start
    report_aggregate "$segments" "$map" "$prev_start" "$prev_end" "$prev_start" \
        "$WDMTG_CFG_BROWSING_CATEGORY" >"$prev_aggregate" || exit "$EX_SOFTWARE"

    total=$(report_seconds "$(report_agg_field "$aggregate" T)")
    prev_total=$(report_seconds "$(report_agg_field "$prev_aggregate" T)")

    report_heading "WhereDidMyTimeGo — Weekly report — week of $week_start_date"
    printf 'Total tracked: %s\n' "$(human_duration "$total")"
    if ((prev_total > 0)); then
        if ((total >= prev_total)); then
            delta="+$(human_duration $((total - prev_total)))"
        else
            delta="-$(human_duration $((prev_total - total)))"
        fi
        printf 'Previous week: %s (%s)\n' "$(human_duration "$prev_total")" "$delta"
    else
        printf 'Previous week: no tracked activity\n'
    fi

    printf '\n'
    report_heading "Daily activity"
    max_day=$(awk -F'\t' '$1 == "D" && $3 > max { max = $3 } END { print max + 0 }' "$aggregate")
    for i in 0 1 2 3 4 5 6; do
        epoch=${day_starts[$i]}
        seconds=$(report_seconds "$(report_agg_field "$aggregate" D "$i")")
        label=$(date -d "@$epoch" '+%a %Y-%m-%d')
        future=0
        ((epoch > $(now_epoch))) && future=1
        if ((future == 1)); then
            printf '  %-16s %8s  %s\n' "$label" "—" "not yet"
        elif ((seconds == 0)); then
            printf '  %-16s %8s  %s\n' "$label" "—" ""
        else
            printf '  %-16s %8s  ' "$label" "$(human_duration "$seconds")"
            if ((max_day > 0)); then
                printf '%s' "$(report_style "36" "$(printf '%*s' "$((seconds * 30 / max_day))" '' | tr ' ' '#')")"
            fi
            printf '\n'
        fi
    done

    report_print_breakdown "$aggregate" A "$total" "Applications" 10 "$color"
    report_print_breakdown "$aggregate" C "$total" "Categories" 10 "$color"

    printf '\n'
    report_heading "Longest sessions"
    local sessions
    sessions=$(awk -F'\t' '$1 == "S" { print $2 "\t" $4 "\t" $5 }' "$aggregate" |
        LC_ALL=C sort -t$'\t' -k3,3nr | head -n 5)
    if [[ -z $sessions ]]; then
        printf '  none\n'
    else
        while IFS=$'\t' read -r app epoch seconds; do
            printf '  %-24s %8s  %s\n' "$app" "$(human_duration "$seconds")" \
                "$(date -d "@$epoch" '+%a %H:%M')"
        done <<<"$sessions"
    fi

    report_weekly_goals "$week_start_date" "$segments" "$map" || true

    printf '\n'
    printf 'Measured from foreground-window events. Idle, lock, suspend, and pause gaps are excluded.\n'
    exit 0
)

# Weekly goals and streaks. The last 365 days are aggregated with day
# boundaries so a session crossing midnight is credited to both days.
report_weekly_goals() {
    local week_start_date=${1:?week start required}
    local segments=${2:?segments required}
    local map=${3:?map required}
    local today week_last reference
    local goal_category goal_seconds count=0 start_index
    local i j date_label
    local streak_start_date streak_start streak_end streak_days=""
    local tmp_aggregate
    local -A day_category_seconds=()

    ((${#WDMTG_GOAL_CATEGORIES[@]} > 0)) || return 0

    today=$(date '+%F')
    week_last=$(date -d "$week_start_date +6 days" '+%F') || return 1
    if [[ $week_last < $today ]]; then
        reference=$week_last
    else
        reference=$today
    fi

    streak_start_date=$(date -d "$reference -364 days" '+%F') || return 1
    streak_start=$(day_start_epoch "$streak_start_date") || return 1
    streak_end=$(day_end_epoch "$reference") || return 1
    for i in $(seq 0 364); do
        date_label=$(date -d "$streak_start_date +$i days" '+%F') || return 1
        streak_days+="$(day_start_epoch "$date_label")," || return 1
    done
    streak_days=${streak_days%,}

    tmp_aggregate=$(mktemp "${TMPDIR:-/tmp}/wdmtg-streak.XXXXXX") || return 1
    chmod 600 -- "$tmp_aggregate" || {
        rm -f -- "$tmp_aggregate"
        return 1
    }
    report_aggregate "$segments" "$map" "$streak_start" "$streak_end" \
        "$streak_days" "$WDMTG_CFG_BROWSING_CATEGORY" >"$tmp_aggregate" || {
        rm -f -- "$tmp_aggregate"
        return 1
    }

    while IFS=$'\t' read -r _ day_index category seconds; do
        [[ $day_index =~ ^[0-9]+$ && $seconds =~ ^[0-9]+$ ]] || continue
        day_category_seconds["$day_index,$category"]=$seconds
    done < <(awk -F'\t' '$1 == "DC" { print $1 "\t" $2 "\t" $3 "\t" $4 }' "$tmp_aggregate")

    printf '\n'
    report_heading "Goals"
    for i in "${!WDMTG_GOAL_CATEGORIES[@]}"; do
        goal_category=${WDMTG_GOAL_CATEGORIES[$i]}
        goal_seconds=${WDMTG_GOAL_MINUTES[$i]}
        start_index=364

        # Do not call today's streak broken while the day is still in progress.
        if [[ $reference == "$today" ]] &&
            ((${day_category_seconds["364,$goal_category"]:-0} < goal_seconds)); then
            start_index=363
        fi

        count=0
        for ((j = start_index; j >= 0; j--)); do
            if ((${day_category_seconds["$j,$goal_category"]:-0} >= goal_seconds)); then
                count=$((count + 1))
            else
                break
            fi
        done
        printf '  %s: %d day streak (goal %s/day)\n' \
            "$goal_category" "$count" "$(human_duration "$goal_seconds")"
    done

    rm -f -- "$tmp_aggregate"
    return 0
}

# Today's aggregate for alerts and status. Runs in a subshell so its temporary
# files are removed even when the caller aborts.
report_today_aggregate() (
    local today start end close_open=0
    local tmpdir segments map

    config_load
    today=$(date '+%F')
    start=$(day_start_epoch "$today") || exit "$EX_SOFTWARE"
    end=$(day_end_epoch "$today") || exit "$EX_SOFTWARE"
    tracker_running_pid >/dev/null 2>&1 && close_open=$(now_epoch)

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wdmtg-today.XXXXXX") || exit "$EX_SOFTWARE"
    chmod 700 -- "$tmpdir" || {
        rm -rf -- "$tmpdir"
        exit "$EX_SOFTWARE"
    }
    trap 'rm -rf -- "$tmpdir"' EXIT

    segments="$tmpdir/segments"
    map="$tmpdir/map"
    report_build_segments "$close_open" >"$segments" || exit "$EX_SOFTWARE"
    report_map_apps "$segments" "$map" || exit "$EX_SOFTWARE"
    report_aggregate "$segments" "$map" "$start" "$end" "" \
        "$WDMTG_CFG_BROWSING_CATEGORY"
)

report_today_seconds() {
    report_today_aggregate | awk -F'\t' '$1 == "T" { print $2; found = 1; exit } END { if (!found) print 0 }'
}
