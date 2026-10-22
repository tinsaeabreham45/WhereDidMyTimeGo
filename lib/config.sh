# shellcheck shell=bash
#
# Configuration and category matching for WhereDidMyTimeGo.
#
# The config is a deliberately small key=value file. It is parsed, never
# sourced, so a malformed config cannot execute commands.

config_trim() {
    local value=${1-}

    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

config_reset() {
    WDMTG_CFG_IDLE_TIMEOUT=300
    WDMTG_CFG_ALERT_COOLDOWN=1800
    WDMTG_CFG_NOTIFICATIONS=1
    WDMTG_CFG_BROWSING_CATEGORY="Browsing"
    WDMTG_CFG_SLEEP_GAP=5

    # Flat first-match rule list: rule N is name[N] + pattern[N].
    WDMTG_CAT_RULE_NAMES=()
    WDMTG_CAT_RULE_PATTERNS=()
    WDMTG_EXCLUDE_PATTERNS=()
    WDMTG_LIMIT_TYPES=()
    WDMTG_LIMIT_NAMES=()
    WDMTG_LIMIT_MINUTES=()
    WDMTG_GOAL_CATEGORIES=()
    WDMTG_GOAL_MINUTES=()
}

config_add_default_categories() {
    local name pattern

    while IFS=$'\t' read -r name pattern; do
        [[ -n $name && -n $pattern ]] || continue
        WDMTG_CAT_RULE_NAMES+=("$name")
        WDMTG_CAT_RULE_PATTERNS+=("$pattern")
    done <<'EOF'
Coding	org.kde.konsole
Coding	org.kde.kate
Coding	org.kde.kdevelop
Coding	org.kde.kwrite
Coding	code
Coding	code-oss
Coding	codium
Coding	jetbrains-*
Coding	idea
Coding	pycharm
Coding	webstorm
Coding	goland
Coding	clion
Coding	vim
Coding	nvim
Coding	emacs
Coding	org.gnome.builder
Coding	android-studio
Coding	sublime_text
Coding	zed
Browsing	firefox
Browsing	firefox-esr
Browsing	org.mozilla.firefox
Browsing	google-chrome
Browsing	chromium
Browsing	brave-*
Browsing	brave-browser
Browsing	microsoft-edge
Browsing	vivaldi-*
Browsing	opera
Communication	telegram*
Communication	org.telegram*
Communication	signal
Communication	org.signal.signal
Communication	slack
Communication	discord
Communication	zoom
Communication	teams
Communication	thunderbird
Communication	org.kde.neochat
Communication	element
Entertainment	vlc
Entertainment	mpv
Entertainment	spotify
Entertainment	steam
Entertainment	org.kde.audiotube
Entertainment	rhythmbox
Entertainment	totem
Entertainment	celluloid
Entertainment	haruna
EOF
}

config_enabled_value() {
    case ${1,,} in
        1 | true | yes | on) printf '1' ;;
        0 | false | no | off) printf '0' ;;
        *) return 1 ;;
    esac
}

config_add_category_rule() {
    local name
    local value=${2-}
    local pattern
    local -a parts=()

    name=$(config_trim "${1-}")
    if [[ -z $name || $name == *","* ]]; then
        warn "config: category name is empty or contains a comma: '$name'"
        return 0
    fi

    IFS=',' read -r -a parts <<<"$value" || true
    for pattern in "${parts[@]}"; do
        pattern=$(config_trim "$pattern")
        pattern=${pattern,,}
        [[ -n $pattern ]] || continue
        WDMTG_CAT_RULE_NAMES+=("$name")
        WDMTG_CAT_RULE_PATTERNS+=("$pattern")
    done
}

config_add_excludes() {
    local value=${1-}
    local pattern
    local -a parts=()

    IFS=',' read -r -a parts <<<"$value" || true
    for pattern in "${parts[@]}"; do
        pattern=$(config_trim "$pattern")
        pattern=${pattern,,}
        [[ -n $pattern ]] || continue
        WDMTG_EXCLUDE_PATTERNS+=("$pattern")
    done
}

config_add_limit() {
    local spec
    local type name
    local minutes=${2-}
    local -a parts=()

    spec=$(config_trim "${1-}")
    if [[ $spec != *:* ]]; then
        warn "config: limit needs 'app:PATTERN' or 'category:NAME', got '$spec'"
        return 0
    fi

    type=${spec%%:*}
    name=${spec#*:}
    type=${type,,}
    name=$(config_trim "$name")

    if [[ $type != app && $type != category ]] || [[ -z $name ]]; then
        warn "config: invalid limit '$spec'"
        return 0
    fi
    if [[ ! $minutes =~ ^[0-9]+$ ]] || ((minutes < 1 || minutes > 1440)); then
        warn "config: limit '$spec' needs a minute value from 1 to 1440"
        return 0
    fi

    if [[ $type == app ]]; then
        name=${name,,}
    fi
    WDMTG_LIMIT_TYPES+=("$type")
    WDMTG_LIMIT_NAMES+=("$name")
    WDMTG_LIMIT_MINUTES+=("$((minutes * 60))")
}

config_add_goal() {
    local category
    local minutes=${2-}

    category=$(config_trim "${1-}")
    if [[ -z $category ]]; then
        warn "config: goal needs a category name"
        return 0
    fi
    if [[ ! $minutes =~ ^[0-9]+$ ]] || ((minutes < 1 || minutes > 1440)); then
        warn "config: goal for '$category' needs a minute value from 1 to 1440"
        return 0
    fi

    WDMTG_GOAL_CATEGORIES+=("$category")
    WDMTG_GOAL_MINUTES+=("$((minutes * 60))")
}

config_load() {
    local line key value left lower_left lineno=0

    config_reset

    if [[ ! -f $WDMTG_CONFIG_FILE ]]; then
        config_add_default_categories
        return 0
    fi
    if [[ ! -r $WDMTG_CONFIG_FILE ]]; then
        warn "config: cannot read $WDMTG_CONFIG_FILE; using built-in defaults"
        config_add_default_categories
        return 0
    fi

    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        line=${line%%#*}
        line=$(config_trim "$line")
        [[ -n $line ]] || continue

        if [[ $line != *=* ]]; then
            warn "config: line $lineno has no '=' and was ignored"
            continue
        fi

        left=$(config_trim "${line%%=*}")
        value=$(config_trim "${line#*=}")
        lower_left=${left,,}

        case "$lower_left" in
            idle_timeout_seconds)
                if [[ $value =~ ^[0-9]+$ ]] && ((value >= 0 && value <= 86400)); then
                    WDMTG_CFG_IDLE_TIMEOUT=$value
                else
                    warn "config: idle_timeout_seconds must be 0..86400 on line $lineno"
                fi
                ;;
            alert_cooldown_seconds)
                if [[ $value =~ ^[0-9]+$ ]] && ((value >= 60 && value <= 86400)); then
                    WDMTG_CFG_ALERT_COOLDOWN=$value
                else
                    warn "config: alert_cooldown_seconds must be 60..86400 on line $lineno"
                fi
                ;;
            sleep_gap_seconds)
                if [[ $value =~ ^[0-9]+$ ]] && ((value >= 5 && value <= 3600)); then
                    WDMTG_CFG_SLEEP_GAP=$value
                else
                    warn "config: sleep_gap_seconds must be 5..3600 on line $lineno"
                fi
                ;;
            notifications)
                if value=$(config_enabled_value "$value"); then
                    WDMTG_CFG_NOTIFICATIONS=$value
                else
                    warn "config: notifications must be true/false on line $lineno"
                fi
                ;;
            browsing_category)
                if [[ -n $value ]]; then
                    WDMTG_CFG_BROWSING_CATEGORY=$value
                else
                    warn "config: browsing_category cannot be empty on line $lineno"
                fi
                ;;
            category\ *)
                config_add_category_rule "${left#* }" "$value"
                ;;
            exclude)
                config_add_excludes "$value"
                ;;
            limit\ *)
                config_add_limit "${left#* }" "$value"
                ;;
            goal\ *)
                config_add_goal "${left#* }" "$value"
                ;;
            *)
                warn "config: unknown key '$left' on line $lineno"
                ;;
        esac
    done <"$WDMTG_CONFIG_FILE"

    # An explicitly configured category list wins. A config that only changes
    # idle/alert settings still gets the built-in categories.
    if ((${#WDMTG_CAT_RULE_NAMES[@]} == 0)); then
        config_add_default_categories
    fi
    return 0
}

# First matching user/default rule wins; unmatched apps are "Other".
category_for_app() {
    local app=${1,,}
    local i

    for i in "${!WDMTG_CAT_RULE_NAMES[@]}"; do
        # shellcheck disable=SC2053 # glob matching is intentional
        if [[ $app == ${WDMTG_CAT_RULE_PATTERNS[$i]} ]]; then
            printf '%s' "${WDMTG_CAT_RULE_NAMES[$i]}"
            return 0
        fi
    done
    printf 'Other'
}

app_is_excluded() {
    local app=${1,,}
    local pattern

    for pattern in "${WDMTG_EXCLUDE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053 # glob matching is intentional
        if [[ $app == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

config_default_content() {
    cat <<'EOF'
# WhereDidMyTimeGo configuration.
# Format: key = value. Lines starting with # are ignored.
# Category and exclude values are comma-separated shell-glob patterns.
# First matching category wins. Apps not matched are "Other".

idle_timeout_seconds = 300
alert_cooldown_seconds = 1800
notifications = true
browsing_category = Browsing
sleep_gap_seconds = 5

# Categories. Edit freely; remove a whole line to stop using that rule.
category Coding = org.kde.konsole, org.kde.kate, org.kde.kdevelop, org.kde.kwrite, code, code-oss, codium, jetbrains-*, idea, pycharm, webstorm, goland, clion, vim, nvim, emacs, org.gnome.builder, android-studio, sublime_text, zed
category Browsing = firefox, firefox-esr, org.mozilla.firefox, google-chrome, chromium, brave-*, brave-browser, microsoft-edge, vivaldi-*, opera
category Communication = telegram*, org.telegram*, signal, org.signal.signal, slack, discord, zoom, teams, thunderbird, org.kde.neochat, element
category Entertainment = vlc, mpv, spotify, steam, org.kde.audiotube, rhythmbox, totem, celluloid, haruna

# Apps whose usage should never be recorded.
# exclude = keepassxc, org.kde.spectacle

# Daily limits. A notification is sent when the limit is reached.
# limit category:Entertainment = 60
# limit app:mpv = 30

# Daily goal used for weekly coding streaks.
# goal Coding = 120
EOF
}

config_ensure_file() {
    local tmp

    [[ -f $WDMTG_CONFIG_FILE ]] && return 0

    if ! mkdir -p -- "$WDMTG_CONFIG_DIR"; then
        printf 'cannot create config directory: %s\n' "$WDMTG_CONFIG_DIR" >&2
        return 1
    fi

    tmp="${WDMTG_CONFIG_FILE}.tmp.$$"
    config_default_content >"$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    chmod 600 -- "$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$WDMTG_CONFIG_FILE" || {
        rm -f -- "$tmp"
        return 1
    }
    return 0
}

config_show() {
    local i

    printf 'Config file: %s\n' "$WDMTG_CONFIG_FILE"
    printf 'Idle timeout: %s\n' "$(human_duration "$WDMTG_CFG_IDLE_TIMEOUT")"
    printf 'Alert cooldown: %s\n' "$(human_duration "$WDMTG_CFG_ALERT_COOLDOWN")"
    printf 'Notifications: %s\n' "$([[ $WDMTG_CFG_NOTIFICATIONS == 1 ]] && printf enabled || printf disabled)"
    printf 'Browsing category: %s\n' "$WDMTG_CFG_BROWSING_CATEGORY"
    printf 'Suspend gap threshold: %ss\n' "$WDMTG_CFG_SLEEP_GAP"

    printf '\nCategories (first match wins):\n'
    for i in "${!WDMTG_CAT_RULE_NAMES[@]}"; do
        printf '  %-16s %s\n' "${WDMTG_CAT_RULE_NAMES[$i]}" "${WDMTG_CAT_RULE_PATTERNS[$i]}"
    done

    printf '\nExcluded apps:'
    if ((${#WDMTG_EXCLUDE_PATTERNS[@]} == 0)); then
        printf ' none\n'
    else
        printf '\n'
        for i in "${!WDMTG_EXCLUDE_PATTERNS[@]}"; do
            printf '  %s\n' "${WDMTG_EXCLUDE_PATTERNS[$i]}"
        done
    fi

    printf '\nLimits:'
    if ((${#WDMTG_LIMIT_TYPES[@]} == 0)); then
        printf ' none\n'
    else
        printf '\n'
        for i in "${!WDMTG_LIMIT_TYPES[@]}"; do
            printf '  %s:%s = %s\n' "${WDMTG_LIMIT_TYPES[$i]}" "${WDMTG_LIMIT_NAMES[$i]}" \
                "$(human_duration "${WDMTG_LIMIT_MINUTES[$i]}")"
        done
    fi

    printf '\nGoals:'
    if ((${#WDMTG_GOAL_CATEGORIES[@]} == 0)); then
        printf ' none\n'
    else
        printf '\n'
        for i in "${!WDMTG_GOAL_CATEGORIES[@]}"; do
            printf '  %s = %s/day\n' "${WDMTG_GOAL_CATEGORIES[$i]}" \
                "$(human_duration "${WDMTG_GOAL_MINUTES[$i]}")"
        done
    fi
}
