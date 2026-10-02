# shellcheck shell=bash
#
# The interactive front end.
#
# This is the whole configuration interface. There are files behind it, but no
# part of the program ever asks anybody to open one: the workspaces, the apps,
# a settings list.

# Terminal mode.
#
# bash flips the terminal into non-canonical mode for each `read -sn1` and back
# out again in between. That gap matters: in canonical mode DEL is the ERASE
# character, so the line discipline eats it instead of delivering it, and a
# backspace typed while the interface was between reads simply vanishes.
# Holding non-canonical mode for the whole interface removes the gap.
RF_TERM_SAVED=''

rf_ui_term_raw() {
	rf_have stty || return 0
	[[ -t 0 ]] || return 0
	[[ -n $RF_TERM_SAVED ]] && return 0

	RF_TERM_SAVED="$(stty -g 2>/dev/null)" || { RF_TERM_SAVED=''; return 0; }
	stty -icanon -echo min 1 time 0 2>/dev/null || true
}

rf_ui_term_restore() {
	[[ -n $RF_TERM_SAVED ]] || return 0
	stty "$RF_TERM_SAVED" 2>/dev/null || true
	RF_TERM_SAVED=''
}

# Runs an action with the terminal handed back to normal line mode, so what it
# prompts for (a user name, a password) behaves the way a program expects.
rf_ui_cooked() {
	rf_ui_term_restore
	"$@"
	local rc=$?
	rf_ui_term_raw
	return $rc
}

# rf_read_key
# One keypress, resolved to a symbolic name. Arrow keys arrive as ESC [ A, so
# the tail of the sequence is consumed here rather than being mistaken for
# three separate presses.
rf_read_key() {
	local k rest

	IFS= read -rsn1 k || return 1

	case "$k" in
		$'\e')
			if IFS= read -rsn2 -t 0.05 rest; then
				case "$rest" in
					'[A') printf 'up\n' ;;
					'[B') printf 'down\n' ;;
					'[C') printf 'right\n' ;;
					'[D') printf 'left\n' ;;
					*)    printf 'escape\n' ;;
				esac
			else
				printf 'escape\n'
			fi
			;;
		''|$'\r')      printf 'enter\n' ;;
		$'\x7f'|$'\b') printf 'backspace\n' ;;
		' ')           printf 'space\n' ;;
		*)             printf '%s\n' "$k" ;;
	esac
}

# _rf_ui_take_notices
# The messages the last action left, as lines for under a frame, in
# RF_UI_NOTICE_TEXT. Each is shown once.
RF_UI_NOTICE_TEXT=''

_rf_ui_take_notices() {
	local n
	RF_UI_NOTICE_TEXT=''
	(( ${#RF_UI_NOTICES[@]} )) || return 0
	RF_UI_NOTICE_TEXT=$'\n'
	for n in "${RF_UI_NOTICES[@]}"; do
		RF_UI_NOTICE_TEXT+="  $n"$'\n'
	done
	RF_UI_NOTICES=()
}

# rf_ui_confirm <question>
rf_ui_confirm() {
	local key hint yes
	# TRANSLATORS: the letter after "[" is the key for yes. y works too.
	hint="$(rf_msg "[y/N]")"
	yes="${hint:1:1}"
	printf '\n  %s %s ' "$1" "$hint"
	key="$(rf_read_key)" || return 1
	printf '%s\n' "$key"
	[[ ${key,,} == y || ${key,,} == "${yes,,}" ]]
}

# _rf_width <text>
# The columns the text takes, into RF_WIDTH. ${#s} counts characters, but
# Chinese, Japanese and Korean ones take two columns each.
RF_WIDTH=0

_rf_width() {
	local wide="${1//[^　-〿぀-ヿ㐀-䶿一-鿿가-힯豈-﫿＀-｠]/}"
	RF_WIDTH=$(( ${#1} + ${#wide} ))
}

# _rf_pad <text> <columns>
# The text, padded with spaces to the columns, into RF_PADDED. printf's %-28s
# pads by bytes, so a label containing "ü" would come out one column short.
RF_PADDED=''

_rf_pad() {
	local pad
	_rf_width "$1"
	pad=$(( $2 - RF_WIDTH ))
	(( pad < 1 )) && pad=1
	printf -v RF_PADDED '%s%*s' "$1" "$pad" ''
}

# _rf_wrap <width> <text>
# Word wrap, into RF_WRAP_LINES.
RF_WRAP_LINES=()

_rf_wrap() {
	local width="$1" word line='' used=0 c i
	local -a words
	RF_WRAP_LINES=()
	read -r -a words <<< "$2"
	for word in "${words[@]}"; do
		_rf_width "$word"
		if (( used > 0 && used + 1 + RF_WIDTH > width )); then
			RF_WRAP_LINES+=("$line")
			line='' used=0
		fi
		(( used > 0 )) && line+=' ' used=$(( used + 1 ))
		if (( used + RF_WIDTH <= width )); then
			line+="$word" used=$(( used + RF_WIDTH ))
			continue
		fi
		# Longer than a line: Chinese and Japanese have no spaces, so break
		# between any two characters.
		for (( i = 0; i < ${#word}; i++ )); do
			c="${word:i:1}"
			_rf_width "$c"
			if (( used + RF_WIDTH > width )); then
				RF_WRAP_LINES+=("$line")
				line='' used=0
			fi
			line+="$c" used=$(( used + RF_WIDTH ))
		done
	done
	[[ -n $line ]] && RF_WRAP_LINES+=("$line")
	return 0
}

# _rf_apps_label <count>
_rf_apps_label() {
	if [[ $1 == 1 ]]; then
		rf_msg "1 app"
	else
		rf_msg "%d apps" "$1"
	fi
}

# rf_start_detached <id> <app>
# Starts an app on its own, so it keeps running when the menu closes.
rf_start_detached() {
	if rf_have setsid; then
		setsid -f "$RF_SELF" run "$1/$2" > /dev/null 2>&1 < /dev/null
	else
		nohup "$RF_SELF" run "$1/$2" > /dev/null 2>&1 < /dev/null &
	fi
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

# rf_ui_status
# The workspaces, for the head of the menu.
rf_ui_status() {
	local id width=0 apps

	rf_ws_ids
	if (( ${#RF_WS_IDS[@]} == 0 )); then
		printf '  %s\n' "$(rf_msg "No workspace yet. Add the one of your company with [1].")"
		return 0
	fi
	for id in "${RF_WS_IDS[@]}"; do
		rf_ws_load "$id"
		_rf_width "$WS_NAME"
		(( RF_WIDTH > width )) && width=$RF_WIDTH
	done
	for id in "${RF_WS_IDS[@]}"; do
		rf_ws_load "$id"
		rf_ws_apps_load "$id"
		_rf_pad "$WS_NAME" $(( width + 3 ))
		apps="$(_rf_apps_label "${#RF_APP_SLUGS[@]}")"
		printf '  %s%-10s %s%s%s\n' "$RF_PADDED" "$apps" "$RF_C_DIM" "$WS_ACCOUNT" "$RF_C_RESET"
	done
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# Format: scope|Key|type|default|label-msgid|choices
#   scope  user (the settings file), entries (the settings file, and the app
#          menu entries are written again), timer (the daily refresh, a
#          systemd user timer), or group for a heading, with only the label
#          after it
#   type   bool, or choice (steps through the choices)
RF_SETTINGS=(
	"group|Apps"
	"user|Share|choice|off|Share a folder|off,documents,downloads,home"
	"entries|OpenWith|bool|yes|Open files with the apps"
	"user|Scale|choice|auto|Size|auto,100,125,150,175,200"
	"user|Sound|bool|yes|Sound"
	"user|Graphics|choice|gfx|Graphics|gfx,classic"
	"group|Signing in"
	"user|MfaWait|choice|auto|Wait for the second MFA prompt|auto,always,never"
	"timer|AutoRefresh|bool|yes|Refresh the apps every day"
)

# rf_value_label <Key> <value>
# How a setting's value reads in the menu.
rf_value_label() {
	local dir
	case "$1:$2" in
		Share:off)        rf_msg "off" ;;
		Share:home)       rf_msg "home folder" ;;
		Share:documents|Share:downloads)
			case "$2" in
				documents) rf_msg "Documents" ;;
				*)         rf_msg "Downloads" ;;
			esac
			if dir="$(CFG_SHARE="$2" rf_share_dir)"; then
				printf ' %s(%s)%s' "$RF_C_DIM" "${dir/#"$HOME"/\~}" "$RF_C_RESET"
			else
				printf ' %s(%s)%s' "$RF_C_YELLOW" "$(rf_msg "not found")" "$RF_C_RESET"
			fi
			;;
		Scale:auto)       rf_auto_scale; rf_msg "automatic (%d %%)" "$RF_AUTO_SCALE" ;;
		Scale:*)          printf '%s %%' "$2" ;;
		Graphics:classic) rf_msg "classic" ;;
		Graphics:*)       rf_msg "GFX" ;;
		MfaWait:always)   rf_msg "always" ;;
		MfaWait:never)    rf_msg "never" ;;
		MfaWait:*)        rf_msg "automatic" ;;
		*)                printf '%s' "$2" ;;
	esac
}

# rf_setting_help <Key> <value>
# What a setting does, shown under the list for the selected one.
rf_setting_help() {
	case "$1:$2" in
		Share:off)        rf_msg "The apps only see the files on the server. Pick a folder to open and save files of this computer in them." ;;
		Share:*)          rf_msg "The apps can open and save files in this folder. It shows up as a drive in them." ;;
		OpenWith:*)       rf_msg "Offers the apps under \"Open with\" for their file types, for example Word for .docx. The folder of the file is shared with the app while it is open." ;;
		Scale:*)          rf_msg "How big the apps are drawn. Automatic follows the scale of your desktop, so they are sharp and the right size." ;;
		Sound:*)          rf_msg "Plays the sound of the apps here, for calls and videos." ;;
		Graphics:classic) rf_msg "Paints every window right. But some servers end the session right after signing in, then go back to GFX." ;;
		Graphics:*)       rf_msg "Works with every server. FreeRDP may not repaint a window after it was minimized or resized." ;;
		MfaWait:always)   rf_msg "Always waits before the second sign-in. For when the second prompt does not come with automatic." ;;
		MfaWait:never)    rf_msg "Never waits. Right when your company has no MFA." ;;
		MfaWait:*)        rf_msg "Many servers with MFA need a second sign-in, and its prompt only comes after a short wait. Automatic waits when the first sign-in took a while." ;;
		AutoRefresh:*)
			if rf_timer_available; then
				rf_msg "Loads the list of apps again once a day, so new apps show up by themselves."
			else
				rf_msg "Needs a systemd user session."
			fi
			;;
	esac
}

# _rf_setting_value <scope> <Key> <default>
# The current value, in RF_SETTING_VALUE.
RF_SETTING_VALUE=''

_rf_setting_value() {
	case "$1" in
		user|entries) _rf_kv_lookup "$RF_CONFIG" "$2" "$3"; RF_SETTING_VALUE="$RF_KV_VALUE" ;;
		timer) if rf_timer_enabled; then RF_SETTING_VALUE=yes; else RF_SETTING_VALUE=no; fi ;;
	esac
}

# _rf_step <current> <step> <choice>...
# The choice <step> (1 or -1) away from the current one, round at the ends.
_rf_step() {
	local current="$1" step="$2" i
	shift 2
	local -a all=("$@")
	for i in "${!all[@]}"; do
		if [[ ${all[i]} == "$current" ]]; then
			printf '%s\n' "${all[(i + step + ${#all[@]}) % ${#all[@]}]}"
			return
		fi
	done
	printf '%s\n' "${all[0]}"
}

# _rf_setting_change <scope> <Key> <type> <current> <choices> <step>
_rf_setting_change() {
	local scope="$1" key="$2" type="$3" current="$4" options="$5" step="$6" next
	local -a choices

	case "$type" in
		bool) if rf_is_true "$current"; then next=no; else next=yes; fi ;;
		choice)
			IFS=',' read -r -a choices <<< "$options"
			next="$(_rf_step "$current" "$step" "${choices[@]}")"
			;;
	esac

	case "$scope" in
		user)
			rf_config_set "$key" "$next" || rf_bad "$(rf_msg "Could not save the setting.")"
			;;
		entries)
			rf_config_set "$key" "$next" || rf_bad "$(rf_msg "Could not save the setting.")"
			rf_ws_entries_all
			;;
		timer)
			rf_config_set "$key" "$next"
			rf_timer_set "$next" || rf_bad "$(rf_msg "Needs a systemd user session.")"
			;;
	esac
}

# rf_ui_settings
# A cursor list in groups, with what the selected setting does under it. The
# frame is assembled in memory and written once, and everything constant is
# resolved before the loop.
rf_ui_settings() {
	local -a scopes=() keys=() types=() defaults=() labels=() widths=() choices=() values=() rows=()
	local spec scope key type default label choice locale i j frame row pad dirty=1 cursor=0 shown
	local width=0 wrap cols

	locale="$(rf_ui_locale)"
	for spec in "${RF_SETTINGS[@]}"; do
		IFS='|' read -r scope key type default label choice <<< "$spec"
		# A heading has its label where the key would be.
		[[ $scope == group ]] && label="$key" key=''
		scopes+=("$scope"); keys+=("$key"); types+=("$type"); defaults+=("$default")
		choices+=("$choice")
		rf_msg_into "$locale" "$label"
		labels+=("$RF_MSG_RESULT")
		_rf_width "$RF_MSG_RESULT"
		widths+=("$RF_WIDTH")
		if [[ $scope != group ]]; then
			rows+=($(( ${#keys[@]} - 1 )))
			(( RF_WIDTH > width )) && width=$RF_WIDTH
		fi
	done
	local count=${#rows[@]}

	cols="$(tput cols 2>/dev/null)" || cols=80
	[[ $cols =~ ^[0-9]+$ ]] || cols=80
	wrap=$(( cols - 4 ))
	(( wrap > 72 )) && wrap=72
	local rule
	printf -v rule '%*s' "$wrap" ''
	rule="${rule// /─}"

	local title hint l_on l_off
	rf_msg_into "$locale" "Settings"; title="$RF_MSG_RESULT"
	rf_msg_into "$locale" "↑↓ select   ←→ or Space: change   q: back"; hint="$RF_MSG_RESULT"
	rf_msg_into "$locale" "ON"; l_on="$RF_MSG_RESULT"
	rf_msg_into "$locale" "OFF"; l_off="$RF_MSG_RESULT"

	local clearseq
	clearseq="$(clear 2>/dev/null)" || clearseq=$'\033[H\033[2J'

	while true; do
		if (( dirty )); then
			RF_KV_CACHE=()
			for i in "${rows[@]}"; do
				_rf_setting_value "${scopes[i]}" "${keys[i]}" "${defaults[i]}"
				values[i]="$RF_SETTING_VALUE"
			done
			dirty=0
		fi

		frame="$clearseq"$'\n'"${RF_C_BOLD}${RF_C_BLUE}  ${title}${RF_C_RESET}"$'\n'

		local selected=${rows[cursor]} marker before after
		for i in "${!keys[@]}"; do
			if [[ ${scopes[i]} == group ]]; then
				frame+=$'\n'"  ${RF_C_BOLD}${labels[i]}${RF_C_RESET}"$'\n'
				continue
			fi
			if [[ ${types[i]} == bool ]]; then
				if rf_is_true "${values[i]}"; then
					shown="${RF_C_GREEN}${l_on}${RF_C_RESET}"
				else
					shown="${RF_C_DIM}${l_off}${RF_C_RESET}"
				fi
			else
				shown="$(rf_value_label "${keys[i]}" "${values[i]}")"
			fi
			# Arrows on the selected choice: left and right step through it.
			before='  ' after=''
			if (( i == selected )) && [[ ${types[i]} != bool ]]; then
				before="${RF_C_BLUE}◂${RF_C_RESET} " after=" ${RF_C_BLUE}▸${RF_C_RESET}"
			fi
			pad=$(( width + 2 - widths[i] ))
			if (( i == selected )); then marker="${RF_C_BLUE}▸${RF_C_RESET} "; else marker='  '; fi
			printf -v row '  %s%s%*s%s%s%s' "$marker" "${labels[i]}" "$pad" '' "$before" "$shown$RF_C_RESET" "$after"
			frame+="$row"$'\n'
		done

		# What the selected setting does, in a box of fixed height so the
		# screen does not jump while moving through the list.
		_rf_wrap "$wrap" "$(rf_setting_help "${keys[selected]}" "${values[selected]}")"
		frame+=$'\n'"  ${RF_C_DIM}${rule}${RF_C_RESET}"$'\n'
		for j in 0 1 2; do
			frame+="  ${RF_WRAP_LINES[j]:-}"$'\n'
		done
		frame+=$'\n'"  ${RF_C_DIM}${hint}${RF_C_RESET}"$'\n'
		_rf_ui_take_notices
		frame+="$RF_UI_NOTICE_TEXT"
		printf '%s' "$frame"

		key="$(rf_read_key)" || return 0

		case "$key" in
			up|k)   cursor=$(( (cursor - 1 + count) % count )) ;;
			down|j) cursor=$(( (cursor + 1) % count )) ;;
			space|right|l|left|h)
				local step=1
				[[ $key == left || $key == h ]] && step=-1
				_rf_setting_change "${scopes[selected]}" "${keys[selected]}" "${types[selected]}" "${values[selected]}" "${choices[selected]}" "$step"
				dirty=1
				;;
			q|Q|escape) return 0 ;;
			*) ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Workspaces
# ---------------------------------------------------------------------------

rf_ui_workspaces() {
	local key frame row i cursor=0 count locale width
	local -a ids=()

	locale="$(rf_ui_locale)"
	local title hint empty
	rf_msg_into "$locale" "Workspaces"; title="$RF_MSG_RESULT"
	# TRANSLATORS: keep the letters, they are the keys.
	rf_msg_into "$locale" "↑↓ select   r: refresh   s: sign in again   d: remove   a: add   q: back"; hint="$RF_MSG_RESULT"
	rf_msg_into "$locale" "No workspace yet. Press a to add one."; empty="$RF_MSG_RESULT"

	local clearseq
	clearseq="$(clear 2>/dev/null)" || clearseq=$'\033[H\033[2J'

	while true; do
		rf_ws_ids
		ids=("${RF_WS_IDS[@]}")
		count=${#ids[@]}
		(( cursor >= count )) && cursor=$(( count > 0 ? count - 1 : 0 ))

		width=0
		for i in "${!ids[@]}"; do
			rf_ws_load "${ids[i]}"
			_rf_width "$WS_NAME"
			(( RF_WIDTH > width )) && width=$RF_WIDTH
		done

		frame="$clearseq"$'\n'"${RF_C_BOLD}${RF_C_BLUE}  ${title}${RF_C_RESET}"$'\n\n'
		(( count == 0 )) && frame+="  ${RF_C_DIM}${empty}${RF_C_RESET}"$'\n'
		local marker apps when
		for i in "${!ids[@]}"; do
			rf_ws_load "${ids[i]}"
			rf_ws_apps_load "${ids[i]}"
			apps="$(_rf_apps_label "${#RF_APP_SLUGS[@]}")"
			when="$(rf_msg "refreshed %s" "$(rf_time_ago "$WS_REFRESHED")")"
			_rf_pad "$WS_NAME" $(( width + 3 ))
			if (( i == cursor )); then marker="${RF_C_BLUE}▸${RF_C_RESET} "; else marker='  '; fi
			printf -v row '  %s%s%-10s %s  %s%s%s' "$marker" "$RF_PADDED" "$apps" "$WS_ACCOUNT" "$RF_C_DIM" "$when" "$RF_C_RESET"
			frame+="$row"$'\n'
		done
		frame+=$'\n'"  ${RF_C_DIM}${hint}${RF_C_RESET}"$'\n'
		_rf_ui_take_notices
		frame+="$RF_UI_NOTICE_TEXT"
		printf '%s' "$frame"

		key="$(rf_read_key)" || return 0
		case "$key" in
			up|k)   (( count )) && cursor=$(( (cursor - 1 + count) % count )) ;;
			down|j) (( count )) && cursor=$(( (cursor + 1) % count )) ;;
			r|R)
				(( count )) || continue
				printf '\n'
				rf_ui_cooked rf_do_refresh "${ids[cursor]}"
				;;
			s|S)
				(( count )) || continue
				printf '\n'
				rf_ui_cooked rf_do_signin_again "${ids[cursor]}"
				;;
			d|D)
				(( count )) || continue
				rf_ws_load "${ids[cursor]}"
				if rf_ui_confirm "$(rf_msg "Remove \"%s\" and its apps?" "$WS_NAME")"; then
					rf_do_remove "${ids[cursor]}" > /dev/null
				fi
				;;
			a|A)
				printf '\n'
				rf_ui_cooked rf_do_add
				;;
			q|Q|escape) return 0 ;;
			*) ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------

rf_ui_apps() {
	local key frame row i id cursor=0 count locale
	local -a ws=() slugs=() titles=()

	locale="$(rf_ui_locale)"
	local title hint empty
	rf_msg_into "$locale" "Start an app"; title="$RF_MSG_RESULT"
	rf_msg_into "$locale" "↑↓ select   Enter: start   q: back"; hint="$RF_MSG_RESULT"
	rf_msg_into "$locale" "No apps yet. Add a workspace first."; empty="$RF_MSG_RESULT"

	rf_ws_ids
	for id in "${RF_WS_IDS[@]}"; do
		rf_ws_apps_load "$id"
		for i in "${!RF_APP_SLUGS[@]}"; do
			ws+=("$id") slugs+=("${RF_APP_SLUGS[i]}") titles+=("${RF_APP_TITLES[i]}")
		done
	done
	count=${#slugs[@]}

	local clearseq
	clearseq="$(clear 2>/dev/null)" || clearseq=$'\033[H\033[2J'

	while true; do
		frame="$clearseq"$'\n'"${RF_C_BOLD}${RF_C_BLUE}  ${title}${RF_C_RESET}"$'\n'
		(( count == 0 )) && frame+=$'\n'"  ${RF_C_DIM}${empty}${RF_C_RESET}"$'\n'
		local marker last=''
		for i in "${!slugs[@]}"; do
			# A heading for each workspace.
			if [[ ${ws[i]} != "$last" ]]; then
				rf_ws_load "${ws[i]}"
				frame+=$'\n'"  ${RF_C_BOLD}${WS_NAME}${RF_C_RESET}"$'\n'
				last="${ws[i]}"
			fi
			if (( i == cursor )); then marker="${RF_C_BLUE}▸${RF_C_RESET} "; else marker='  '; fi
			printf -v row '  %s%s' "$marker" "${titles[i]}"
			frame+="$row"$'\n'
		done
		frame+=$'\n'"  ${RF_C_DIM}${hint}${RF_C_RESET}"$'\n'
		_rf_ui_take_notices
		frame+="$RF_UI_NOTICE_TEXT"
		printf '%s' "$frame"

		key="$(rf_read_key)" || return 0
		case "$key" in
			up|k)   (( count )) && cursor=$(( (cursor - 1 + count) % count )) ;;
			down|j) (( count )) && cursor=$(( (cursor + 1) % count )) ;;
			enter|space)
				(( count )) || continue
				rf_start_detached "${ws[cursor]}" "${slugs[cursor]}"
				rf_ok "$(rf_msg "%s is starting. It opens in a window of its own." "${titles[cursor]}")" > /dev/null
				;;
			q|Q|escape) return 0 ;;
			*) ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# The menu
# ---------------------------------------------------------------------------

rf_ui_menu() {
	local choice

	if [[ ! -t 0 ]]; then
		rf_do_help
		return 1
	fi
	rf_ui_term_raw
	trap 'rf_ui_term_restore' EXIT INT TERM

	while true; do
		clear 2>/dev/null || true
		rf_head "  $RF_PRETTY"
		rf_ui_status
		printf '\n'
		printf '  [1] %s\n' "$(rf_msg "Add a workspace")"
		printf '  [2] %s\n' "$(rf_msg "Start an app")"
		printf '  [3] %s\n' "$(rf_msg "Workspaces")"
		printf '  [4] %s\n' "$(rf_msg "Settings")"
		printf '  [q] %s\n' "$(rf_msg "Quit")"
		_rf_ui_take_notices
		printf '%s' "$RF_UI_NOTICE_TEXT"
		printf '\n  > '

		choice="$(rf_read_key)" || {
			printf '\n'; rf_ui_term_restore; trap - EXIT INT TERM; return 0
		}
		case "$choice" in
			enter|space|up|down|left|right|escape) choice='' ;;
		esac
		printf '%s\n' "$choice"

		case "$choice" in
			1) printf '\n'; rf_ui_cooked rf_do_add ;;
			2) rf_ui_apps ;;
			3) rf_ui_workspaces ;;
			4) rf_ui_settings ;;
			q|Q) rf_ui_term_restore; trap - EXIT INT TERM; return 0 ;;
			# Anything else (Enter, arrow keys, stray characters) just
			# redraws. Escape is deliberately not a quit key, so a mistyped
			# arrow key cannot close the menu.
			*) ;;
		esac
	done
}
