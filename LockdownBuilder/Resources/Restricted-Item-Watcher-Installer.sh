#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Restricted-Item-Watcher-Installer.sh
# Author: LockdownBuilder
# Date: 10-01-2026
# Modified: 10-02-2026
# Purpose: Jamf script payload. Writes the Restricted-Item-Watcher script and its LaunchDaemon plist via heredoc, then (re)loads the daemon. Parameter 4 = install (default) | uninstall.
# Version: 1.7 - Embedded watcher v1.8; new deployment values BANNER_HEIGHT, DIALOG_ICON and DIALOG_ICON_SIZE; BANNER_IMAGE may be empty
# 1.6 - Embedded watcher v1.7 (optional Dialog* rule keys)
# 1.5 - Embedded watcher v1.6 (faster kill/dialog path)
# 1.4 - Embedded watcher v1.5 (WatchProcess rule key)
# 1.3 - Renamed Restricted-Item-Watcher-Installer.sh (hyphenated); installs Restricted-Item-Watcher.sh v1.4
# 1.2 - DOMAIN_PREFIX and DAEMON_LABEL derived from ORG_PLIST_DOMAIN + PREFERENCE; embedded watcher v1.3
# 1.1 - Embedded watcher v1.2 (ButtonText/ButtonAction/DismissButtonText rule keys)
# 1.0 - Initial Script
#
#
######################################################################
############## End Script Information Block ##########################
######################################################################

####################################################################
############## Begin Define Variables Block ########################
####################################################################
##############################
### Core Defined Variables ###
### MODIFY AT YOUR OWN RISK ##
##############################

# File-level shellcheck directives (before the first command so they cover the whole file):
#   SC2230 - `which` is preferred over `command -v` per the house style guide.
#   SC2155 - readonly NAME=$(which x) is the house binary pattern; validate_config() verifies
#            every binary, so a masked `which` failure cannot go unnoticed.
#   SC2034 - TIMESTAMP is core boilerplate that not every script consumes.
# shellcheck disable=SC2230,SC2155,SC2034
set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# `which` is preferred over `command -v` per the style guide (see file-level disables above).
readonly BASH_BIN=$(which bash)
readonly CAT=$(which cat)
readonly CHMOD=$(which chmod)
readonly CHOWN=$(which chown)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LAUNCHCTL=$(which launchctl)
readonly LOGGER=$(which logger)
readonly MKDIR=$(which mkdir)
readonly MKTEMP=$(which mktemp)
readonly PLUTIL=$(which plutil)
readonly RM=$(which rm)
readonly SLEEP=$(which sleep)
readonly TEE=$(which tee)

# Org identity — REQUIRED, set per deployment (also baked into the installed watcher).
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces.
# ORG_NAME: path-safe — derived, never set by hand.
# ORG_PLIST_DOMAIN: reverse-DNS — used for LOG_LABEL.
readonly ORG_NAME_FRIENDLY="Company Name"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"

# Script metadata (constant name: Jamf stages payload scripts under random temp names)
readonly PROJECT_NAME="Restricted-Item-Watcher"
readonly SCRIPT_NAME="${PROJECT_NAME}-Installer.sh"
readonly SCRIPT_VERSION="1.7"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${PROJECT_NAME}.installer"
readonly TIMESTAMP=$("${DATE}" +%Y%m%d_%H%M%S)
readonly JAMF_LOG="/var/log/jamf.log"

declare -a TEMP_FILES=()
CLEANUP_DONE="false"

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# ── PLACEHOLDERS — REPLACE BEFORE DEPLOYING ─────────────────────────────────
# >>> PLACEHOLDERS: ORG_NAME_FRIENDLY and ORG_PLIST_DOMAIN above (the script refuses to run
#     while ORG_PLIST_DOMAIN is still "com.company").
# PREFERENCE is the namespace segment; both names below are derived from it:
#   rule domains:   ${ORG_PLIST_DOMAIN}.${PREFERENCE}.<rule-name>   e.g. com.company.restrict.apple-account
#   daemon label:   ${ORG_PLIST_DOMAIN}.${PREFERENCE}.watcher       e.g. com.company.restrict.watcher
# Rules are read from /Library/Managed Preferences/<DOMAIN_PREFIX>.<rule-name>.plist
# Rule names must be lowercase kebab-case; "watcher" is reserved.
readonly PREFERENCE="restrict"
readonly DOMAIN_PREFIX="${ORG_PLIST_DOMAIN}.${PREFERENCE}"
readonly DAEMON_LABEL="${DOMAIN_PREFIX}.watcher"
# >>> PLACEHOLDER: banner image shown at the top of every dialog (local path on the Mac).
#     Empty = no banner; dialogs show ORG_NAME_FRIENDLY as their title instead.
readonly BANNER_IMAGE="/Library/Application Support/${ORG_NAME}/Branding/banner.png"
# Banner height in points. Empty = swiftDialog's default.
readonly BANNER_HEIGHT=""
# Dialog icon: a local image path or any swiftDialog --icon value. Empty = the standard shield symbol.
readonly DIALOG_ICON=""
# Dialog icon size in points. Empty = swiftDialog's default.
readonly DIALOG_ICON_SIZE=""
# >>> PLACEHOLDER (rule side): the Apple Account DialogMessage text lives in the AppleAccount
#     rule plist (__APPLE_ACCOUNT_DIALOG_MESSAGE__), not in this script.

# ── Jamf parameter ($1-$3 reserved by Jamf: mount point, computer name, username) ──
readonly PARAM_MODE="${4:-install}"

# ── Paths ───────────────────────────────────────────────────────────────────
readonly INSTALL_DIR="/Library/Application Support/${ORG_NAME}/${PROJECT_NAME}"
readonly INSTALL_SCRIPT_PATH="${INSTALL_DIR}/${PROJECT_NAME}.sh"
readonly TRACKING_DIR="${INSTALL_DIR}/Tracking"
readonly DAEMON_PLIST_PATH="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

##################################
### End User Defined Variables ###
##################################
####################################################################
############## End Define Variables Block ##########################
####################################################################

###################################################################################
############## Begin Function Block ###############################################
###################################################################################
##############################
### Core Defined Functions ###
### MODIFY AT YOUR OWN RISK ##
##############################

# ── Logging ──────────────────────────────────────────────────────────────────
log_info() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_warn() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_error() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_debug() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?
    local f
    if [[ "${CLEANUP_DONE}" == "true" ]]
    then
        return 0
    fi
    CLEANUP_DONE="true"

    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -n "${f}" && -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done
    log_info "${SCRIPT_NAME} exiting with code ${exit_code}"
}

handle_term() {
    exit 143
}

handle_int() {
    exit 130
}

trap cleanup EXIT
trap handle_term TERM
trap handle_int INT

# ── Preflight ────────────────────────────────────────────────────────────────
require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root"
        exit 1
    fi
}

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

validate_config() {
    local bin
    for bin in "${BASH_BIN}" "${CAT}" "${CHMOD}" "${CHOWN}" "${LAUNCHCTL}" "${MKDIR}" "${MKTEMP}" "${PLUTIL}" "${RM}"
    do
        if [[ ! -x "${bin}" ]]
        then
            log_error "Required binary missing or not executable: '${bin}'"
            exit 1
        fi
    done

    if [[ "${ORG_PLIST_DOMAIN}" == "com.company" || "${ORG_NAME_FRIENDLY}" == "Company Name" ]]
    then
        log_error "Placeholders not replaced (ORG_PLIST_DOMAIN='${ORG_PLIST_DOMAIN}', ORG_NAME_FRIENDLY='${ORG_NAME_FRIENDLY}')"
        exit 1
    fi

    # Prerequisites the watcher needs at runtime: warn only, they may arrive after this policy.
    if [[ ! -x "/usr/local/bin/jq" && ! -x "/usr/bin/jq" ]]
    then
        log_warn "jq not found; the watcher will not start until jq is installed"
    fi
    if [[ ! -x "/usr/local/bin/dialog" ]]
    then
        log_warn "swiftDialog not found at /usr/local/bin/dialog; kills will still happen but no dialogs"
    fi
}

# Writes the watcher via a LITERAL (single-quoted) heredoc into a staging file, then copies it
# to INSTALL_SCRIPT_PATH line by line substituting the deployment tokens with parameter expansion
# (no sed, so values containing & | \ / are safe).
write_watcher_script() {
    local staging line

    staging=$("${MKTEMP}")
    TEMP_FILES+=("${staging}")

    "${CAT}" > "${staging}" <<'WATCHER_SCRIPT_EOF'
#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Restricted-Item-Watcher.sh
# Author: LockdownBuilder
# Date: 10-01-2026
# Modified: 10-02-2026
# Purpose: Rule-driven restricted item watcher (deployed by Restricted-Item-Watcher-Installer.sh via heredoc). Reads one managed preference domain per rule, kills the named process on a log event (Predicate) or on presence, shows a swiftDialog message, and records attempts/kills to per-rule tracking plists for an Extension Attribute.
# Version: 1.8 - Dialog icon, icon size and banner height are deployment values; added DialogMessageAlignment and DialogMessagePosition rule keys; no banner configured is no longer a warning
# 1.7 - Added optional dialog rule keys: DialogWidth, DialogHeight, DialogPosition, DialogOnTop, DialogMoveable, DialogBlurScreen, DialogShowBanner, DialogShowIcon
# 1.6 - Faster response: kill before bookkeeping, dialog before SIGKILL escalation, 0.5 s presence poll
# 1.5 - Added optional WatchProcess rule key (presence rules can watch one process and kill another)
# 1.4 - Script renamed Restricted-Item-Watcher.sh; install folder is now .../Restricted-Item-Watcher/
# 1.3 - Rule names must be lowercase kebab-case; "watcher" is reserved
# 1.2 - Added ButtonText, ButtonAction and DismissButtonText rule keys
# 1.1 - Removed self-install; deployed and placeholder-substituted by the Jamf installer payload
# 1.0 - Initial Script
#
######################################################################
############## End Script Information Block ##########################
######################################################################

####################################################################
############## Begin Define Variables Block ########################
####################################################################
##############################
### Core Defined Variables ###
### MODIFY AT YOUR OWN RISK ##
##############################

# File-level shellcheck directives (placed before the first command so they cover the whole file):
#   SC2230 - `which` is preferred over `command -v` per the house style guide.
#   SC2155 - readonly NAME=$(which x) is the house binary pattern; validate_config() verifies every
#            binary, so a masked `which` failure cannot go unnoticed.
#   SC2034 - TIMESTAMP is core boilerplate that not every script consumes.
# shellcheck disable=SC2230,SC2155,SC2034
set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# `which` is preferred over `command -v` per the style guide (see file-level disables above).
readonly AWK=$(which awk)
readonly CHMOD=$(which chmod)
readonly CKSUM=$(which cksum)
readonly DATE=$(which date)
readonly DEFAULTS=$(which defaults)
readonly ID=$(which id)
readonly JQ=$(which jq)
readonly LAUNCHCTL=$(which launchctl)
readonly LOG=$(which log)
readonly LOGGER=$(which logger)
readonly MKDIR=$(which mkdir)
readonly MKFIFO=$(which mkfifo)
readonly MKTEMP=$(which mktemp)
readonly OPEN=$(which open)
readonly PGREP=$(which pgrep)
readonly PKILL=$(which pkill)
readonly PLUTIL=$(which plutil)
readonly PS=$(which ps)
readonly RM=$(which rm)
readonly SCUTIL=$(which scutil)
readonly SLEEP=$(which sleep)
readonly SUDO=$(which sudo)
readonly TEE=$(which tee)
readonly TR=$(which tr)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces.
# ORG_NAME: path-safe — derived, never set by hand.
# ORG_PLIST_DOMAIN: reverse-DNS — used for LOG_LABEL.
readonly ORG_NAME_FRIENDLY="__ORG_NAME_FRIENDLY__"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="__ORG_PLIST_DOMAIN__"

# Script metadata
# SCRIPT_NAME is a constant (not basename "$0") because Jamf stages payload scripts under
# random temp names; the installed copy and every log line must use one stable name.
readonly PROJECT_NAME="Restricted-Item-Watcher"
readonly SCRIPT_NAME="${PROJECT_NAME}.sh"
readonly SCRIPT_VERSION="1.8"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${PROJECT_NAME}"
readonly TIMESTAMP=$("${DATE}" +%Y%m%d_%H%M%S)
readonly JAMF_LOG="/var/log/jamf.log"

declare -a TEMP_FILES=()
declare -a TEMP_DIRS=()
CLEANUP_DONE="false"

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# ── Deployment values (substituted by the installer when it writes this file) ──
# Tokens: __DOMAIN_PREFIX__, __BANNER_IMAGE__, __BANNER_HEIGHT__, __DIALOG_ICON__, __DIALOG_ICON_SIZE__,
#         __ORG_NAME_FRIENDLY__, __ORG_PLIST_DOMAIN__.
# Set them at the top of Restricted-Item-Watcher-Installer.sh, not here.
# Rule domain prefix: rules are read from /Library/Managed Preferences/<DOMAIN_PREFIX>.<RuleName>.plist
readonly DOMAIN_PREFIX="__DOMAIN_PREFIX__"
# Banner image shown at the top of every dialog (local path on the Mac)
# Empty = no banner: every dialog shows the organisation name as its title instead.
BANNER_IMAGE="__BANNER_IMAGE__"
# Banner height in points. Empty = swiftDialog's default.
BANNER_HEIGHT="__BANNER_HEIGHT__"
# Dialog icon: a local image path or any swiftDialog --icon value. Empty = the standard shield symbol.
DIALOG_ICON="__DIALOG_ICON__"
# Dialog icon size in points. Empty = swiftDialog's default.
DIALOG_ICON_SIZE="__DIALOG_ICON_SIZE__"
# Rule data (including the Apple Account DialogMessage) lives in the rule plists, never here.

# ── Paths ───────────────────────────────────────────────────────────────────
readonly RULES_DIR="/Library/Managed Preferences"
readonly INSTALL_DIR="/Library/Application Support/${ORG_NAME}/${PROJECT_NAME}"
readonly TRACKING_DIR="${INSTALL_DIR}/Tracking"

# ── Tunables ────────────────────────────────────────────────────────────────
readonly RESCAN_INTERVAL=5          # seconds between rule-change / child-health checks
readonly PRESENCE_POLL_INTERVAL=0.5 # seconds between pgrep sweeps for presence rules (pgrep is ~ms; lower = faster kill)
readonly DEFAULT_COOLDOWN=5         # seconds, when a rule has no CooldownSeconds
readonly STREAM_MIN_RUNTIME=10      # a log stream that dies sooner than this = bad predicate
readonly STREAM_BACKOFF_MIN=30      # first retry delay after a bad predicate
readonly STREAM_BACKOFF_MAX=600     # retry delay cap
readonly EVENT_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'

# Rule names come from the file name (<DOMAIN_PREFIX>.<rule-name>.plist). They must be lowercase
# kebab-case (APFS is case-insensitive, so names differing only by case would collide), and
# "watcher" is reserved for the daemon label (<DOMAIN_PREFIX>.watcher).
readonly RULE_NAME_REGEX='^[a-z0-9]+(-[a-z0-9]+)*$'
readonly RESERVED_RULE_NAME="watcher"

# Processes that must never be killed (matched exactly against KillProcess).
# "bash" and the script name cover this watcher itself; "log" covers our own streams.
declare -a KILL_DENYLIST=("launchd" "kernel_task" "loginwindow" "WindowServer" "bash" "log" "dialog" "${SCRIPT_NAME}")

# jq filter: a rule must pass this or it is skipped (wrong/missing types never crash the daemon)
readonly RULE_VALIDATE_FILTER='type == "object"
    and (.KillProcess | type == "string" and length > 0)
    and (.DialogMessage | type == "string" and length > 0)
    and ((has("Predicate") | not) or (.Predicate | type == "string"))
    and ((has("ButtonText") | not) or (.ButtonText | type == "string" and length > 0))
    and ((has("ButtonAction") | not) or (.ButtonAction | type == "string" and length > 0))
    and ((has("WatchProcess") | not) or (.WatchProcess | type == "string" and length > 0))
    and ((has("DismissButtonText") | not) or (.DismissButtonText | type == "string" and length > 0))
    and ((has("CooldownSeconds") | not) or (.CooldownSeconds | type == "number" and . >= 0 and . == floor))'

# ButtonAction must be an absolute path (e.g. /Applications/Self Service.app) or a URL with a scheme
# (e.g. jamfselfservice://content). file:// is refused. It is only ever passed to `open --` as ONE argument.
readonly ACTION_REGEX='^(/[^[:cntrl:]]+|[A-Za-z][A-Za-z0-9+.-]*://[^[:cntrl:]]+)$'
readonly DEFAULT_BUTTON_TEXT="OK"

# Optional dialog window keys. They only change how the dialog looks, so a wrong value is ignored
# with a warning (the default is used) and the rule still loads and still kills.
readonly DIALOG_MIN_SIZE=200        # smallest DialogWidth / DialogHeight accepted (points)
readonly DIALOG_ALIGNMENT_REGEX='^(left|center|right)$'
readonly DIALOG_MESSAGE_POSITION_REGEX='^(top|center|bottom)$'
readonly DIALOG_POSITION_REGEX='^(topleft|top|topright|left|center|right|bottomleft|bottom|bottomright)$'
# jq filter: prints the key's value, nothing when the key is absent, or __invalid__ when it has the
# wrong type or is out of range. $k = key name, $kind = size | choice | bool; $choices is the regex a
# choice value must match.
# shellcheck disable=SC2016 # $k, $kind, $min and $choices are jq variables, not shell expansions
readonly DIALOG_KEY_FILTER='if (has($k) | not) then ""
    elif $kind == "size" and (.[$k] | type == "number" and . >= $min and . == floor) then (.[$k] | tostring)
    elif $kind == "choice" and (.[$k] | type == "string" and test($choices)) then .[$k]
    elif $kind == "bool" and (.[$k] | type == "boolean") then (.[$k] | tostring)
    else "__invalid__" end'

# ── swiftDialog ─────────────────────────────────────────────────────────────
readonly DIALOG_BIN="/usr/local/bin/dialog"
# Banner-only look is done with `--bannerimage` + `--title none`; verified on swiftDialog 3.0.0.4952.
# Deviation from the house branding block: no --bannertext / --title (rules carry no title).
APP_ICON="SF=exclamationmark.shield.fill,colour=red"
# shellcheck disable=SC2034 # shared size constants; only appSizeSmall is used by this script
appIconSize=125
# shellcheck disable=SC2034
appSizeXSmall=250
appSizeSmall=500
# shellcheck disable=SC2034
appSizeMedium=650
# shellcheck disable=SC2034
appSizeLarge=800
# shellcheck disable=SC2034
appSizeXLarge=1000

# ── Runtime state (parallel indexed arrays; Bash 3.2 has no associative arrays) ──
declare -a RULE_NAMES=()
declare -a RULE_KILLS=()
declare -a RULE_PREDICATES=()
declare -a RULE_MESSAGES=()
declare -a RULE_COOLDOWNS=()
declare -a RULE_BUTTON_TEXTS=()
declare -a RULE_BUTTON_ACTIONS=()
declare -a RULE_DISMISS_TEXTS=()
declare -a RULE_WATCHES=()
# Dialog window options, one entry per rule; an empty entry means "use the default".
declare -a RULE_DIALOG_WIDTHS=()
declare -a RULE_DIALOG_HEIGHTS=()
declare -a RULE_DIALOG_POSITIONS=()
declare -a RULE_DIALOG_ONTOPS=()
declare -a RULE_DIALOG_MOVEABLES=()
declare -a RULE_DIALOG_BLURS=()
declare -a RULE_DIALOG_BANNERS=()
declare -a RULE_DIALOG_ICONS=()
declare -a RULE_DIALOG_ALIGNMENTS=()
declare -a RULE_DIALOG_MESSAGE_POSITIONS=()
declare -a RULE_LAST_DIALOG=()
declare -a CHILD_PIDS=()
RUN_DIR=""
RULES_SIGNATURE=""
CONSOLE_USER=""
CONSOLE_UID=""
KILL_RESULT=""
DIALOG_KEY_VALUE=""
MODE=""

##################################
### End User Defined Variables ###
##################################
####################################################################
############## End Define Variables Block ##########################
####################################################################

###################################################################################
############## Begin Function Block ###############################################
###################################################################################
##############################
### Core Defined Functions ###
### MODIFY AT YOUR OWN RISK ##
##############################

# ── Logging ──────────────────────────────────────────────────────────────────
# printf '%s\n' (not echo -e) so backslashes in rule data are never interpreted.
log_info() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_warn() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_error() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_debug() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    printf '%s\n' "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

# ── Cleanup (trapped on EXIT; TERM/INT convert to exit so EXIT always fires) ─
# Idempotent: stops every child handler and log stream, then removes temp files.
cleanup() {
    local exit_code=$?
    local f
    if [[ "${CLEANUP_DONE}" == "true" ]]
    then
        return 0
    fi
    CLEANUP_DONE="true"

    stop_children

    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -n "${f}" && -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done
    for f in "${TEMP_DIRS[@]:-}"
    do
        if [[ -n "${f}" && -d "${f}" ]]
        then
            "${RM}" -rf "${f}"
        fi
    done
    log_info "${SCRIPT_NAME} exiting with code ${exit_code}"
}

handle_term() {
    exit 143
}

handle_int() {
    exit 130
}

trap cleanup EXIT
trap handle_term TERM
trap handle_int INT

# ── Preflight ────────────────────────────────────────────────────────────────
require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root"
        exit 1
    fi
}

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

# ── Config / preflight ───────────────────────────────────────────────────────
validate_config() {
    local bin
    for bin in "${JQ}" "${PLUTIL}" "${PGREP}" "${PKILL}" "${LOG}" "${MKFIFO}" "${DEFAULTS}" "${LAUNCHCTL}" "${SCUTIL}" "${SUDO}"
    do
        if [[ ! -x "${bin}" ]]
        then
            log_error "Required binary missing or not executable: '${bin}'"
            exit 1
        fi
    done

    if [[ "${DOMAIN_PREFIX}" == __* || "${BANNER_IMAGE}" == __* ]]
    then
        log_error "Placeholders not replaced (DOMAIN_PREFIX='${DOMAIN_PREFIX}', BANNER_IMAGE='${BANNER_IMAGE}')"
        exit 1
    fi

    if [[ "${BANNER_HEIGHT}" == __* || "${DIALOG_ICON}" == __* || "${DIALOG_ICON_SIZE}" == __* ]]
    then
        log_error "Placeholders not replaced (BANNER_HEIGHT='${BANNER_HEIGHT}', DIALOG_ICON='${DIALOG_ICON}', DIALOG_ICON_SIZE='${DIALOG_ICON_SIZE}')"
        exit 1
    fi

    # Sizes are optional; anything that is not a whole number is dropped so swiftDialog's default applies.
    if [[ -n "${BANNER_HEIGHT}" ]] && ! [[ "${BANNER_HEIGHT}" =~ ^[0-9]+$ ]]
    then
        log_warn "BANNER_HEIGHT '${BANNER_HEIGHT}' is not a whole number; using swiftDialog's default"
        BANNER_HEIGHT=""
    fi

    if [[ -n "${DIALOG_ICON_SIZE}" ]] && ! [[ "${DIALOG_ICON_SIZE}" =~ ^[0-9]+$ ]]
    then
        log_warn "DIALOG_ICON_SIZE '${DIALOG_ICON_SIZE}' is not a whole number; using swiftDialog's default"
        DIALOG_ICON_SIZE=""
    fi

    if [[ -n "${DIALOG_ICON}" ]]
    then
        APP_ICON="${DIALOG_ICON}"
    fi

    if [[ ! -x "${DIALOG_BIN}" ]]
    then
        log_warn "swiftDialog not found at ${DIALOG_BIN}; rules will still kill but no dialogs will show"
    fi
}

# Sets CONSOLE_USER / CONSOLE_UID globals (never echoes — see log-helper stdout rule).
get_console_user() {
    local user
    CONSOLE_USER=""
    CONSOLE_UID=""
    # shellcheck disable=SC2016 # $3 is awk's field, not a shell expansion
    user=$("${SCUTIL}" <<< "show State:/Users/ConsoleUser" | "${AWK}" '/Name :/ && !/loginwindow/ { print $3 }')
    if [[ -z "${user}" || "${user}" == "root" ]]
    then
        return 1
    fi
    CONSOLE_USER="${user}"
    CONSOLE_UID=$("${ID}" -u "${user}")
    return 0
}

# Sleep that a trapped signal can interrupt immediately (plain foreground sleep defers traps).
interruptible_sleep() {
    local seconds="$1"
    "${SLEEP}" "${seconds}" &
    # An interrupted/killed wait returns non-zero; both outcomes are expected here.
    if wait "$!" 2>/dev/null
    then
        return 0
    fi
    return 0
}

# ── Rule loading ─────────────────────────────────────────────────────────────
# Sets RULES_SIGNATURE: a checksum of every matching plist; any add/remove/edit changes it.
compute_rules_signature() {
    local plist_file
    local sig_output
    local -a plist_files=()

    for plist_file in "${RULES_DIR}/${DOMAIN_PREFIX}".*.plist
    do
        if [[ -f "${plist_file}" ]]
        then
            plist_files+=("${plist_file}")
        fi
    done

    if [[ "${#plist_files[@]}" -eq 0 ]]
    then
        RULES_SIGNATURE="none"
        return 0
    fi

    if sig_output=$("${CKSUM}" "${plist_files[@]}" 2>/dev/null)
    then
        RULES_SIGNATURE="${sig_output}"
    else
        RULES_SIGNATURE="unreadable"
    fi
}

# Reads one optional dialog key from a rule's JSON into DIALOG_KEY_VALUE (empty = absent or invalid).
# Uses a global rather than stdout because the log functions also write to stdout.
read_dialog_key() {
    local json="$1"
    local key="$2"
    local kind="$3"
    local rule_name="$4"
    local choices="${5:-}"

    DIALOG_KEY_VALUE=""
    if ! DIALOG_KEY_VALUE=$("${JQ}" -r --arg k "${key}" --arg kind "${kind}" --argjson min "${DIALOG_MIN_SIZE}" \
        --arg choices "${choices}" "${DIALOG_KEY_FILTER}" <<< "${json}" 2>/dev/null)
    then
        DIALOG_KEY_VALUE="__invalid__"
    fi

    if [[ "${DIALOG_KEY_VALUE}" == "__invalid__" ]]
    then
        log_warn "Rule '${rule_name}': ${key} is not a valid ${kind} value; using the default"
        DIALOG_KEY_VALUE=""
    fi
}

load_rules() {
    local plist_file rule_name json kill_name predicate message cooldown denied rule_type
    local denied_hit button_text button_action dismiss_text watch_name
    local dialog_width dialog_height dialog_position dialog_ontop dialog_moveable dialog_blur
    local dialog_banner dialog_icon dialog_alignment dialog_message_position

    RULE_NAMES=()
    RULE_KILLS=()
    RULE_PREDICATES=()
    RULE_MESSAGES=()
    RULE_COOLDOWNS=()
    RULE_BUTTON_TEXTS=()
    RULE_BUTTON_ACTIONS=()
    RULE_DISMISS_TEXTS=()
    RULE_WATCHES=()
    RULE_DIALOG_WIDTHS=()
    RULE_DIALOG_HEIGHTS=()
    RULE_DIALOG_POSITIONS=()
    RULE_DIALOG_ONTOPS=()
    RULE_DIALOG_MOVEABLES=()
    RULE_DIALOG_BLURS=()
    RULE_DIALOG_BANNERS=()
    RULE_DIALOG_ICONS=()
    RULE_DIALOG_ALIGNMENTS=()
    RULE_DIALOG_MESSAGE_POSITIONS=()
    RULE_LAST_DIALOG=()

    for plist_file in "${RULES_DIR}/${DOMAIN_PREFIX}".*.plist
    do
        if [[ ! -f "${plist_file}" ]]
        then
            continue
        fi

        rule_name="${plist_file##*/}"
        rule_name="${rule_name#"${DOMAIN_PREFIX}".}"
        rule_name="${rule_name%.plist}"

        if ! [[ "${rule_name}" =~ ${RULE_NAME_REGEX} ]] || [[ "${rule_name}" == "${RESERVED_RULE_NAME}" ]]
        then
            log_warn "Rule file skipped: '${rule_name}' is not valid (use lowercase kebab-case, e.g. apple-account; '${RESERVED_RULE_NAME}' is reserved)"
            continue
        fi

        if ! json=$("${PLUTIL}" -convert json -o - -- "${plist_file}" 2>/dev/null)
        then
            log_warn "Rule '${rule_name}' skipped: plist could not be converted to JSON (${plist_file})"
            continue
        fi

        if ! "${JQ}" -e "${RULE_VALIDATE_FILTER}" <<< "${json}" >/dev/null 2>&1
        then
            log_warn "Rule '${rule_name}' skipped: missing/invalid KillProcess, DialogMessage, Predicate or CooldownSeconds"
            continue
        fi

        kill_name=$("${JQ}" -r '.KillProcess' <<< "${json}")
        predicate=$("${JQ}" -r '.Predicate // ""' <<< "${json}")
        message=$("${JQ}" -r '.DialogMessage' <<< "${json}")
        # shellcheck disable=SC2016 # $d is a jq variable, not a shell expansion
        cooldown=$("${JQ}" -r --argjson d "${DEFAULT_COOLDOWN}" '(.CooldownSeconds // $d) | floor' <<< "${json}")

        # shellcheck disable=SC2016 # $d is a jq variable, not a shell expansion
        button_text=$("${JQ}" -r --arg d "${DEFAULT_BUTTON_TEXT}" '.ButtonText // $d' <<< "${json}")
        button_action=$("${JQ}" -r '.ButtonAction // ""' <<< "${json}")
        dismiss_text=$("${JQ}" -r '.DismissButtonText // ""' <<< "${json}")
        watch_name=$("${JQ}" -r '.WatchProcess // ""' <<< "${json}")

        if [[ -n "${watch_name}" && -n "${predicate}" ]]
        then
            log_warn "Rule '${rule_name}' skipped: WatchProcess only applies to presence rules (rules without a Predicate)"
            continue
        fi
        if [[ -z "${watch_name}" ]]
        then
            watch_name="${kill_name}"
        fi

        if [[ -n "${button_action}" ]]
        then
            if ! [[ "${button_action}" =~ ${ACTION_REGEX} ]] || [[ "${button_action}" == [Ff][Ii][Ll][Ee]:* ]]
            then
                log_warn "Rule '${rule_name}' skipped: ButtonAction must be an absolute path or a non-file URL"
                continue
            fi
        fi

        denied_hit="false"
        for denied in "${KILL_DENYLIST[@]}"
        do
            if [[ "${kill_name}" == "${denied}" ]]
            then
                denied_hit="true"
            fi
        done
        if [[ "${denied_hit}" == "true" ]]
        then
            log_error "Rule '${rule_name}' skipped: KillProcess '${kill_name}' is on the critical-process denylist"
            continue
        fi

        read_dialog_key "${json}" "DialogWidth" "size" "${rule_name}"
        dialog_width="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogHeight" "size" "${rule_name}"
        dialog_height="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogPosition" "choice" "${rule_name}" "${DIALOG_POSITION_REGEX}"
        dialog_position="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogOnTop" "bool" "${rule_name}"
        dialog_ontop="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogMoveable" "bool" "${rule_name}"
        dialog_moveable="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogBlurScreen" "bool" "${rule_name}"
        dialog_blur="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogShowBanner" "bool" "${rule_name}"
        dialog_banner="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogShowIcon" "bool" "${rule_name}"
        dialog_icon="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogMessageAlignment" "choice" "${rule_name}" "${DIALOG_ALIGNMENT_REGEX}"
        dialog_alignment="${DIALOG_KEY_VALUE}"
        read_dialog_key "${json}" "DialogMessagePosition" "choice" "${rule_name}" "${DIALOG_MESSAGE_POSITION_REGEX}"
        dialog_message_position="${DIALOG_KEY_VALUE}"

        RULE_NAMES+=("${rule_name}")
        RULE_KILLS+=("${kill_name}")
        RULE_PREDICATES+=("${predicate}")
        RULE_MESSAGES+=("${message}")
        RULE_COOLDOWNS+=("${cooldown}")
        RULE_BUTTON_TEXTS+=("${button_text}")
        RULE_BUTTON_ACTIONS+=("${button_action}")
        RULE_DISMISS_TEXTS+=("${dismiss_text}")
        RULE_WATCHES+=("${watch_name}")
        RULE_DIALOG_WIDTHS+=("${dialog_width}")
        RULE_DIALOG_HEIGHTS+=("${dialog_height}")
        RULE_DIALOG_POSITIONS+=("${dialog_position}")
        RULE_DIALOG_ONTOPS+=("${dialog_ontop}")
        RULE_DIALOG_MOVEABLES+=("${dialog_moveable}")
        RULE_DIALOG_BLURS+=("${dialog_blur}")
        RULE_DIALOG_BANNERS+=("${dialog_banner}")
        RULE_DIALOG_ICONS+=("${dialog_icon}")
        RULE_DIALOG_ALIGNMENTS+=("${dialog_alignment}")
        RULE_DIALOG_MESSAGE_POSITIONS+=("${dialog_message_position}")
        RULE_LAST_DIALOG+=("0")

        if [[ -n "${predicate}" ]]
        then
            rule_type="predicate"
        else
            rule_type="presence"
        fi
        log_info "Rule loaded: name='${rule_name}' type=${rule_type} kill='${kill_name}' watch='${watch_name}' cooldown=${cooldown}s"
    done

    if [[ "${#RULE_NAMES[@]}" -eq 0 ]]
    then
        log_warn "No valid rules loaded from ${RULES_DIR}/${DOMAIN_PREFIX}.*.plist; watcher idle"
    fi
}

# ── Tracking (per-rule plists read by the Extension Attribute) ───────────────
# One plist per rule so a rule's single handler is the only writer (no cross-process races).
# record_tracking <idx> <counter_key|""> <timestamp_key|"">
record_tracking() {
    local idx="$1"
    local counter_key="$2"
    local timestamp_key="$3"
    local track_file="${TRACKING_DIR}/${RULE_NAMES[${idx}]}.plist"
    local current=0
    local now_iso

    now_iso=$("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')

    if ! "${MKDIR}" -p "${TRACKING_DIR}"
    then
        log_warn "Tracking: could not create ${TRACKING_DIR}"
        return 0
    fi

    "${DEFAULTS}" write "${track_file}" RuleName -string "${RULE_NAMES[${idx}]}"
    "${DEFAULTS}" write "${track_file}" KillProcess -string "${RULE_KILLS[${idx}]}"

    if [[ -n "${counter_key}" ]]
    then
        if ! current=$("${DEFAULTS}" read "${track_file}" "${counter_key}" 2>/dev/null)
        then
            current=0
        fi
        if ! [[ "${current}" =~ ^[0-9]+$ ]]
        then
            current=0
        fi
        "${DEFAULTS}" write "${track_file}" "${counter_key}" -int $((current + 1))
    fi

    if [[ -n "${timestamp_key}" ]]
    then
        "${DEFAULTS}" write "${track_file}" "${timestamp_key}" -string "${now_iso}"
    fi

    "${CHMOD}" 644 "${track_file}"
}

record_attempt() {
    local idx="$1"
    local track_file="${TRACKING_DIR}/${RULE_NAMES[${idx}]}.plist"
    local user="none"

    if get_console_user
    then
        user="${CONSOLE_USER}"
    fi

    record_tracking "${idx}" "AttemptCount" "LastAttempt"
    "${DEFAULTS}" write "${track_file}" LastConsoleUser -string "${user}"

    if ! "${DEFAULTS}" read "${track_file}" FirstAttempt >/dev/null 2>&1
    then
        "${DEFAULTS}" write "${track_file}" FirstAttempt -string "$("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
}

# ── Kill + dialog ────────────────────────────────────────────────────────────
# Sets KILL_RESULT: killed | not_running | refused | failed.  Returns 1 only on refusal.
# UNVERIFIED: whether killing System Settings produces no "quit unexpectedly" alert (see test plan).
# pgrep/pkill -x match the full process name (verified on macOS 26 with a 31-character name,
# InternetAccountsSettingsExtension); still confirm each KillProcess/WatchProcess with pgrep -x.
kill_process() {
    local process_name="$1"
    local rule_name="$2"
    local denied
    local pkill_rc

    KILL_RESULT="not_running"

    for denied in "${KILL_DENYLIST[@]}"
    do
        if [[ "${process_name}" == "${denied}" ]]
        then
            log_error "Rule '${rule_name}': REFUSED to kill denylisted process '${process_name}'"
            KILL_RESULT="refused"
            return 1
        fi
    done

    # pkill exits 1 when nothing matched (not running), >1 on error. SIGTERM only here; the
    # survivor check / SIGKILL escalation happens in confirm_kill AFTER the dialog is launched.
    if "${PKILL}" -x "${process_name}" >/dev/null 2>&1
    then
        KILL_RESULT="killed"
        log_info "Rule '${rule_name}': sent SIGTERM to '${process_name}'"
    else
        pkill_rc=$?
        if [[ "${pkill_rc}" -eq 1 ]]
        then
            log_debug "Rule '${rule_name}': '${process_name}' not running at kill time"
        else
            KILL_RESULT="failed"
            log_warn "Rule '${rule_name}': pkill failed for '${process_name}' (rc ${pkill_rc})"
        fi
    fi
    return 0
}

# Waits up to ~1 s (0.1 s steps) for the process to exit after SIGTERM, then escalates to SIGKILL.
confirm_kill() {
    local process_name="$1"
    local rule_name="$2"
    local attempt=0

    while [[ "${attempt}" -lt 10 ]]
    do
        if ! "${PGREP}" -x "${process_name}" >/dev/null 2>&1
        then
            return 0
        fi
        "${SLEEP}" 0.1
        attempt=$((attempt + 1))
    done

    log_warn "Rule '${rule_name}': '${process_name}' survived SIGTERM, sending SIGKILL"
    if ! "${PKILL}" -9 -x "${process_name}" >/dev/null 2>&1
    then
        log_warn "Rule '${rule_name}': SIGKILL failed for '${process_name}'"
    fi
}

# Every dialog goes through here; returns swiftDialog's exit code (0 = button 1, 2 = button 2).
# Always backgrounded by the caller so the watcher never blocks.
run_dialog() {
    local dialog_rc=0
    if "${LAUNCHCTL}" asuser "${CONSOLE_UID}" "${SUDO}" -u "${CONSOLE_USER}" \
        "${DIALOG_BIN}" "$@" >/dev/null 2>&1
    then
        dialog_rc=0
    else
        dialog_rc=$?
    fi
    return "${dialog_rc}"
}

# Opens the rule's ButtonAction in the user's session as ONE argument (never eval'd, never shell-built).
open_button_action() {
    local action="$1"
    log_info "Opening ButtonAction for ${CONSOLE_USER}: ${action}"
    if ! "${LAUNCHCTL}" asuser "${CONSOLE_UID}" "${SUDO}" -u "${CONSOLE_USER}" "${OPEN}" -- "${action}" >/dev/null 2>&1
    then
        log_warn "open failed for ButtonAction: ${action}"
    fi
}

# Runs one dialog and, if button 1 was pressed and the rule has a ButtonAction, performs it.
# Runs as a background job started by show_rule_dialog; CONSOLE_USER/UID are inherited at fork.
run_dialog_with_action() {
    local action="$1"
    local dialog_rc=0
    shift

    if run_dialog "$@"
    then
        dialog_rc=0
    else
        dialog_rc=$?
    fi
    log_debug "swiftDialog exited rc=${dialog_rc}"

    if [[ "${dialog_rc}" -eq 0 && -n "${action}" ]]
    then
        open_button_action "${action}"
    fi
}

show_rule_dialog() {
    local idx="$1"
    local rule_name="${RULE_NAMES[${idx}]}"
    local -a dialog_args=()

    if [[ ! -x "${DIALOG_BIN}" ]]
    then
        log_error "Rule '${rule_name}': swiftDialog missing at ${DIALOG_BIN}; kill done, no dialog"
        return 0
    fi

    if ! get_console_user
    then
        log_info "Rule '${rule_name}': no console user (none/root/loginwindow); dialog skipped"
        return 0
    fi

    # Dialog window options: an empty entry means the rule did not set the key, so the default applies.
    local dialog_height="${RULE_DIALOG_HEIGHTS[${idx}]}"
    if [[ -z "${dialog_height}" ]]
    then
        dialog_height="${appSizeSmall}"
    fi

    dialog_args=(
        --height "${dialog_height}"
        --message "${RULE_MESSAGES[${idx}]}"
        --button1text "${RULE_BUTTON_TEXTS[${idx}]}"
    )

    if [[ -n "${RULE_DIALOG_WIDTHS[${idx}]}" ]]
    then
        dialog_args+=(--width "${RULE_DIALOG_WIDTHS[${idx}]}")
    fi

    if [[ -n "${RULE_DIALOG_POSITIONS[${idx}]}" ]]
    then
        dialog_args+=(--position "${RULE_DIALOG_POSITIONS[${idx}]}")
    fi

    if [[ -n "${RULE_DIALOG_ALIGNMENTS[${idx}]}" ]]
    then
        dialog_args+=(--messagealignment "${RULE_DIALOG_ALIGNMENTS[${idx}]}")
    fi

    if [[ -n "${RULE_DIALOG_MESSAGE_POSITIONS[${idx}]}" ]]
    then
        dialog_args+=(--messageposition "${RULE_DIALOG_MESSAGE_POSITIONS[${idx}]}")
    fi

    # DialogShowIcon false hides the icon; absent or true shows the deployment's icon.
    if [[ "${RULE_DIALOG_ICONS[${idx}]}" == "false" ]]
    then
        dialog_args+=(--icon none)
    else
        dialog_args+=(--icon "${APP_ICON}")
        if [[ -n "${DIALOG_ICON_SIZE}" ]]
        then
            dialog_args+=(--iconsize "${DIALOG_ICON_SIZE}")
        fi
    fi

    # DialogOnTop and DialogMoveable default to true; DialogBlurScreen defaults to false.
    if [[ "${RULE_DIALOG_ONTOPS[${idx}]}" != "false" ]]
    then
        dialog_args+=(--ontop)
    fi

    if [[ "${RULE_DIALOG_MOVEABLES[${idx}]}" != "false" ]]
    then
        dialog_args+=(--moveable)
    fi

    if [[ "${RULE_DIALOG_BLURS[${idx}]}" == "true" ]]
    then
        dialog_args+=(--blurscreen)
    fi

    if [[ -n "${RULE_DISMISS_TEXTS[${idx}]}" ]]
    then
        dialog_args+=(--button2text "${RULE_DISMISS_TEXTS[${idx}]}")
    fi

    # No banner configured, or DialogShowBanner false: the organisation name is the title instead.
    if [[ -z "${BANNER_IMAGE}" || "${RULE_DIALOG_BANNERS[${idx}]}" == "false" ]]
    then
        dialog_args+=(--title "${ORG_NAME_FRIENDLY}")
    elif [[ -f "${BANNER_IMAGE}" ]]
    then
        dialog_args+=(--bannerimage "${BANNER_IMAGE}" --title none)
        if [[ -n "${BANNER_HEIGHT}" ]]
        then
            dialog_args+=(--bannerheight "${BANNER_HEIGHT}")
        fi
    else
        log_warn "Banner image missing (${BANNER_IMAGE}); falling back to plain title"
        dialog_args+=(--title "${ORG_NAME_FRIENDLY}")
    fi

    log_info "Rule '${rule_name}': showing dialog to ${CONSOLE_USER} (uid ${CONSOLE_UID})"
    run_dialog_with_action "${RULE_BUTTON_ACTIONS[${idx}]}" "${dialog_args[@]}" &
}

maybe_show_dialog() {
    local idx="$1"
    local rule_name="${RULE_NAMES[${idx}]}"
    local now elapsed last cooldown

    now=$("${DATE}" +%s)
    last="${RULE_LAST_DIALOG[${idx}]}"
    cooldown="${RULE_COOLDOWNS[${idx}]}"
    elapsed=$((now - last))

    if [[ "${elapsed}" -ge "${cooldown}" ]]
    then
        RULE_LAST_DIALOG[idx]="${now}"
        show_rule_dialog "${idx}"
        record_tracking "${idx}" "DialogCount" "LastDialog"
    else
        record_tracking "${idx}" "SuppressedDialogCount" ""
        log_info "Rule '${rule_name}': dialog suppressed by cooldown (${elapsed}s < ${cooldown}s)"
    fi
}

# Shared by both handler types: record attempt, kill every time, dialog subject to cooldown.
handle_rule_event() {
    local idx="$1"

    # Order matters for speed: kill first, dialog second, SIGKILL escalation third, tracking last.
    if ! kill_process "${RULE_KILLS[${idx}]}" "${RULE_NAMES[${idx}]}"
    then
        record_attempt "${idx}"
        return 0
    fi

    maybe_show_dialog "${idx}"

    if [[ "${KILL_RESULT}" == "killed" ]]
    then
        confirm_kill "${RULE_KILLS[${idx}]}" "${RULE_NAMES[${idx}]}"
    fi

    record_attempt "${idx}"
    if [[ "${KILL_RESULT}" == "killed" ]]
    then
        record_tracking "${idx}" "KillCount" "LastKill"
    fi
}

# ── Handlers (each runs as its own background subshell) ──────────────────────
# Predicate rule: one `log stream` per rule feeds a FIFO; this loop reads it.
# Cooldown state (RULE_LAST_DIALOG) is private to this subshell, i.e. per rule.
run_predicate_handler() {
    local idx="$1"
    local rule_name="${RULE_NAMES[${idx}]}"
    local predicate="${RULE_PREDICATES[${idx}]}"
    local fifo="${RUN_DIR}/rule${idx}.fifo"
    local errfile="${RUN_DIR}/rule${idx}.err"
    local backoff="${STREAM_BACKOFF_MIN}"
    local stream_pid started ended runtime stream_rc line err_text

    while true
    do
        "${RM}" -f "${fifo}"
        if ! "${MKFIFO}" "${fifo}"
        then
            log_error "Rule '${rule_name}': could not create FIFO ${fifo}; handler exiting"
            return 1
        fi
        : > "${errfile}"

        started=$("${DATE}" +%s)
        "${LOG}" stream --predicate "${predicate}" --style default > "${fifo}" 2> "${errfile}" &
        stream_pid=$!
        # Pidfile lets stop_children reap this stream even if the handler itself died first.
        printf '%s\n' "${stream_pid}" > "${RUN_DIR}/rule${idx}.pid"
        log_info "Rule '${rule_name}': log stream started (pid ${stream_pid})"

        while IFS= read -r line
        do
            if [[ "${line}" =~ ${EVENT_REGEX} ]]
            then
                log_info "Rule '${rule_name}': event matched"
                handle_rule_event "${idx}"
            fi
        done < "${fifo}"

        if wait "${stream_pid}" 2>/dev/null
        then
            stream_rc=0
        else
            stream_rc=$?
        fi
        ended=$("${DATE}" +%s)
        runtime=$((ended - started))
        err_text=$("${TR}" '\n' ' ' < "${errfile}")

        if [[ "${runtime}" -lt "${STREAM_MIN_RUNTIME}" ]]
        then
            log_error "Rule '${rule_name}': log stream exited after ${runtime}s (rc=${stream_rc}); predicate likely invalid: ${err_text:0:300}"
            log_warn "Rule '${rule_name}': skipping for ${backoff}s (other rules unaffected)"
            interruptible_sleep "${backoff}"
            backoff=$((backoff * 2))
            if [[ "${backoff}" -gt "${STREAM_BACKOFF_MAX}" ]]
            then
                backoff="${STREAM_BACKOFF_MAX}"
            fi
        else
            log_warn "Rule '${rule_name}': log stream ended after ${runtime}s (rc=${stream_rc}); restarting"
            backoff="${STREAM_BACKOFF_MIN}"
            interruptible_sleep 2
        fi
    done
}

# Presence rules: a single shared poll loop covers every rule that has no Predicate.
run_presence_handler() {
    local idx
    local count="${#RULE_NAMES[@]}"

    log_info "Presence poll started (every ${PRESENCE_POLL_INTERVAL}s)"
    while true
    do
        idx=0
        while [[ "${idx}" -lt "${count}" ]]
        do
            if [[ -z "${RULE_PREDICATES[${idx}]}" ]]
            then
                if "${PGREP}" -x "${RULE_WATCHES[${idx}]}" >/dev/null 2>&1
                then
                    log_info "Rule '${RULE_NAMES[${idx}]}': watched process '${RULE_WATCHES[${idx}]}' is running (kills '${RULE_KILLS[${idx}]}')"
                    handle_rule_event "${idx}"
                fi
            fi
            idx=$((idx + 1))
        done
        interruptible_sleep "${PRESENCE_POLL_INTERVAL}"
    done
}

# ── Child management ─────────────────────────────────────────────────────────
start_children() {
    local idx=0
    local count="${#RULE_NAMES[@]}"
    local presence_count=0

    while [[ "${idx}" -lt "${count}" ]]
    do
        if [[ -n "${RULE_PREDICATES[${idx}]}" ]]
        then
            run_predicate_handler "${idx}" &
            CHILD_PIDS+=("$!")
        else
            presence_count=$((presence_count + 1))
        fi
        idx=$((idx + 1))
    done

    if [[ "${presence_count}" -gt 0 ]]
    then
        run_presence_handler &
        CHILD_PIDS+=("$!")
    fi

    log_info "Started ${#CHILD_PIDS[@]} handler(s) for ${count} rule(s)"
}

# Collect each handler's children BEFORE killing it (they reparent to launchd afterwards),
# then kill handler first (so it cannot respawn its stream) and its children second.
stop_children() {
    local idx=0
    local count="${#CHILD_PIDS[@]}"
    local pid child child_list

    while [[ "${idx}" -lt "${count}" ]]
    do
        pid="${CHILD_PIDS[${idx}]}"
        if kill -0 "${pid}" 2>/dev/null
        then
            if ! child_list=$("${PGREP}" -P "${pid}" 2>/dev/null)
            then
                child_list=""
            fi
            if ! kill "${pid}" 2>/dev/null
            then
                log_debug "Handler ${pid} already gone"
            fi
            # shellcheck disable=SC2086 # intentional word splitting of a PID list
            for child in ${child_list}
            do
                if ! kill "${child}" 2>/dev/null
                then
                    log_debug "Child ${child} already gone"
                fi
            done
            log_info "Stopped handler pid ${pid} and its children (${child_list//$'\n'/ })"
        fi
        if ! wait "${pid}" 2>/dev/null
        then
            log_debug "Handler ${pid} reaped (non-zero status expected after kill)"
        fi
        idx=$((idx + 1))
    done
    CHILD_PIDS=()
    reap_stray_streams
}

# Safety net: kill any `log stream` recorded in a pidfile that is still alive (verified by name,
# so a recycled PID is never touched), then remove the pidfile.
reap_stray_streams() {
    local pid_file stray_pid stray_comm

    if [[ -z "${RUN_DIR}" ]]
    then
        return 0
    fi

    for pid_file in "${RUN_DIR}"/*.pid
    do
        if [[ ! -f "${pid_file}" ]]
        then
            continue
        fi
        stray_pid=$(<"${pid_file}")
        if [[ "${stray_pid}" =~ ^[0-9]+$ ]]
        then
            if stray_comm=$("${PS}" -p "${stray_pid}" -o comm= 2>/dev/null)
            then
                if [[ "${stray_comm##*/}" == "log" ]]
                then
                    log_warn "Reaping stray log stream pid ${stray_pid}"
                    if ! kill "${stray_pid}" 2>/dev/null
                    then
                        log_debug "Stray stream ${stray_pid} already gone"
                    fi
                fi
            fi
        fi
        "${RM}" -f "${pid_file}"
    done
}

children_healthy() {
    local idx=0
    local count="${#CHILD_PIDS[@]}"

    while [[ "${idx}" -lt "${count}" ]]
    do
        if ! kill -0 "${CHILD_PIDS[${idx}]}" 2>/dev/null
        then
            return 1
        fi
        idx=$((idx + 1))
    done
    return 0
}

# ── Modes ────────────────────────────────────────────────────────────────────
# Main loop. Re-scan is in-process (not WatchPaths): with KeepAlive the job is always
# running, so WatchPaths would never fire. On any rule change, stop all children and restart.
run_watcher() {
    local active_signature

    RUN_DIR=$("${MKTEMP}" -d)
    TEMP_DIRS+=("${RUN_DIR}")
    "${MKDIR}" -p "${TRACKING_DIR}"

    compute_rules_signature
    active_signature="${RULES_SIGNATURE}"
    load_rules
    start_children

    while true
    do
        interruptible_sleep "${RESCAN_INTERVAL}"

        compute_rules_signature
        if [[ "${RULES_SIGNATURE}" != "${active_signature}" ]]
        then
            log_info "Rule set changed; restarting all handlers"
            stop_children
            active_signature="${RULES_SIGNATURE}"
            load_rules
            start_children
        elif ! children_healthy
        then
            log_warn "A handler died unexpectedly; restarting all handlers"
            stop_children
            load_rules
            start_children
        fi
    done
}

##################################
### End User Defined Functions ###
##################################
###################################################################################
############## End Function Block #################################################
###################################################################################

#####################################################
################## Run Script Block #################
#####################################################

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting"

require_root
validate_config

# The LaunchDaemon passes --run. --validate is a dry run that loads and reports rules.
MODE="${1:---run}"
log_info "Mode: ${MODE}"

case "${MODE}" in
    --run)
        run_watcher
        ;;
    --validate)
        load_rules
        ;;
    *)
        printf 'Usage: %s [--run|--validate]\n' "${SCRIPT_NAME}" >&2
        exit 1
        ;;
esac

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################
WATCHER_SCRIPT_EOF

    while IFS= read -r line
    do
        line="${line//__DOMAIN_PREFIX__/${DOMAIN_PREFIX}}"
        line="${line//__BANNER_IMAGE__/${BANNER_IMAGE}}"
        line="${line//__BANNER_HEIGHT__/${BANNER_HEIGHT}}"
        line="${line//__DIALOG_ICON_SIZE__/${DIALOG_ICON_SIZE}}"
        line="${line//__DIALOG_ICON__/${DIALOG_ICON}}"
        line="${line//__ORG_NAME_FRIENDLY__/${ORG_NAME_FRIENDLY}}"
        line="${line//__ORG_PLIST_DOMAIN__/${ORG_PLIST_DOMAIN}}"
        printf '%s\n' "${line}"
    done < "${staging}" > "${INSTALL_SCRIPT_PATH}"

    "${CHOWN}" root:wheel "${INSTALL_SCRIPT_PATH}"
    "${CHMOD}" 755 "${INSTALL_SCRIPT_PATH}"

    if ! "${BASH_BIN}" -n "${INSTALL_SCRIPT_PATH}"
    then
        log_error "Generated watcher failed bash -n: ${INSTALL_SCRIPT_PATH}"
        return 1
    fi
    log_info "Wrote watcher script ${INSTALL_SCRIPT_PATH}"
}

write_daemon_plist() {
    "${CAT}" > "${DAEMON_PLIST_PATH}" <<DAEMON_PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_SCRIPT_PATH}</string>
        <string>--run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/var/log/${DAEMON_LABEL}.err</string>
</dict>
</plist>
DAEMON_PLIST_EOF

    "${CHOWN}" root:wheel "${DAEMON_PLIST_PATH}"
    "${CHMOD}" 644 "${DAEMON_PLIST_PATH}"

    if ! "${PLUTIL}" -lint "${DAEMON_PLIST_PATH}" >/dev/null 2>&1
    then
        log_error "Generated plist failed plutil -lint: ${DAEMON_PLIST_PATH}"
        return 1
    fi
    log_info "Wrote LaunchDaemon plist ${DAEMON_PLIST_PATH}"
}

# Idempotent: every step runs on every pass so a re-run upgrades in place.
do_install() {
    log_info "Installing ${DAEMON_LABEL} (installer v${SCRIPT_VERSION})"

    "${MKDIR}" -p "${INSTALL_DIR}" "${TRACKING_DIR}"
    "${CHOWN}" root:wheel "${INSTALL_DIR}" "${TRACKING_DIR}"
    "${CHMOD}" 755 "${INSTALL_DIR}" "${TRACKING_DIR}"

    if ! write_watcher_script
    then
        return 1
    fi

    if ! write_daemon_plist
    then
        return 1
    fi

    if "${LAUNCHCTL}" print "system/${DAEMON_LABEL}" >/dev/null 2>&1
    then
        if ! "${LAUNCHCTL}" bootout "system/${DAEMON_LABEL}" 2>/dev/null
        then
            log_warn "launchctl bootout reported an error (continuing)"
        fi
        "${SLEEP}" 1
    fi

    if ! "${LAUNCHCTL}" bootstrap system "${DAEMON_PLIST_PATH}" 2>/dev/null
    then
        log_error "launchctl bootstrap failed for ${DAEMON_PLIST_PATH}"
        return 1
    fi

    log_info "Install complete"
}

# Leaves ${TRACKING_DIR} so EA history survives a reinstall; delete it by hand to purge.
do_uninstall() {
    log_info "Uninstalling ${DAEMON_LABEL}"

    if "${LAUNCHCTL}" print "system/${DAEMON_LABEL}" >/dev/null 2>&1
    then
        if ! "${LAUNCHCTL}" bootout "system/${DAEMON_LABEL}" 2>/dev/null
        then
            log_warn "launchctl bootout reported an error (continuing)"
        fi
    fi

    "${RM}" -f "${DAEMON_PLIST_PATH}" "${INSTALL_SCRIPT_PATH}"
    log_info "Uninstall complete (tracking data retained in ${TRACKING_DIR})"
}

##################################
### End User Defined Functions ###
##################################
###################################################################################
############## End Function Block #################################################
###################################################################################

#####################################################
################## Run Script Block #################
#####################################################

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting (mode: ${PARAM_MODE})"

require_root
validate_config

case "${PARAM_MODE}" in
    install|--install)
        do_install
        ;;
    uninstall|--uninstall)
        do_uninstall
        ;;
    *)
        log_error "Unknown mode '${PARAM_MODE}' (parameter 4 must be install or uninstall)"
        exit 1
        ;;
esac

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################
