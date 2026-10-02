# shellcheck shell=bash
#
# Paths, translations and output helpers.
#
# Everything rdfeed keeps is the user's own: a settings file and one file per
# workspace under ~/.config/rdfeed, the downloaded apps under
# ~/.local/share/rdfeed, and the passwords in the keyring. Nothing needs root.

RF_VERSION="@VERSION@"
RF_NAME="rdfeed"
RF_PRETTY="rdfeed"

RF_LIBDIR="${RF_LIBDIR:-@LIBDIR@}"
RF_LIBEXECDIR="${RF_LIBEXECDIR:-@LIBEXECDIR@}"
RF_LOCALEDIR="${RF_LOCALEDIR:-@LOCALEDIR@}"

RF_FETCH="${RF_FETCH:-$RF_LIBEXECDIR/rdfeed-fetch}"
RF_HOOK="${RF_HOOK:-$RF_LIBEXECDIR/rdfeed-hook.so}"

RF_XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
RF_XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
RF_XDG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"

RF_CONFDIR="${RF_XDG_CONFIG}/${RF_NAME}"
RF_CONFIG="${RF_CONFDIR}/config"
RF_WSDIR="${RF_CONFDIR}/workspaces"
RF_DATADIR="${RF_XDG_DATA}/${RF_NAME}"
RF_CACHEDIR="${RF_XDG_CACHE}/${RF_NAME}"
# For what only lives while an app runs: the .rdp copy that names a file.
RF_RUNDIR="${XDG_RUNTIME_DIR:-$RF_CACHEDIR}/${RF_NAME}"

# Where the app menu looks: the entries, the folder for each workspace (a
# merged menu) and the folder's name and icon.
RF_APPDIR="${RF_XDG_DATA}/applications"
RF_MENUDIR="${RF_XDG_CONFIG}/menus/applications-merged"
RF_DIRDIR="${RF_XDG_DATA}/desktop-directories"

RF_UNIT_TIMER="rdfeed-refresh.timer"

# ---------------------------------------------------------------------------
# Translations
# ---------------------------------------------------------------------------

export TEXTDOMAIN="rdfeed"
export TEXTDOMAINDIR="${RF_LOCALEDIR}"

rf_ui_locale() {
	local l="${RF_UI_LOCALE:-}"

	if [[ -z $l ]]; then
		l="${LC_ALL:-}"
		[[ -z $l ]] && l="${LC_MESSAGES:-}"
		[[ -z $l ]] && l="${LANG:-}"
	fi

	# systemd writes /etc/locale.conf and most distributions use it; Debian and
	# Ubuntu keep the same LANG= line in /etc/default/locale instead.
	if [[ -z $l ]]; then
		local f
		for f in /etc/locale.conf /etc/default/locale; do
			[[ -r $f ]] || continue
			l="$(sed -n 's/^LANG=//p' "$f" | tr -d '"' | head -n1)"
			[[ -n $l ]] && break
		done
	fi

	printf '%s\n' "${l:-C}"
}

# Every gettext lookup is a fork and the settings screen redraws a screenful of
# labels per keypress, so results are memoized.
declare -A RF_MSG_CACHE=()

RF_MSG_RESULT=''

# rf_msg_into <locale> <msgid>
# Plain lookup with the result in RF_MSG_RESULT and no printf formatting, for
# callers that would otherwise pay a fork per label per frame.
rf_msg_into() {
	local locale="$1" msgid="$2" cachekey
	cachekey="${locale}"$'\x1f'"${msgid}"

	if [[ -n ${RF_MSG_CACHE[$cachekey]+set} ]]; then
		RF_MSG_RESULT="${RF_MSG_CACHE[$cachekey]}"
		return 0
	fi

	RF_MSG_RESULT="$(LC_ALL="$locale" LANGUAGE="${locale%%.*}" gettext -- "$msgid" 2>/dev/null)"
	[[ -n $RF_MSG_RESULT ]] || RF_MSG_RESULT="$msgid"
	RF_MSG_CACHE[$cachekey]="$RF_MSG_RESULT"
	return 0
}

# rf_msg_in <locale> <msgid> [printf args...]
rf_msg_in() {
	local locale="$1" msgid="$2"
	shift 2

	rf_msg_into "$locale" "$msgid"

	# With no arguments the message is plain text, not a format string. Feeding
	# it to printf anyway would turn a literal percent sign in a translation
	# into an invalid conversion.
	if (( $# == 0 )); then
		printf '%s' "$RF_MSG_RESULT"
		return
	fi

	# shellcheck disable=SC2059  # the format string is the translated message
	printf -- "$RF_MSG_RESULT" "$@"
}

RF_LOCALE_CACHED=''

# rf_msg <msgid> [printf args...]
rf_msg() {
	[[ -n $RF_LOCALE_CACHED ]] || RF_LOCALE_CACHED="$(rf_ui_locale)"
	rf_msg_in "$RF_LOCALE_CACHED" "$@"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# Decided once, while stdout is still whatever the process was started with:
# testing -t 1 at the point of use is wrong for anything called through $(...),
# which sees a pipe and would conclude nobody is watching.
RF_INTERACTIVE=''
[[ -t 1 ]] && RF_INTERACTIVE=1

if [[ -n $RF_INTERACTIVE && -z ${NO_COLOR:-} ]]; then
	RF_C_RESET=$'\033[0m'
	RF_C_BOLD=$'\033[1m'
	RF_C_DIM=$'\033[2m'
	RF_C_BLUE=$'\033[38;2;52;153;255m'
	RF_C_GREEN=$'\033[32m'
	RF_C_YELLOW=$'\033[33m'
	RF_C_RED=$'\033[31m'
else
	RF_C_RESET='' RF_C_BOLD='' RF_C_DIM='' RF_C_BLUE=''
	RF_C_GREEN='' RF_C_YELLOW='' RF_C_RED=''
fi

# What rf_ok, rf_bad and rf_note printed. The menu redraws straight after an
# action, which wipes the screen, so it shows these again under the new frame
# rather than holding everything up for a key press.
RF_UI_NOTICES=()

rf_say()  { printf '%s\n' "$*"; }
rf_head() { printf '\n%s%s%s\n\n' "$RF_C_BOLD$RF_C_BLUE" "$*" "$RF_C_RESET"; }
rf_ok()   { RF_UI_NOTICES+=("$RF_C_GREEN✔$RF_C_RESET $*"); printf '%s✔%s %s\n' "$RF_C_GREEN" "$RF_C_RESET" "$*"; }
rf_bad()  { RF_UI_NOTICES+=("$RF_C_RED✘$RF_C_RESET $*"); printf '%s✘%s %s\n' "$RF_C_RED" "$RF_C_RESET" "$*" >&2; }
rf_note() { RF_UI_NOTICES+=("$RF_C_DIM•$RF_C_RESET $*"); printf '%s•%s %s\n' "$RF_C_DIM" "$RF_C_RESET" "$*"; }

rf_have() { command -v "$1" > /dev/null 2>&1; }

# rf_notify <summary> <body> [icon]
# A desktop notification, for what happens after the menu or the app menu
# started something and nobody watches a terminal.
rf_notify() {
	rf_have notify-send || return 0
	notify-send -a "$RF_PRETTY" -i "${3:-rdfeed}" -- "$1" "$2" > /dev/null 2>&1 || true
}

# Human-readable "x minutes ago" for a unix timestamp. 0 or empty yields the
# translated "never".
#
# Written with [[ ]] and a variable for each number on purpose: xgettext reads
# the < of an (( )) as a redirection and loses every string after it.
rf_time_ago() {
	local ts="$1" now delta n

	if [[ ! $ts =~ ^[0-9]+$ || $ts -eq 0 ]]; then
		rf_msg "never"
		printf '\n'
		return
	fi

	now="$(date +%s)"
	delta=$(( now - ts ))
	[[ $delta -lt 0 ]] && delta=0

	if [[ $delta -lt 60 ]]; then
		rf_msg "just now"
	elif [[ $delta -lt 120 ]]; then
		rf_msg "1 minute ago"
	elif [[ $delta -lt 3600 ]]; then
		n=$(( delta / 60 ))
		rf_msg "%d minutes ago" "$n"
	elif [[ $delta -lt 7200 ]]; then
		rf_msg "1 hour ago"
	elif [[ $delta -lt 86400 ]]; then
		n=$(( delta / 3600 ))
		rf_msg "%d hours ago" "$n"
	elif [[ $delta -lt 172800 ]]; then
		rf_msg "1 day ago"
	else
		n=$(( delta / 86400 ))
		rf_msg "%d days ago" "$n"
	fi
	printf '\n'
}
