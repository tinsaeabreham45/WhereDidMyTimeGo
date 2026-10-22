#!/usr/bin/env bash
#
# WhereDidMyTimeGo test harness.
#
# These tests use temporary directories. They do not read or write the real
# XDG data/state directories, and they do not load a KWin script. The live
# detector is tested separately by running the program and switching windows.
#
set -u
set -o pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/.." && pwd -P)
WDMTG_ROOT_DIR="$ROOT_DIR"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wdmtg-tests.XXXXXX")

cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

# Test helpers run in this shell, so point the program at a private tree.
export WDMTG_DATA_DIR="$TEST_TMP/data"
export WDMTG_STATE_DIR="$TEST_TMP/state"
export WDMTG_CONFIG_DIR="$TEST_TMP/config"
export WDMTG_RUNTIME_DIR="$TEST_TMP/run"

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/detector.sh
source "$ROOT_DIR/lib/detector.sh"
# shellcheck source=../lib/idle.sh
source "$ROOT_DIR/lib/idle.sh"
# shellcheck source=../lib/reports.sh
source "$ROOT_DIR/lib/reports.sh"
# shellcheck source=../lib/alerts.sh
source "$ROOT_DIR/lib/alerts.sh"
# shellcheck source=../lib/tracker.sh
source "$ROOT_DIR/lib/tracker.sh"
# shellcheck source=../lib/data.sh
source "$ROOT_DIR/lib/data.sh"

wdmtg_init_paths
wdmtg_ensure_dirs || {
    printf 'cannot create test directories\n' >&2
    exit 1
}

TEST_NUMBER=0
FAILURES=0

ok() {
    TEST_NUMBER=$((TEST_NUMBER + 1))
    printf 'ok %d - %s\n' "$TEST_NUMBER" "$1"
}

not_ok() {
    TEST_NUMBER=$((TEST_NUMBER + 1))
    FAILURES=$((FAILURES + 1))
    printf 'not ok %d - %s\n' "$TEST_NUMBER" "$1"
    if (($# > 1)); then
        printf '  %s\n' "$2"
    fi
}

assert_eq() {
    local expected=${1-}
    local actual=${2-}
    local name=${3-assertion}

    if [[ $expected == "$actual" ]]; then
        ok "$name"
    else
        not_ok "$name" "expected '$expected', got '$actual'"
    fi
}

assert_file_contains() {
    local file=${1:?}
    local needle=${2:?}
    local name=${3:-file contains value}

    if [[ -f $file ]] && grep -Fq -- "$needle" "$file"; then
        ok "$name"
    else
        not_ok "$name" "did not find '$needle' in $file"
    fi
}

assert_file_mode() {
    local file=${1:?}
    local expected=${2:?}
    local name=${3:-file mode}

    if [[ ! -e $file ]]; then
        not_ok "$name" "missing file: $file"
        return
    fi

    local actual
    actual=$(stat -c '%a' -- "$file")
    assert_eq "$expected" "$actual" "$name"
}

# --- tests -----------------------------------------------------------------

test_sanitize_csv_field() {
    local input=$'a,b\tc\nd\re'
    assert_eq 'a;b c d e' "$(sanitize_csv_field "$input")" "CSV field sanitization"
    assert_eq 'plain' "$(sanitize_csv_field 'plain')" "CSV plain value unchanged"
    assert_eq '' "$(sanitize_csv_field '')" "CSV empty value"
}

test_normalize_app_id() {
    assert_eq 'org.kde.konsole' \
        "$(normalize_app_id 'org.kde.konsole' 'konsole' '' 1234)" \
        "desktop file preferred for app id"
    assert_eq 'firefox' \
        "$(normalize_app_id '' 'Firefox' '' 0)" \
        "window class lowercased"
    assert_eq 'some.app' \
        "$(normalize_app_id 'Some.App.desktop' '' '' 0)" \
        "desktop suffix removed"
    assert_eq 'telegram' \
        "$(normalize_app_id '137646' 'Telegram' '' 0)" \
        "numeric desktop id falls back to window class"
    assert_eq 'org.telegram.desktop' \
        "$(normalize_app_id '137646' 'org.telegram.desktop' '' 0)" \
        "flatpak-style window class keeps its id suffix"
    assert_eq 'unknown' \
        "$(normalize_app_id '' '' '' 0)" \
        "unknown fallback"
}

test_log_file_for_epoch() {
    local file
    file=$(TZ=UTC log_file_for_epoch 0)
    assert_eq "$WDMTG_DATA_DIR/events-1970-01.csv" "$file" "monthly log path from epoch"
}

test_append_event() {
    local file
    append_event app 'org.kde.konsole' 'org.kde.konsole' 'org.kde.konsole' 4242 kwin test-run >/dev/null
    file=$WDMTG_LAST_LOG

    assert_file_contains "$file" "$WDMTG_CSV_HEADER" "append_event writes CSV header"
    assert_file_contains "$file" ',app,org.kde.konsole,org.kde.konsole,org.kde.konsole,4242,kwin,test-run' \
        "append_event writes expected fields"
    assert_file_mode "$file" 600 "event log is private"

    local fields
    fields=$(awk -F',' 'END { print NF }' "$file")
    assert_eq '9' "$fields" "event log has nine fields"
}

test_state_roundtrip() {
    state_set current_app org.kde.konsole
    state_set last_event 12345
    state_set status running

    assert_eq 'org.kde.konsole' "$(state_get current_app)" "state_set/state_get current app"
    assert_eq '12345' "$(state_get last_event)" "state_set/state_get numeric value"
    assert_eq 'running' "$(state_get status)" "state_set preserves unrelated keys"
    assert_file_mode "$WDMTG_STATE_FILE" 600 "state file is private"
}

test_parse_monitor_line() {
    local raw fields
    raw=$(jq -cn --arg token 'run-1' '{
        type: "method_call",
        interface: "org.wheredidmytimego.Tracker",
        member: "Event",
        payload: {
            type: "s",
            data: [
                ({
                    token: $token,
                    event: "active",
                    app_class: "org.kde.konsole",
                    app_name: "konsole",
                    desktop_file: "org.kde.konsole",
                    pid: 4242
                } | tojson)
            ]
        }
    }')

    if fields=$(parse_monitor_line "$raw" 'run-1'); then
        assert_eq $'active\torg.kde.konsole\tkonsole\torg.kde.konsole\t4242' \
            "$fields" "parse_monitor_line returns TSV fields"
    else
        not_ok "parse_monitor_line accepts a valid event"
    fi

    if parse_monitor_line "$raw" 'wrong-run' >/dev/null; then
        not_ok "parse_monitor_line rejects another run token"
    else
        ok "parse_monitor_line rejects another run token"
    fi

    if parse_monitor_line 'not json' 'run-1' >/dev/null; then
        not_ok "parse_monitor_line rejects malformed JSON"
    else
        ok "parse_monitor_line rejects malformed JSON"
    fi

    if parse_monitor_line '{"member":"Other"}' 'run-1' >/dev/null; then
        not_ok "parse_monitor_line rejects unrelated methods"
    else
        ok "parse_monitor_line rejects unrelated methods"
    fi

    local signal
    signal=$(jq -cn '{
        type: "signal",
        interface: "org.freedesktop.ScreenSaver",
        member: "ActiveChanged",
        payload: { type: "b", data: [true] }
    }')
    fields=$(parse_monitor_line "$signal" 'run-1') || fields=""
    assert_eq $'lock\t\t\t\t0' "$fields" "parse_monitor_line maps lock signals"

    signal=$(jq -cn '{
        type: "signal",
        interface: "org.freedesktop.ScreenSaver",
        member: "ActiveChanged",
        payload: { type: "b", data: [false] }
    }')
    fields=$(parse_monitor_line "$signal" 'run-1') || fields=""
    assert_eq $'unlock\t\t\t\t0' "$fields" "parse_monitor_line maps unlock signals"
}

test_tracker_lock() {
    local holder lock_state

    rm -f -- "$WDMTG_LOCK_FILE"
    flock -n "$WDMTG_LOCK_FILE" -c 'sleep 1' &
    holder=$!
    sleep 0.2

    lock_state=0
    tracker_is_locked || lock_state=$?
    if ((lock_state == 0)); then
        ok "tracker_is_locked detects a held lock"
    else
        not_ok "tracker_is_locked detects a held lock" "status $lock_state"
    fi
    wait "$holder" 2>/dev/null || true

    lock_state=0
    tracker_is_locked || lock_state=$?
    if ((lock_state == 1)); then
        ok "tracker_is_locked reports a free lock"
    else
        not_ok "tracker_is_locked reports a free lock" "status $lock_state"
    fi
}

test_count_events_today() {
    local file start today yesterday
    file="$TEST_TMP/count.csv"
    start=$(date -d 'today 00:00' '+%s')
    today=$((start + 60))
    yesterday=$((start - 3600))

    {
        printf '%s\n' "$WDMTG_CSV_HEADER"
        printf '%s,iso,app,a,a,a,1,kwin,r\n' "$today"
        printf '%s,iso,app,b,b,b,2,kwin,r\n' "$today"
        printf '%s,iso,app,c,c,c,3,kwin,r\n' "$yesterday"
        printf 'malformed,line\n'
        printf '%s,iso,none,,,,0,kwin,r\n' "$today"
    } >"$file"

    assert_eq '2' "$(count_events_today "$file")" "count_events_today counts app changes only"
    assert_eq '0' "$(count_events_today "$TEST_TMP/missing.csv")" "count_events_today handles missing log"
}

test_duplicate_start_with_held_lock() {
    local holder rc output
    rm -f -- "$WDMTG_PID_FILE" "$WDMTG_READY_FILE"
    flock -n "$WDMTG_LOCK_FILE" -c 'sleep 1' &
    holder=$!
    sleep 0.2

    output=$(
        WDMTG_DATA_DIR="$WDMTG_DATA_DIR" \
        WDMTG_STATE_DIR="$WDMTG_STATE_DIR" \
        WDMTG_CONFIG_DIR="$WDMTG_CONFIG_DIR" \
        WDMTG_RUNTIME_DIR="$WDMTG_RUNTIME_DIR" \
        "$ROOT_DIR/detective.sh" start 2>&1
    )
    rc=$?
    wait "$holder" 2>/dev/null || true

    assert_eq '75' "$rc" "duplicate start returns 75"
    if [[ $output == *"already running"* ]]; then
        ok "duplicate start explains the problem"
    else
        not_ok "duplicate start explains the problem" "$output"
    fi
}

test_stopped_status_and_stop() {
    local output rc
    rm -f -- "$WDMTG_PID_FILE" "$WDMTG_READY_FILE"
    output=$(
        WDMTG_DATA_DIR="$WDMTG_DATA_DIR" \
        WDMTG_STATE_DIR="$WDMTG_STATE_DIR" \
        WDMTG_CONFIG_DIR="$WDMTG_CONFIG_DIR" \
        WDMTG_RUNTIME_DIR="$WDMTG_RUNTIME_DIR" \
        "$ROOT_DIR/detective.sh" status 2>&1
    )
    rc=$?
    assert_eq '3' "$rc" "status returns 3 when stopped"
    if [[ $output == *"Status: stopped"* ]]; then
        ok "status prints stopped state"
    else
        not_ok "status prints stopped state" "$output"
    fi

    output=$(
        WDMTG_DATA_DIR="$WDMTG_DATA_DIR" \
        WDMTG_STATE_DIR="$WDMTG_STATE_DIR" \
        WDMTG_RUNTIME_DIR="$WDMTG_RUNTIME_DIR" \
        "$ROOT_DIR/detective.sh" stop 2>&1
    )
    rc=$?
    assert_eq '0' "$rc" "stop is idempotent when not running"
}

test_now_millis() {
    local value
    if value=$(now_millis) && [[ $value =~ ^[0-9]+$ ]] && ((value > 1000000000000)); then
        ok "now_millis returns epoch milliseconds"
    else
        not_ok "now_millis returns epoch milliseconds" "got '$value'"
    fi
}

test_config_parsing() {
    local old_config=$WDMTG_CONFIG_FILE
    local config_dir="$TEST_TMP/config-parse"
    local config="$config_dir/config"

    mkdir -p -- "$config_dir"
    cat >"$config" <<'EOF'
idle_timeout_seconds = 120
alert_cooldown_seconds = 600
notifications = false
browsing_category = Web
sleep_gap_seconds = 8

Category Tools = foo, bar-*
exclude = secret*
Limit category:Tools = 5
Limit app:mpv = 10
Goal Coding = 60
EOF
    WDMTG_CONFIG_FILE=$config
    config_load

    assert_eq '120' "$WDMTG_CFG_IDLE_TIMEOUT" "config: idle timeout parsed"
    assert_eq '600' "$WDMTG_CFG_ALERT_COOLDOWN" "config: alert cooldown parsed"
    assert_eq '0' "$WDMTG_CFG_NOTIFICATIONS" "config: notifications parsed"
    assert_eq 'Web' "$WDMTG_CFG_BROWSING_CATEGORY" "config: browsing category parsed"
    assert_eq '8' "$WDMTG_CFG_SLEEP_GAP" "config: sleep gap parsed"
    assert_eq 'Tools' "$(category_for_app foo)" "config: category glob matches"
    assert_eq 'Tools' "$(category_for_app bar-window)" "config: category prefix glob matches"
    assert_eq 'Other' "$(category_for_app org.kde.konsole)" "config: user list replaces built-ins"
    if app_is_excluded secret-tool; then
        ok "config: exclusion glob matches"
    else
        not_ok "config: exclusion glob matches"
    fi
    assert_eq '2' "${#WDMTG_LIMIT_TYPES[@]}" "config: two limits parsed"
    assert_eq '300' "${WDMTG_LIMIT_MINUTES[0]}" "config: category limit converted to seconds"
    assert_eq '600' "${WDMTG_LIMIT_MINUTES[1]}" "config: app limit converted to seconds"
    assert_eq '3600' "${WDMTG_GOAL_MINUTES[0]}" "config: daily goal converted to seconds"

    WDMTG_CONFIG_FILE=$old_config
    config_load
}

test_config_defaults() {
    local old_config=$WDMTG_CONFIG_FILE
    local old_config_dir=$WDMTG_CONFIG_DIR
    local config_dir="$TEST_TMP/config-default"
    local config="$config_dir/config"

    WDMTG_CONFIG_DIR=$config_dir
    WDMTG_CONFIG_FILE=$config
    config_ensure_file || {
        not_ok "config: default file is created"
        WDMTG_CONFIG_FILE=$old_config
        WDMTG_CONFIG_DIR=$old_config_dir
        config_load
        return
    }

    if [[ -s $config ]]; then
        ok "config: default file is created"
    else
        not_ok "config: default file is created"
    fi
    config_load
    assert_eq 'Coding' "$(category_for_app org.kde.konsole)" "config: default categories include Konsole"
    assert_eq 'Browsing' "$(category_for_app google-chrome)" "config: default categories include Chrome"
    assert_eq 'Communication' "$(category_for_app org.telegram.desktop)" \
        "config: default categories include Telegram"
    assert_eq 'Other' "$(category_for_app mystery-app)" "config: unknown apps are Other"

    WDMTG_CONFIG_FILE=$old_config
    WDMTG_CONFIG_DIR=$old_config_dir
    config_load
}

test_report_interval_math() {
    local old_data=$WDMTG_DATA_DIR
    local old_config=$WDMTG_CONFIG_FILE
    local data="$TEST_TMP/report-data"
    local config="$TEST_TMP/report-config/config"
    local day="2026-01-15"
    local day_start
    local segments="$TEST_TMP/report-segments"
    local map="$TEST_TMP/report-map"
    local aggregate="$TEST_TMP/report-aggregate"
    local output=""

    mkdir -p -- "$data" "$(dirname -- "$config")"
    cat >"$config" <<'EOF'
category Coding = code
category Browsing = browser
exclude = secret*
goal Coding = 30
EOF
    WDMTG_DATA_DIR=$data
    WDMTG_CONFIG_FILE=$config
    config_load

    day_start=$(day_start_epoch "$day")
    cat >"$data/events-2026-01.csv" <<EOF
epoch,iso8601,event,app_id,app_class,desktop_file,pid,source,run_id
$((day_start + 32400)),2026-01-15T18:00:00+0300,start,,,,0,cli,test
$((day_start + 36000)),2026-01-15T19:00:00+0300,app,code,code,code,1,kwin,test
$((day_start + 37800)),2026-01-15T19:30:00+0300,app,browser,browser,browser,2,kwin,test
$((day_start + 38700)),2026-01-15T19:45:00+0300,idle,,,,0,idle,test
$((day_start + 39600)),2026-01-15T20:00:00+0300,active,,,,0,idle,test
$((day_start + 39600)),2026-01-15T20:00:00+0300,app,code,code,code,1,kwin,test
$((day_start + 40800)),2026-01-15T20:20:00+0300,stop,,,,0,cli,test
$((day_start + 43200)),2026-01-15T21:00:00+0300,start,,,,0,cli,test
$((day_start + 43200)),2026-01-15T21:00:00+0300,app,secret-tool,secret-tool,secret-tool,3,kwin,test
$((day_start + 43800)),2026-01-15T21:10:00+0300,app,code,code,code,1,kwin,test
$((day_start + 44400)),2026-01-15T21:20:00+0300,stop,,,,0,cli,test
malformed,line
$((day_start + 45000)),2026-01-15T21:30:00+0300,app,code,code,code,1,kwin,test
EOF

    report_build_segments 0 >"$segments"
    report_map_apps "$segments" "$map"
    report_aggregate "$segments" "$map" "$day_start" "$((day_start + 86400))" \
        "$day_start" Browsing >"$aggregate"

    assert_eq '4500' "$(report_agg_field "$aggregate" T)" "report: total interval seconds"
    assert_eq '3600' "$(awk -F'\t' '$1=="C" && $2=="Coding"{print $3}' "$aggregate")" \
        "report: coding category total"
    assert_eq '900' "$(awk -F'\t' '$1=="C" && $2=="Browsing"{print $3}' "$aggregate")" \
        "report: browsing category total"
    assert_eq '3600' "$(awk -F'\t' '$1=="A" && $2=="code"{print $3}' "$aggregate")" \
        "report: app total"
    assert_eq '1800' "$(awk -F'\t' '$1=="S" && $2=="code" && $5>max{max=$5} END{print max+0}' "$aggregate")" \
        "report: longest app segment"
    assert_eq '900' "$(awk -F'\t' '$1=="B"{print $4}' "$aggregate")" \
        "report: longest browsing segment"
    if grep -q $'secret-tool\t__EXCLUDED__' "$map"; then
        ok "report: excluded app is marked and skipped"
    else
        not_ok "report: excluded app is marked and skipped"
    fi

    output=$(report_daily "$day" 0)
    if [[ $output == *"Total tracked: 1h 15m"* ]]; then
        ok "report: daily total is formatted"
    else
        not_ok "report: daily total is formatted" "$output"
    fi
    if [[ $output == *"Coding"* && $output == *"code"* && $output == *"Longest sessions"* ]]; then
        ok "report: daily output contains apps, categories, and sessions"
    else
        not_ok "report: daily output contains apps, categories, and sessions" "$output"
    fi

    output=$(report_daily 2026-01-14 0)
    if [[ $output == *"No tracked activity"* ]]; then
        ok "report: empty day is handled"
    else
        not_ok "report: empty day is handled" "$output"
    fi

    output=$(report_weekly "$day" 0)
    if [[ $output == *"week of 2026-01-12"* &&
          $output == *"Total tracked: 1h 15m"* &&
          $output == *"Thu 2026-01-15"* ]]; then
        ok "report: weekly report uses Monday-Sunday and totals"
    else
        not_ok "report: weekly report uses Monday-Sunday and totals" "$output"
    fi

    WDMTG_DATA_DIR=$old_data
    WDMTG_CONFIG_FILE=$old_config
    config_load
}

test_report_monday() {
    assert_eq '2026-01-12' "$(report_monday 2026-01-15)" "report: Thursday maps to Monday"
    assert_eq '2026-01-12' "$(report_monday 2026-01-12)" "report: Monday maps to itself"
    assert_eq '2026-01-12' "$(report_monday 2026-01-18)" "report: Sunday maps to previous Monday"
}

test_alerts() {
    local old_data=$WDMTG_DATA_DIR
    local old_config=$WDMTG_CONFIG_FILE
    local data="$TEST_TMP/alert-data"
    local config="$TEST_TMP/alert-config/config"
    local today start key first second app_key
    local log_file

    mkdir -p -- "$data" "$(dirname -- "$config")"
    cat >"$config" <<'EOF'
notifications = false
alert_cooldown_seconds = 1800
category Coding = code
limit category:Coding = 5
EOF

    today=$(date '+%F')
    start=$(day_start_epoch "$today")
    log_file="$data/events-$(date '+%Y-%m').csv"
    cat >"$log_file" <<EOF
epoch,iso8601,event,app_id,app_class,desktop_file,pid,source,run_id
$((start + 60)),iso,start,,,,0,cli,test
$((start + 60)),iso,app,code,code,code,1,kwin,test
$((start + 660)),iso,app,other,other,other,2,kwin,test
$((start + 660)),iso,stop,,,,0,cli,test
EOF

    rm -f -- "$WDMTG_PID_FILE" "$WDMTG_READY_FILE"
    WDMTG_DATA_DIR=$data
    WDMTG_CONFIG_FILE=$config
    WDMTG_PAUSED=0
    WDMTG_LOCKED=0
    WDMTG_IDLE=0
    config_load

    key="alert_last_${today}_category_Coding"
    state_set "$key" 0
    alerts_check || true
    first=$(state_get "$key" 2>/dev/null || true)
    if [[ $first =~ ^[0-9]+$ ]] && ((first > 0)); then
        ok "alerts: limit reached records a cooldown"
    else
        not_ok "alerts: limit reached records a cooldown" "got '$first'"
    fi

    sleep 1
    alerts_check || true
    second=$(state_get "$key" 2>/dev/null || true)
    assert_eq "$first" "$second" "alerts: cooldown prevents a repeat"

    cat >>"$config" <<'EOF'
limit app:code = 20
EOF
    config_load
    app_key="alert_last_${today}_app_code"
    alerts_check || true
    if state_get "$app_key" >/dev/null 2>&1; then
        not_ok "alerts: usage below a limit produces no alert"
    else
        ok "alerts: usage below a limit produces no alert"
    fi

    # Exercise the notification path with a fake notify-send, never the real
    # desktop session.
    local old_path=$PATH
    local fakebin="$TEST_TMP/fakebin"
    local notify_log="$TEST_TMP/notify.log"
    mkdir -p -- "$fakebin"
    cat >"$fakebin/notify-send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$notify_log"
EOF
    chmod +x "$fakebin/notify-send"
    cat >"$config" <<'EOF'
notifications = true
alert_cooldown_seconds = 1800
category Coding = code
limit category:Coding = 5
EOF
    config_load
    state_set "$key" 0
    PATH="$fakebin:$PATH"
    alerts_check || true
    PATH=$old_path
    if [[ -s $notify_log ]] && grep -Fq 'Coding limit reached' "$notify_log"; then
        ok "alerts: enabled notifications call notify-send"
    else
        not_ok "alerts: enabled notifications call notify-send" "$(cat "$notify_log" 2>/dev/null || true)"
    fi

    WDMTG_DATA_DIR=$old_data
    WDMTG_CONFIG_FILE=$old_config
    config_load
}

test_report_midnight_split() {
    local old_data=$WDMTG_DATA_DIR
    local old_config=$WDMTG_CONFIG_FILE
    local data="$TEST_TMP/midnight-data"
    local config="$TEST_TMP/midnight-config/config"
    local start16 start17
    local segments="$TEST_TMP/midnight-segments"
    local map="$TEST_TMP/midnight-map"
    local aggregate="$TEST_TMP/midnight-aggregate"

    mkdir -p -- "$data" "$(dirname -- "$config")"
    cat >"$config" <<'EOF'
category Coding = code
category Browsing = browser
EOF
    WDMTG_DATA_DIR=$data
    WDMTG_CONFIG_FILE=$config
    config_load

    start16=$(day_start_epoch 2026-01-16)
    start17=$(day_start_epoch 2026-01-17)
    cat >"$data/events-2026-01.csv" <<EOF
epoch,iso8601,event,app_id,app_class,desktop_file,pid,source,run_id
$((start16 + 85800)),2026-01-16T23:50:00+0300,start,,,,0,cli,test
$((start16 + 85800)),2026-01-16T23:50:00+0300,app,code,code,code,1,kwin,test
$((start17 + 600)),2026-01-17T00:10:00+0300,app,browser,browser,browser,2,kwin,test
$((start17 + 1800)),2026-01-17T00:30:00+0300,stop,,,,0,cli,test
EOF

    report_build_segments 0 >"$segments"
    report_map_apps "$segments" "$map"
    report_aggregate "$segments" "$map" "$start16" "$((start17 + 86400))" \
        "$start16,$start17" Browsing >"$aggregate"

    assert_eq '600' "$(report_agg_field "$aggregate" D 0)" "report: pre-midnight portion"
    assert_eq '1800' "$(report_agg_field "$aggregate" D 1)" "report: post-midnight portion"
    assert_eq '2400' "$(report_agg_field "$aggregate" T)" "report: midnight split preserves total"

    WDMTG_DATA_DIR=$old_data
    WDMTG_CONFIG_FILE=$old_config
    config_load
}

test_sleep_gap_detection() {
    if tracker_sleep_gap_detected 20 5 5; then
        ok "sleep gap: wall-clock jump is detected"
    else
        not_ok "sleep gap: wall-clock jump is detected"
    fi
    if tracker_sleep_gap_detected 5 5 5; then
        not_ok "sleep gap: normal elapsed time is ignored"
    else
        ok "sleep gap: normal elapsed time is ignored"
    fi
    if tracker_sleep_gap_detected 20 5 60; then
        not_ok "sleep gap: threshold is respected"
    else
        ok "sleep gap: threshold is respected"
    fi
}

test_export_and_delete() {
    local old_data=$WDMTG_DATA_DIR
    local data="$TEST_TMP/export-data"
    local export_csv="$TEST_TMP/export.csv"
    local export_json="$TEST_TMP/export.json"
    local output rc mar_before mar_after apr feb_event holder

    mkdir -p -- "$data"
    feb_event=$(( $(day_start_epoch 1970-02-01) + 300 ))
    printf '%s\n%s\n%s\n' \
        "$WDMTG_CSV_HEADER" \
        '100,1970-01-01T00:01:40+0000,app,foo,foo,foo,1,kwin,r' \
        '200,1970-01-01T00:03:20+0000,stop,,,,0,cli,r' >"$data/events-1970-01.csv"
    printf '%s\n%s\n' \
        "$WDMTG_CSV_HEADER" \
        "$feb_event,1970-02-01T00:05:00+0000,app,bar,bar,bar,2,kwin,r" >"$data/events-1970-02.csv"

    WDMTG_DATA_DIR=$data
    output=$(cmd_export --format csv 2>&1)
    rc=$?
    assert_eq '0' "$rc" "export: csv exits successfully"
    assert_eq '4' "$(grep -c . <<<"$output")" "export: csv contains header and three events"

    output=$(cmd_export --format json 2>&1)
    if [[ $(jq 'length' <<<"$output" 2>/dev/null) == 3 ]]; then
        ok "export: json is valid and contains three events"
    else
        not_ok "export: json is valid and contains three events" "$output"
    fi

    (cmd_export --output "$export_csv") >/dev/null 2>&1
    if [[ -s $export_csv ]]; then
        ok "export: writes a file"
    else
        not_ok "export: writes a file"
    fi
    if (cmd_export --output "$export_csv") >/dev/null 2>&1; then
        not_ok "export: refuses to overwrite without --force"
    else
        ok "export: refuses to overwrite without --force"
    fi
    if (cmd_export --format json --output "$data/events-1970-03.csv") >/dev/null 2>&1; then
        not_ok "export: refuses to write an events file into live data"
    else
        ok "export: refuses to write an events file into live data"
    fi
    if [[ ! -e $data/events-1970-03.csv ]]; then
        ok "export: rejected export leaves live data untouched"
    else
        not_ok "export: rejected export leaves live data untouched"
    fi

    output=$(cmd_delete 2>&1)
    rc=$?
    assert_eq '64' "$rc" "delete: refuses without --yes"
    if [[ -f $data/events-1970-01.csv ]]; then
        ok "delete: data is untouched without --yes"
    else
        not_ok "delete: data is untouched without --yes"
    fi

    output=$(cmd_delete --before 1970-02-01 --yes 2>&1)
    rc=$?
    assert_eq '0' "$rc" "delete: --yes succeeds"
    if [[ ! -f $data/events-1970-01.csv && -f $data/events-1970-02.csv ]]; then
        ok "delete: --before removes only older months"
    else
        not_ok "delete: --before removes only older months" "$output"
    fi

    mar_before=$(day_start_epoch 1970-03-01)
    mar_after=$(day_start_epoch 1970-03-20)
    apr=$(day_start_epoch 1970-04-01)
    printf '%s\n%s\n%s\n' \
        "$WDMTG_CSV_HEADER" \
        "$((mar_before + 60)),1970-03-01T00:01:00+0000,app,mar-old,mar-old,mar-old,1,kwin,r" \
        "$((mar_after + 60)),1970-03-20T00:01:00+0000,app,mar-new,mar-new,mar-new,1,kwin,r" \
        >"$data/events-1970-03.csv"
    printf '%s\n%s\n' \
        "$WDMTG_CSV_HEADER" \
        "$((apr + 60)),1970-04-01T00:01:00+0000,app,apr-only,apr-only,apr-only,1,kwin,r" \
        >"$data/events-1970-04.csv"

    output=$(cmd_delete --before 1970-03-15 --yes 2>&1)
    rc=$?
    assert_eq '0' "$rc" "delete: mid-month cutoff succeeds"
    if [[ -f $data/events-1970-03.csv ]] &&
        grep -Fq ',app,mar-new,' "$data/events-1970-03.csv" &&
        ! grep -Fq ',app,mar-old,' "$data/events-1970-03.csv"; then
        ok "delete: mid-month cutoff keeps only newer events"
    else
        not_ok "delete: mid-month cutoff keeps only newer events" "$output"
    fi

    output=$(cmd_delete --before 1970-04-02 --yes 2>&1)
    rc=$?
    assert_eq '0' "$rc" "delete: cutoff that empties a month succeeds"
    if [[ ! -f $data/events-1970-04.csv ]]; then
        ok "delete: cutoff removes a month left with only its header"
    else
        not_ok "delete: cutoff removes a month left with only its header" "$output"
    fi

    printf '%s\n' "$WDMTG_CSV_HEADER" >"$data/events-1970-05.csv"
    rm -f -- "$WDMTG_PID_FILE"
    flock -n "$WDMTG_LOCK_FILE" -c 'sleep 1' &
    holder=$!
    sleep 0.2
    output=$(cmd_delete --yes 2>&1)
    rc=$?
    assert_eq '75' "$rc" "delete: refuses while the tracker lock is held"
    if [[ -f $data/events-1970-05.csv ]]; then
        ok "delete: locked deletion leaves data untouched"
    else
        not_ok "delete: locked deletion leaves data untouched"
    fi
    wait "$holder" 2>/dev/null || true

    WDMTG_DATA_DIR=$old_data
}

test_tracker_event_handlers() {
    local old_data=$WDMTG_DATA_DIR
    local old_config=$WDMTG_CONFIG_FILE
    local data="$TEST_TMP/handler-data"
    local config="$TEST_TMP/handler-config/config"
    local file

    mkdir -p -- "$data" "$(dirname -- "$config")"
    cat >"$config" <<'EOF'
category Coding = code
exclude = secret*
EOF
    WDMTG_DATA_DIR=$data
    WDMTG_CONFIG_FILE=$config
    config_load

    WDMTG_RUN_ID="handler-test"
    WDMTG_CURRENT_APP=""
    WDMTG_CURRENT_SINCE=""
    WDMTG_PENDING_NONE=0
    WDMTG_PENDING_NONE_AT=""
    WDMTG_PAUSED=0
    WDMTG_LOCKED=0
    WDMTG_IDLE=0

    tracker_handle_active active code code code 11
    file=$WDMTG_LAST_LOG
    tracker_handle_lock
    WDMTG_LOCKED=0
    tracker_handle_idle_event idle
    tracker_handle_suspend "$(now_epoch)" "$(now_epoch)"

    assert_eq '1' "$(grep -c ',app,code,' "$file" || true)" "handler: app event logged"
    assert_eq '1' "$(grep -c ',lock,' "$file" || true)" "handler: lock event logged"
    assert_eq '1' "$(grep -c ',idle,' "$file" || true)" "handler: idle event logged"
    assert_eq '1' "$(grep -c ',sleep,' "$file" || true)" "handler: suspend closes the interval"
    assert_eq '1' "$(grep -c ',wake,' "$file" || true)" "handler: wake event logged"

    WDMTG_LOCKED=0
    WDMTG_IDLE=0
    tracker_handle_active active secret-tool secret-tool secret-tool 12
    assert_eq '1' "$(grep -c ',excluded,secret-tool,' "$file" || true)" \
        "handler: excluded app is marked, not counted"

    WDMTG_DATA_DIR=$old_data
    WDMTG_CONFIG_FILE=$old_config
    config_load
}


test_none_debounce() {
    local old_data=$WDMTG_DATA_DIR
    local file debounce=500

    WDMTG_DATA_DIR="$TEST_TMP/debounce-data"
    mkdir -p -- "$WDMTG_DATA_DIR"
    WDMTG_RUN_ID="debounce-run"
    WDMTG_NONE_DEBOUNCE_MS=$debounce
    WDMTG_CURRENT_APP=""
    WDMTG_CURRENT_SINCE=""
    WDMTG_PENDING_NONE=0
    WDMTG_PENDING_NONE_AT=""

    tracker_handle_active active org.kde.konsole konsole org.kde.konsole 111
    file=$WDMTG_LAST_LOG
    assert_eq '1' "$(grep -c ',app,org.kde.konsole,' -- "$file" || true)" \
        "debounce: first activation is logged"

    # A null activation is queued, not written immediately.
    tracker_handle_active none "" "" "" 0
    tracker_flush_pending_none "$WDMTG_PENDING_NONE_AT"
    assert_eq '0' "$(grep -c ',none,' -- "$file" || true)" \
        "debounce: nothing is logged inside the debounce window"
    assert_eq '1' "${WDMTG_PENDING_NONE:-}" "debounce: none event stays queued"

    # A new activation cancels the queued null event: Chrome follows Konsole
    # directly in the log, with no "none" row between them.
    tracker_handle_active active google-chrome chrome google-chrome 222
    assert_eq '0' "$(grep -c ',none,' -- "$file" || true)" \
        "debounce: window transition does not log none"
    assert_eq '2' "$(grep -c ',app,' -- "$file" || true)" \
        "debounce: both real applications are logged"
    assert_eq '0' "${WDMTG_PENDING_NONE:-}" "debounce: activation clears queued none"

    # With no follow-up activation, the null event is committed after the
    # debounce interval from its original arrival time.
    tracker_handle_active none "" "" "" 0
    tracker_flush_pending_none $((WDMTG_PENDING_NONE_AT + debounce))
    assert_eq '1' "$(grep -c ',none,' -- "$file" || true)" \
        "debounce: a lasting empty desktop is logged as none"
    assert_eq '' "${WDMTG_CURRENT_APP-}" "debounce: none clears current app"
    assert_eq '0' "${WDMTG_PENDING_NONE:-}" "debounce: flush clears pending flag"

    WDMTG_DATA_DIR=$old_data
}

test_shell_syntax() {
    local script failed=0
    while IFS= read -r -d '' script; do
        if ! bash -n "$script"; then
            printf '  syntax error: %s\n' "$script" >&2
            failed=1
        fi
    done < <(find "$ROOT_DIR" -maxdepth 2 -type f \( -name '*.sh' -o -name 'detective.sh' \) -print0)

    if ((failed == 0)); then
        ok "all shell files pass bash -n"
    else
        not_ok "all shell files pass bash -n"
    fi
}

test_sanitize_csv_field
test_normalize_app_id
test_log_file_for_epoch
test_append_event
test_state_roundtrip
test_parse_monitor_line
test_config_parsing
test_config_defaults
test_report_interval_math
test_report_midnight_split
test_report_monday
test_alerts
test_sleep_gap_detection
test_now_millis
test_none_debounce
test_tracker_event_handlers
test_export_and_delete
test_tracker_lock
test_count_events_today
test_duplicate_start_with_held_lock
test_stopped_status_and_stop
test_shell_syntax

printf '\n%d test(s), %d failure(s)\n' "$TEST_NUMBER" "$FAILURES"
if ((FAILURES > 0)); then
    exit 1
fi
exit 0
