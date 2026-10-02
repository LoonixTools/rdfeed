# shellcheck shell=bash
#
# Reading and writing the settings files.
#
# ~/.config/rdfeed/config holds how the apps run (a shared folder, the size,
# the graphics), and ~/.config/rdfeed/workspaces/<id> where a workspace comes
# from and who signs in to it. Neither is meant to be edited by hand: every
# option is in the menu.
#
# Both are parsed rather than sourced. One "Key=Value" per line, '#' comments.

declare -A RF_KV_CACHE=()

# _rf_kv_lookup <file> <Key> [default]
# Result in RF_KV_VALUE. Assigning rather than printing matters on the
# settings screen, which reads every key on every frame: a command
# substitution there is a fork, and forks are the whole cost of a redraw.
RF_KV_VALUE=''

_rf_kv_lookup() {
	local file="$1" key="$2" default="${3:-}" val='' line content

	RF_KV_VALUE="$default"
	[[ -r $file ]] || return 0

	if [[ -n ${RF_KV_CACHE[$file]+set} ]]; then
		content="${RF_KV_CACHE[$file]}"
	else
		content="$(< "$file")"
		RF_KV_CACHE[$file]="$content"
	fi

	while IFS= read -r line; do
		[[ $line == *"$key"* ]] || continue
		[[ $line =~ ^[[:space:]]*"$key"[[:space:]]*=(.*)$ ]] || continue
		val="${BASH_REMATCH[1]}"
	done <<< "$content"

	val="${val#"${val%%[![:space:]]*}"}"
	val="${val%"${val##*[![:space:]]}"}"

	[[ -n $val ]] && RF_KV_VALUE="$val"
	return 0
}

rf_is_true() {
	case "${1,,}" in
		yes|y|true|1|on|enabled) return 0 ;;
		*) return 1 ;;
	esac
}

# rf_kv_set <file> <Key> <Value> <header line>
rf_kv_set() {
	local file="$1" key="$2" value="$3" header="$4" tmp

	if [[ ! -e $file ]]; then
		mkdir -p "$(dirname "$file")" || return 1
		{
			printf '# %s\n' "$header"
			printf '#\n'
			# shellcheck disable=SC2016  # the backticks are text
			printf '# Written by `%s`. Nothing here needs editing by hand:\n' "$RF_NAME"
			printf '# every option is in the menu.\n'
		} > "$file" || return 1
	fi
	[[ -w $file ]] || return 1

	tmp="$(mktemp "${file}.XXXXXX")" || return 1
	chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0644 "$tmp"

	if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
		awk -v key="$key" -v value="$value" '
			!done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=" {
				print key "=" value; done = 1; next
			}
			# drop any further occurrences so the file cannot grow duplicates
			$0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
			{ print }
		' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
	else
		cat "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
		printf '%s=%s\n' "$key" "$value" >> "$tmp"
	fi

	mv -f "$tmp" "$file"
	unset 'RF_KV_CACHE[$file]'
}

# ---------------------------------------------------------------------------
# The settings
# ---------------------------------------------------------------------------

rf_config_get() {
	_rf_kv_lookup "$RF_CONFIG" "$@"
	printf '%s\n' "$RF_KV_VALUE"
}

rf_config_set() {
	rf_kv_set "$RF_CONFIG" "$1" "$2" "$RF_PRETTY"
}

# rf_config_load
# Everything starting an app needs, resolved once.
rf_config_load() {
	RF_KV_CACHE=()
	_rf_kv_lookup "$RF_CONFIG" Share off;        CFG_SHARE="$RF_KV_VALUE"
	_rf_kv_lookup "$RF_CONFIG" Scale auto;       CFG_SCALE="$RF_KV_VALUE"
	_rf_kv_lookup "$RF_CONFIG" Graphics gfx;     CFG_GRAPHICS="$RF_KV_VALUE"
	_rf_kv_lookup "$RF_CONFIG" MfaWait auto;     CFG_MFAWAIT="$RF_KV_VALUE"
	_rf_kv_lookup "$RF_CONFIG" Sound yes;        CFG_SOUND=no; rf_is_true "$RF_KV_VALUE" && CFG_SOUND=yes
	return 0
}

# ---------------------------------------------------------------------------
# Workspaces
# ---------------------------------------------------------------------------

rf_ws_file() { printf '%s/%s\n' "$RF_WSDIR" "$1"; }

# rf_ws_ids
# The workspaces, sorted, in RF_WS_IDS.
RF_WS_IDS=()

rf_ws_ids() {
	local f
	RF_WS_IDS=()
	[[ -d $RF_WSDIR ]] || return 0
	for f in "$RF_WSDIR"/*; do
		[[ -f $f ]] || continue
		RF_WS_IDS+=("${f##*/}")
	done
}

# rf_ws_load <id>
# Sets WS_URL, WS_NAME, WS_USER, WS_DOMAIN, WS_REFRESHED and WS_ACCOUNT, the
# name the way Windows writes it (DOMAIN\user, or user@domain as typed).
rf_ws_load() {
	local file
	file="$(rf_ws_file "$1")"
	_rf_kv_lookup "$file" Url;       WS_URL="$RF_KV_VALUE"
	_rf_kv_lookup "$file" Name "$1"; WS_NAME="$RF_KV_VALUE"
	_rf_kv_lookup "$file" User;      WS_USER="$RF_KV_VALUE"
	_rf_kv_lookup "$file" Domain;    WS_DOMAIN="$RF_KV_VALUE"
	_rf_kv_lookup "$file" Refreshed 0; WS_REFRESHED="$RF_KV_VALUE"
	if [[ -n $WS_DOMAIN && $WS_USER != *@* ]]; then
		WS_ACCOUNT="$WS_DOMAIN\\$WS_USER"
	else
		WS_ACCOUNT="$WS_USER"
	fi
}

rf_ws_set() {
	rf_kv_set "$(rf_ws_file "$1")" "$2" "$3" "$RF_PRETTY workspace"
}
