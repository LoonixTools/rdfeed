# shellcheck shell=bash
#
# Workspaces: the feeds rdfeed is subscribed to, and the app menu entries they
# turn into.
#
# A workspace has an id made from its server name. Its settings are in
# ~/.config/rdfeed/workspaces/<id>, its apps in ~/.local/share/rdfeed/<id>
# (apps.tsv, rdp/<app>.rdp, icons/<app>.png), its password in the keyring.
# Each app gets ~/.local/share/applications/rdfeed-<id>--<app>.desktop, and
# the workspace a folder of its own in the app menu. With "Open files with
# the apps" on, the entries also name the file types, so file managers offer
# the apps under "Open with".

# ---------------------------------------------------------------------------
# The keyring
# ---------------------------------------------------------------------------

rf_secret_get() {
	rf_have secret-tool || return 1
	secret-tool lookup service rdfeed workspace "$1" user "$2" 2>/dev/null
}

# rf_secret_set <id> <account> <label> <password>
# secret-tool keeps all of stdin, a trailing newline too, so printf and not
# a here-string. printf is a builtin: the password shows in no process list.
rf_secret_set() {
	rf_have secret-tool || return 1
	printf '%s' "$4" | secret-tool store --label="rdfeed: $3" service rdfeed workspace "$1" user "$2" \
		> /dev/null 2>&1
}

rf_secret_clear() {
	rf_have secret-tool || return 0
	secret-tool clear service rdfeed workspace "$1" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Finding the feed
# ---------------------------------------------------------------------------

# rf_discover <domain>
# Windows finds the feed for a work e-mail address in a TXT record of the
# domain, _msradc.<domain>. Whichever DNS tool is around asks for it.
rf_discover() {
	local name="_msradc.$1" txt=''
	rf_have resolvectl && txt="$(resolvectl query --legend=no -t TXT "$name" 2>/dev/null)"
	[[ -z $txt ]] && rf_have dig && txt="$(dig +short TXT "$name" 2>/dev/null)"
	[[ -z $txt ]] && rf_have host && txt="$(host -t TXT "$name" 2>/dev/null)"
	[[ -z $txt ]] && rf_have drill && txt="$(drill TXT "$name" 2>/dev/null)"
	[[ $txt =~ (https?://[^\"[:space:]]+) ]] || return 1
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# rf_feed_url <what was typed>
# A server name, an address or a work e-mail address, as the address of the
# feed, in RF_URL. 1: nothing typed, 2: no feed found for the e-mail address.
RF_URL=''

rf_feed_url() {
	local in="$1" scheme rest host path
	in="${in#"${in%%[![:space:]]*}"}"
	in="${in%"${in##*[![:space:]]}"}"
	RF_URL=''
	[[ -n $in ]] || return 1

	if [[ $in != */* && $in == *@* ]]; then
		RF_URL="$(rf_discover "${in#*@}")" || return 2
		return 0
	fi

	[[ $in == *://* ]] || in="https://$in"
	scheme="${in%%://*}"
	rest="${in#*://}"
	host="${rest%%/*}"
	path="${rest#"$host"}"
	# The feed sits at the same place on every server. Whatever part of it
	# was typed, the RD Web page included, leads there.
	case "${path,,}" in
		''|/|/rdweb|/rdweb/|/rdweb/feed|/rdweb/feed/|/rdweb/pages*) path=/RDWeb/Feed/webfeed.aspx ;;
		*/webfeed) path+=.aspx ;;
	esac
	RF_URL="${scheme,,}://$host$path"
}

# rf_ws_id_for <url>
# The workspace that has this address, or a new id made from the server name.
rf_ws_id_for() {
	local url="$1" id base n=2 host
	rf_ws_ids
	for id in "${RF_WS_IDS[@]}"; do
		_rf_kv_lookup "$(rf_ws_file "$id")" Url
		[[ ${RF_KV_VALUE,,} == "${url,,}" ]] && { printf '%s\n' "$id"; return; }
	done
	host="${url#*://}"
	host="${host%%/*}"
	host="${host%%:*}"
	base="${host,,}"
	base="${base//[^a-z0-9]/-}"
	while [[ $base == *--* ]]; do base="${base//--/-}"; done
	base="${base#-}"
	base="${base%-}"
	[[ -n $base ]] || base=workspace
	id="$base"
	while [[ -e $(rf_ws_file "$id") ]]; do
		id="$base-$n"
		n=$(( n + 1 ))
	done
	printf '%s\n' "$id"
}

# rf_split_user <typed>
# DOMAIN\name, name@domain or just a name, into RF_USER and RF_DOMAIN. The
# domain is "-" when the server's own should be taken, and empty for
# name@domain, which carries its domain.
rf_split_user() {
	local in="$1"
	if [[ $in == *\\* ]]; then
		RF_DOMAIN="${in%%\\*}"
		RF_USER="${in#*\\}"
	elif [[ $in == *@* ]]; then
		RF_DOMAIN=''
		RF_USER="$in"
	else
		RF_DOMAIN='-'
		RF_USER="$in"
	fi
}

# ---------------------------------------------------------------------------
# Downloading
# ---------------------------------------------------------------------------

# rf_fetch <url> <user> <domain or -> <dir> <password> [quiet]
# Runs rdfeed-fetch into <dir>, printing each app as it arrives unless quiet.
# Leaves RF_FETCH_NAME, RF_FETCH_DOMAIN, RF_FETCH_COUNT and, when it failed,
# RF_FETCH_ERROR (the reason, already translated).
rf_fetch() {
	local url="$1" user="$2" domain="$3" out="$4" password="$5" quiet="${6:-}"
	local kind a b c rc=1 detail
	local -a args=(--url "$url" --user "$user" --out "$out")
	[[ $domain != - ]] && args+=(--domain "$domain")

	RF_FETCH_NAME='' RF_FETCH_DOMAIN='' RF_FETCH_COUNT=0 RF_FETCH_ERROR=''
	while IFS=$'\t' read -r kind a b c; do
		case "$kind" in
			workspace) RF_FETCH_NAME="$a" ;;
			domain)    RF_FETCH_DOMAIN="$a" ;;
			app)
				RF_FETCH_COUNT=$(( RF_FETCH_COUNT + 1 ))
				[[ -z $quiet ]] && printf '  %s✔%s %s\n' "$RF_C_GREEN" "$RF_C_RESET" "$c"
				;;
			skip)
				[[ -z $quiet ]] && printf '  %s✘%s %s %s(%s)%s\n' "$RF_C_RED" "$RF_C_RESET" "$a" "$RF_C_DIM" "$b" "$RF_C_RESET"
				;;
			exit) rc="$a" ;;
		esac
	done < <("$RF_FETCH" "${args[@]}" <<< "$password" 2> "$out/.error"; printf 'exit\t%s\n' "$?")

	(( rc == 0 )) && { rm -f "$out/.error"; return 0; }
	detail="$(tail -n1 "$out/.error" 2>/dev/null)"
	detail="${detail#rdfeed-fetch: }"
	case "$rc" in
		10) RF_FETCH_ERROR="$(rf_msg "The server did not accept the user name or password.")" ;;
		11) RF_FETCH_ERROR="$(rf_msg "Could not reach the server: %s" "$detail")" ;;
		12) RF_FETCH_ERROR="$(rf_msg "There is no RD Web feed at %s." "$url")" ;;
		*)  RF_FETCH_ERROR="$(rf_msg "Could not load the apps: %s" "${detail:-$rc}")" ;;
	esac
	return "$rc"
}

# rf_stage_dir
# A fresh directory next to the workspaces, so moving it in place is a rename.
rf_stage_dir() {
	mkdir -p "$RF_DATADIR" && mktemp -d "$RF_DATADIR/.new.XXXXXX"
}

# rf_ws_install <id> <stage dir>
rf_ws_install() {
	local dir="$RF_DATADIR/$1"
	rm -f "$2/.error"
	rm -rf "$dir.old"
	[[ -d $dir ]] && mv "$dir" "$dir.old"
	mv "$2" "$dir" || { [[ -d $dir.old ]] && mv "$dir.old" "$dir"; return 1; }
	rm -rf "$dir.old"
	rf_ws_entries "$1"
}

# rf_ws_apps_load <id>
# The apps of a workspace in RF_APP_SLUGS, RF_APP_TYPES, RF_APP_TITLES and
# RF_APP_EXTS (the file types it opens, as "docx doc rtf").
RF_APP_SLUGS=() RF_APP_TYPES=() RF_APP_TITLES=() RF_APP_EXTS=()

rf_ws_apps_load() {
	local slug type title exts file="$RF_DATADIR/$1/apps.tsv"
	RF_APP_SLUGS=() RF_APP_TYPES=() RF_APP_TITLES=() RF_APP_EXTS=()
	[[ -r $file ]] || return 0
	while IFS=$'\t' read -r slug type title exts; do
		[[ -n $slug ]] || continue
		RF_APP_SLUGS+=("$slug") RF_APP_TYPES+=("$type") RF_APP_TITLES+=("$title") RF_APP_EXTS+=("$exts")
	done < "$file"
}

# ---------------------------------------------------------------------------
# The app menu
# ---------------------------------------------------------------------------

_rf_desktop_value() {
	local v="${1//\\/\\\\}"
	v="${v//$'\n'/ }"
	printf '%s' "${v//$'\r'/}"
}

# The command, as the Exec line of an entry wants it.
_rf_exec_path() {
	if [[ $RF_SELF =~ ^[A-Za-z0-9_./+-]+$ ]]; then
		printf '%s' "$RF_SELF"
	else
		local p="${RF_SELF//\\/\\\\\\\\}"
		p="${p//\"/\\\\\"}"
		p="${p//\$/\\\\\$}"
		p="${p//\`/\\\\\`}"
		printf '"%s"' "$p"
	fi
}

# _rf_mime_types <ext>...
# The MIME types of the file extensions, as a MimeType= value, from the
# shared-mime-info database every desktop uses.
_rf_mime_types() {
	local f
	local -a globs=()
	for f in "$RF_XDG_DATA/mime/globs2" /usr/local/share/mime/globs2 /usr/share/mime/globs2; do
		[[ -r $f ]] && globs+=("$f")
	done
	(( ${#globs[@]} )) || return 0
	awk -F: -v want=" $* " '
		BEGIN { want = tolower(want) }
		/^#/ { next }
		{
			glob = tolower($3)
			if (glob !~ /^\*\.[a-z0-9_+-]+$/) next
			if (index(want, " " substr(glob, 3) " ") && !seen[$2]++) out = out $2 ";"
		}
		END { printf "%s", out }
	' "${globs[@]}"
}

# rf_menu_refresh
# KDE reads the app menu from a cache, which needs a nudge. GNOME and the rest
# watch the folders themselves.
rf_menu_refresh() {
	if rf_have kbuildsycoca6; then
		kbuildsycoca6 > /dev/null 2>&1 || true
	elif rf_have kbuildsycoca5; then
		kbuildsycoca5 > /dev/null 2>&1 || true
	fi
	rf_have update-desktop-database && update-desktop-database "$RF_APPDIR" > /dev/null 2>&1
	return 0
}

# rf_ws_entries <id>
# An entry for each app, a folder for the workspace, and nothing left of apps
# the feed no longer has.
rf_ws_entries() {
	local id="$1" i slug title icon comment file keywords mime openwith=no args
	local -A keep=()

	rf_ws_load "$id"
	rf_ws_apps_load "$id"
	mkdir -p "$RF_APPDIR" "$RF_MENUDIR" "$RF_DIRDIR" || return 1
	_rf_kv_lookup "$RF_CONFIG" OpenWith yes
	rf_is_true "$RF_KV_VALUE" && openwith=yes

	keywords="$(_rf_desktop_value "$WS_NAME")"
	keywords="${keywords//;/\\;}"
	for i in "${!RF_APP_SLUGS[@]}"; do
		slug="${RF_APP_SLUGS[i]}"
		title="${RF_APP_TITLES[i]}"
		icon="$RF_DATADIR/$id/icons/$slug.png"
		[[ -f $icon ]] || icon=rdfeed
		if [[ ${RF_APP_TYPES[i]} == Desktop ]]; then
			comment="$(rf_msg "Remote desktop of %s" "$WS_NAME")"
		else
			comment="$(rf_msg "%s from %s" "$title" "$WS_NAME")"
		fi
		mime='' args=''
		if [[ $openwith == yes && -n ${RF_APP_EXTS[i]} ]]; then
			# shellcheck disable=SC2086  # one extension per argument
			mime="$(_rf_mime_types ${RF_APP_EXTS[i]})"
			[[ -n $mime ]] && args=' %f'
		fi
		file="$RF_APPDIR/rdfeed-$id--$slug.desktop"
		keep[$file]=1
		cat > "$file" <<- EOF
		[Desktop Entry]
		Type=Application
		Name=$(_rf_desktop_value "$title")
		GenericName=$(_rf_desktop_value "$WS_NAME")
		Comment=$(_rf_desktop_value "$comment")
		Exec=$(_rf_exec_path) run $id/$slug$args
		Icon=$icon
		Terminal=false
		StartupNotify=false
		Categories=X-rdfeed-$id;
		Keywords=RemoteApp;RDP;$keywords;
		EOF
		[[ -n $mime ]] && printf 'MimeType=%s\n' "$mime" >> "$file"
	done

	for file in "$RF_APPDIR"/rdfeed-"$id"--*.desktop; do
		[[ -e $file && -z ${keep[$file]:-} ]] && rm -f "$file"
	done

	cat > "$RF_MENUDIR/rdfeed-$id.menu" <<- EOF
	<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
	    "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
	<!-- Written by rdfeed: the folder of the workspace $id. -->
	<Menu>
	    <Name>Applications</Name>
	    <Menu>
	        <Name>rdfeed-$id</Name>
	        <Directory>rdfeed-$id.directory</Directory>
	        <Include>
	            <Category>X-rdfeed-$id</Category>
	        </Include>
	    </Menu>
	</Menu>
	EOF

	cat > "$RF_DIRDIR/rdfeed-$id.directory" <<- EOF
	[Desktop Entry]
	Type=Directory
	Name=$(_rf_desktop_value "$WS_NAME")
	Icon=rdfeed
	EOF

	rf_menu_refresh
}

# rf_ws_entries_all
# The entries of every workspace again, after a setting that shows in them.
rf_ws_entries_all() {
	local id
	rf_ws_ids
	for id in "${RF_WS_IDS[@]}"; do
		rf_ws_entries "$id"
	done
}

# rf_ws_purge <id>
# Everything of a workspace: entries, folder, apps, settings, password, logs.
rf_ws_purge() {
	local id="$1" file
	for file in "$RF_APPDIR"/rdfeed-"$id"--*.desktop; do
		[[ -e $file ]] && rm -f "$file"
	done
	rm -f "$RF_MENUDIR/rdfeed-$id.menu" "$RF_DIRDIR/rdfeed-$id.directory"
	rm -rf "${RF_DATADIR:?}/$id"
	rm -f "$(rf_ws_file "$id")"
	for file in "$RF_CACHEDIR/$id"--*.log; do
		[[ -e $file ]] && rm -f "$file"
	done
	rf_secret_clear "$id"
	rf_menu_refresh
}

# ---------------------------------------------------------------------------
# Refreshing every day
# ---------------------------------------------------------------------------

rf_timer_available() {
	rf_have systemctl || return 1
	systemctl --user cat "$RF_UNIT_TIMER" > /dev/null 2>&1
}

rf_timer_enabled() {
	rf_have systemctl || return 1
	[[ $(systemctl --user is-enabled "$RF_UNIT_TIMER" 2>/dev/null) == enabled ]]
}

# rf_timer_set yes|no
rf_timer_set() {
	rf_timer_available || return 1
	if [[ $1 == yes ]]; then
		systemctl --user enable --now "$RF_UNIT_TIMER" > /dev/null 2>&1
	else
		systemctl --user disable --now "$RF_UNIT_TIMER" > /dev/null 2>&1
	fi
}
