# shellcheck shell=bash
#
# Explicit export and deletion of activity data.
#
# Nothing here runs automatically. `delete` refuses to act without --yes and
# refuses to run while the tracker is active.

data_export_csv() {
    local -a files=("$@")
    local file

    printf '%s\n' "$WDMTG_CSV_HEADER"
    for file in "${files[@]}"; do
        tail -n +2 -- "$file" || return 1
    done
}

data_export_json() {
    local -a files=("$@")

    awk -F',' '
        function escape(value, out) {
            out = value
            gsub(/\\/, "\\\\", out)
            gsub(/"/, "\\\"", out)
            gsub(/\t/, "\\t", out)
            gsub(/\r/, "", out)
            return out
        }
        BEGIN {
            print "["
            first = 1
        }
        $1 == "epoch" { next }
        NF < 9 { next }
        $1 !~ /^[0-9]+$/ { next }
        {
            if (!first) print ","
            first = 0
            printf "  {\"epoch\": %s, \"iso8601\": \"%s\", \"event\": \"%s\", \"app_id\": \"%s\", \"app_class\": \"%s\", \"desktop_file\": \"%s\", \"pid\": %d, \"source\": \"%s\", \"run_id\": \"%s\"}",
                $1, escape($2), escape($3), escape($4), escape($5),
                escape($6), $7 + 0, escape($8), escape($9)
        }
        END {
            print "\n]"
        }
    ' "${files[@]}"
}

data_write_export() {
    local output=${1:?output required}
    local force=${2:-0}
    local tmpdir tmp
    local -a files=()

    shift 2
    files=("$@")

    if [[ $output != "-" ]]; then
        local dir base
        dir=$(dirname -- "$output") || return 1
        base=$(basename -- "$output") || return 1
        if [[ ! -d $dir ]]; then
            printf 'export directory does not exist: %s\n' "$dir" >&2
            return 1
        fi
        if [[ $dir -ef $WDMTG_DATA_DIR && $base == events-*.csv ]]; then
            printf 'refusing to export into the live data directory as %s\n' "$base" >&2
            return 1
        fi
        if [[ -e $output && $force != 1 ]]; then
            printf 'refusing to overwrite existing file: %s (use --force)\n' "$output" >&2
            return 1
        fi

        tmpdir=$(dirname -- "$output")
        tmp=$(mktemp "${tmpdir}/.wdmtg-export.XXXXXX") || return 1
        chmod 600 -- "$tmp" || {
            rm -f -- "$tmp"
            return 1
        }
    else
        tmp=""
    fi

    if [[ -n $tmp ]]; then
        data_export_csv "${files[@]}" >"$tmp" || {
            rm -f -- "$tmp"
            return 1
        }
        mv -f -- "$tmp" "$output" || {
            rm -f -- "$tmp"
            return 1
        }
    fi
    return 0
}

cmd_export() {
    local format="csv"
    local output="-"
    local force=0
    local -a files=()
    local file count=0 lines

    wdmtg_init_paths

    while (($# > 0)); do
        case "$1" in
            --format)
                (($# >= 2)) || die "$EX_USAGE" "--format needs csv or json"
                format=$2
                shift 2
                ;;
            --output | -o)
                (($# >= 2)) || die "$EX_USAGE" "$1 needs a path"
                output=$2
                shift 2
                ;;
            --force)
                force=1
                shift
                ;;
            -h | --help)
                printf 'Usage: detective.sh export [--format csv|json] [--output PATH] [--force]\n'
                return 0
                ;;
            *)
                die "$EX_USAGE" "unknown export option: $1"
                ;;
        esac
    done

    [[ $format == csv || $format == json ]] ||
        die "$EX_USAGE" "export format must be csv or json"

    while IFS= read -r file; do
        files+=("$file")
    done < <(report_event_files)

    if ((${#files[@]} == 0)); then
        if [[ $output == "-" ]]; then
            if [[ $format == csv ]]; then
                printf '%s\n' "$WDMTG_CSV_HEADER"
            else
                printf '[]\n'
            fi
        else
            printf 'No activity data to export.\n' >&2
        fi
        return 0
    fi

    for file in "${files[@]}"; do
        lines=$(wc -l <"$file") || lines=0
        count=$((count + lines - 1))
    done

    if [[ $output == "-" ]]; then
        if [[ $format == csv ]]; then
            data_export_csv "${files[@]}" || die "$EX_SOFTWARE" "export failed"
        else
            data_export_json "${files[@]}" || die "$EX_SOFTWARE" "export failed"
        fi
        return 0
    fi

    if [[ $format == csv ]]; then
        data_write_export "$output" "$force" "${files[@]}" ||
            die "$EX_SOFTWARE" "export failed; existing files are not overwritten without --force"
    else
        local tmpdir tmp base
        tmpdir=$(dirname -- "$output") || die "$EX_SOFTWARE" "cannot resolve export path"
        base=$(basename -- "$output") || die "$EX_SOFTWARE" "cannot resolve export path"
        [[ -d $tmpdir ]] || die "$EX_USAGE" "export directory does not exist: $tmpdir"
        if [[ $tmpdir -ef $WDMTG_DATA_DIR && $base == events-*.csv ]]; then
            die "$EX_USAGE" "refusing to export into the live data directory as $base"
        fi
        if [[ -e $output && $force != 1 ]]; then
            die "$EX_USAGE" "refusing to overwrite existing file: $output (use --force)"
        fi
        tmp=$(mktemp "${tmpdir}/.wdmtg-export.XXXXXX") ||
            die "$EX_SOFTWARE" "cannot create a temporary export file"
        chmod 600 -- "$tmp" || {
            rm -f -- "$tmp"
            die "$EX_SOFTWARE" "cannot protect the temporary export file"
        }
        data_export_json "${files[@]}" >"$tmp" || {
            rm -f -- "$tmp"
            die "$EX_SOFTWARE" "export failed"
        }
        mv -f -- "$tmp" "$output" || {
            rm -f -- "$tmp"
            die "$EX_SOFTWARE" "could not move the export into place"
        }
    fi

    printf 'Exported %d event(s) to %s\n' "$count" "$output"
    return 0
}

cmd_delete() {
    local assume_yes=0
    local before=""
    local -a whole_files=()
    local partial_file=""
    local file base month cutoff="" cutoff_epoch=0 lock_state=0
    local bytes=0 size tmp remaining selected=0

    wdmtg_init_paths

    while (($# > 0)); do
        case "$1" in
            --yes)
                assume_yes=1
                shift
                ;;
            --before)
                (($# >= 2)) || die "$EX_USAGE" "--before needs a date (YYYY-MM-DD)"
                before=$2
                shift 2
                ;;
            -h | --help)
                printf 'Usage: detective.sh delete [--before YYYY-MM-DD] [--yes]\n'
                return 0
                ;;
            *)
                die "$EX_USAGE" "unknown delete option: $1"
                ;;
        esac
    done

    if [[ -n $before ]]; then
        valid_date "$before" || die "$EX_USAGE" "invalid date: $before (expected YYYY-MM-DD)"
        cutoff=${before:0:7}
        cutoff_epoch=$(day_start_epoch "$before") ||
            die "$EX_SOFTWARE" "cannot resolve the cutoff date"
    fi

    if tracker_running_pid >/dev/null 2>&1; then
        die "$EX_TEMPFAIL" "stop the tracker before deleting data"
    fi
    # A missing PID file does not prove the data is unowned; a live lock does.
    if [[ -f $WDMTG_LOCK_FILE ]]; then
        tracker_is_locked || lock_state=$?
        if ((lock_state == 0)); then
            die "$EX_TEMPFAIL" "stop the tracker before deleting data"
        fi
        if ((lock_state == 2)); then
            die "$EX_SOFTWARE" "cannot inspect the tracker lock"
        fi
    fi

    for file in "$WDMTG_DATA_DIR"/events-*.csv; do
        [[ -f $file ]] || continue
        if [[ -n $cutoff ]]; then
            base=$(basename -- "$file")
            month=${base#events-}
            month=${month%.csv}
            if [[ $month < $cutoff ]]; then
                whole_files+=("$file")
            elif [[ $month == $cutoff ]]; then
                # Keep whole months simple, but honor the exact date inside the
                # cutoff month instead of silently keeping the entire month.
                if awk -F',' -v c="$cutoff_epoch" '
                    $1 ~ /^[0-9]+$/ && ($1 + 0) < c { found = 1; exit }
                    END { exit !found }
                ' "$file"; then
                    partial_file=$file
                fi
            fi
        else
            whole_files+=("$file")
        fi
    done

    if ((${#whole_files[@]} == 0)) && [[ -z $partial_file ]]; then
        printf 'No activity data found%s.\n' "${before:+ before $before}"
        return 0
    fi

    printf 'Activity data selected for deletion:\n'
    for file in "${whole_files[@]}"; do
        printf '  %s\n' "$file"
        size=$(wc -c <"$file") || size=0
        bytes=$((bytes + size))
        selected=$((selected + 1))
    done
    if [[ -n $partial_file ]]; then
        printf '  %s (events before %s)\n' "$partial_file" "$before"
        size=$(wc -c <"$partial_file") || size=0
        bytes=$((bytes + size))
        selected=$((selected + 1))
    fi
    printf 'Total: %d file(s), %d byte(s)\n' "$selected" "$bytes"

    if ((assume_yes == 0)); then
        printf '\nNo data was deleted. Re-run with --yes to delete this data.\n'
        return "$EX_USAGE"
    fi

    if ((${#whole_files[@]} > 0)); then
        rm -f -- "${whole_files[@]}" ||
            die "$EX_NOPERM" "could not delete all selected files"
    fi

    if [[ -n $partial_file ]]; then
        tmp=$(mktemp "${WDMTG_DATA_DIR}/.wdmtg-delete.XXXXXX") ||
            die "$EX_SOFTWARE" "cannot create a temporary delete file"
        if ! chmod 600 -- "$tmp"; then
            rm -f -- "$tmp"
            die "$EX_NOPERM" "cannot protect the temporary delete file"
        fi
        if ! awk -F',' -v c="$cutoff_epoch" '
            $1 == "epoch" { print; next }
            $1 ~ /^[0-9]+$/ && ($1 + 0) >= c { print }
        ' "$partial_file" >"$tmp"; then
            rm -f -- "$tmp"
            die "$EX_SOFTWARE" "could not filter $partial_file"
        fi
        remaining=$(awk -F',' '$1 != "epoch" { n++ } END { print n + 0 }' "$tmp") ||
            remaining=0
        if ((remaining == 0)); then
            rm -f -- "$tmp" "$partial_file" ||
                die "$EX_NOPERM" "could not remove $partial_file"
        else
            mv -f -- "$tmp" "$partial_file" || {
                rm -f -- "$tmp"
                die "$EX_SOFTWARE" "could not replace $partial_file"
            }
        fi
    fi

    # Resetting cached state is best-effort; the files are already gone and a
    # missing state directory must not make a successful deletion look failed.
    state_set log_file "" || true
    state_set current_app "" || true
    state_set last_seen_app "" || true
    state_set excluded_app "" || true
    printf 'Deleted activity data from %d file(s).\n' "$selected"
    return 0
}

cmd_config() {
    local action=${1:-show}
    local editor=""

    wdmtg_init_paths
    config_ensure_file || die "$EX_NOPERM" "cannot create the configuration file"

    case "$action" in
        show | "")
            config_load
            config_show
            ;;
        path)
            printf '%s\n' "$WDMTG_CONFIG_FILE"
            ;;
        edit)
            editor=${VISUAL:-${EDITOR:-vi}}
            local -a editor_cmd=()
            read -r -a editor_cmd <<<"$editor" || true
            if ((${#editor_cmd[@]} == 0)); then
                editor_cmd=(vi)
            fi
            "${editor_cmd[@]}" "$WDMTG_CONFIG_FILE" ||
                die "$EX_SOFTWARE" "editor exited with an error"
            ;;
        init)
            printf 'Configuration ready: %s\n' "$WDMTG_CONFIG_FILE"
            ;;
        -h | --help)
            printf 'Usage: detective.sh config [show|path|edit|init]\n'
            ;;
        *)
            die "$EX_USAGE" "unknown config action: $action"
            ;;
    esac
    return 0
}

cmd_build() {
    wdmtg_init_paths
    wdmtg_ensure_dirs || die "$EX_NOPERM" "cannot create data directories"
    config_load
    if ! build_idle_helper; then
        die "$EX_UNAVAILABLE" "idle helper build failed"
    fi
    printf 'Idle helper built: %s\n' "$(idle_helper_path)"
    return 0
}

cmd_report() {
    local date=""
    local color=0
    local no_color=0

    wdmtg_init_paths

    while (($# > 0)); do
        case "$1" in
            --date)
                (($# >= 2)) || die "$EX_USAGE" "--date needs YYYY-MM-DD"
                date=$2
                shift 2
                ;;
            --no-color)
                no_color=1
                shift
                ;;
            -h | --help)
                printf 'Usage: detective.sh report [--date YYYY-MM-DD] [--no-color]\n'
                return 0
                ;;
            *)
                die "$EX_USAGE" "unknown report option: $1"
                ;;
        esac
    done

    if [[ -z $date ]]; then
        date=$(date '+%F')
    fi
    valid_date "$date" || die "$EX_USAGE" "invalid date: $date (expected YYYY-MM-DD)"

    if ((no_color == 0)); then
        color=$(report_color_choice)
    fi
    report_daily "$date" "$color"
}

cmd_weekly() {
    local date=""
    local color=0
    local no_color=0

    wdmtg_init_paths

    while (($# > 0)); do
        case "$1" in
            --date)
                (($# >= 2)) || die "$EX_USAGE" "--date needs YYYY-MM-DD"
                date=$2
                shift 2
                ;;
            --no-color)
                no_color=1
                shift
                ;;
            -h|--help)
                printf 'Usage: detective.sh weekly [--date YYYY-MM-DD] [--no-color]\n'
                return 0
                ;;
            *)
                die "$EX_USAGE" "unknown weekly option: $1"
                ;;
        esac
    done

    if [[ -z $date ]]; then
        date=$(date '+%F')
    fi
    valid_date "$date" || die "$EX_USAGE" "invalid date: $date (expected YYYY-MM-DD)"

    if ((no_color == 0)); then
        color=$(report_color_choice)
    fi
    report_weekly "$date" "$color"
}

report_color_choice() {
    if [[ -n ${NO_COLOR:-} ]]; then
        printf '0'
    elif [[ -t 1 ]]; then
        printf '1'
    else
        printf '0'
    fi
}
