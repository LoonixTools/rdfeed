# shellcheck shell=bash
#
# Starting an app.
#
# Each app runs in xfreerdp in RemoteApp mode: only its own windows show, not
# a whole Windows desktop. The arguments, the password among them, go to
# FreeRDP on stdin (/args-from:stdin), never on its command line.
#
# A file from this computer (an "Open with", or `rdfeed run APP FILE`) gets
# there the way Windows does it: its folder is shared as a drive, and the app
# is started with the path on that drive, \\tsclient\<folder>\<file>.
#
# rdfeed-hook.so goes into FreeRDP with LD_PRELOAD. It waits before the second
# gateway sign-in so a second MFA prompt is sent, and keeps the graphics
# pipeline off, which leaves windows unpainted in RemoteApp mode. See
# src/hook/rdfeed-hook.c.

# How long the hook waits before the second sign-in, in seconds.
RF_GW_DELAY=12

# rf_freerdp
# The FreeRDP 3 client that can show RemoteApps (the X11 one), in RF_FREERDP.
# Arch and Debian call it xfreerdp3, Fedora xfreerdp.
RF_FREERDP=''

rf_freerdp() {
	RF_FREERDP=''
	if rf_have xfreerdp3; then
		RF_FREERDP=xfreerdp3
	elif rf_have xfreerdp && [[ $(xfreerdp /version 2>/dev/null) == *" 3."* ]]; then
		RF_FREERDP=xfreerdp
	fi
	[[ -n $RF_FREERDP ]]
}

# rf_kbd_layout
# The Windows id of the keyboard layout in use. Under Wayland, X11 programs
# often see "us" whatever the real layout is, so it is asked of the desktop.
rf_kbd_layout() {
	local layout=''
	if [[ -r $RF_XDG_CONFIG/kxkbrc ]]; then
		layout="$(sed -n 's/^LayoutList=//p' "$RF_XDG_CONFIG/kxkbrc" | head -n1)"
	fi
	if [[ -z $layout && ${XDG_CURRENT_DESKTOP:-} == *GNOME* ]] && rf_have gsettings; then
		layout="$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null \
			| sed -n "s/^[^']*'xkb', '\([a-z]*\).*/\1/p")"
	fi
	if [[ -z $layout ]] && rf_have localectl; then
		layout="$(localectl status 2>/dev/null | sed -n 's/.*X11 Layout: *//p')"
	fi
	[[ -z $layout ]] && layout="${XKB_DEFAULT_LAYOUT:-}"
	layout="${layout%%,*}"
	case "${layout,,}" in
		de|at) printf '0x00000407\n' ;;
		ch)    printf '0x00000807\n' ;;
		us)    printf '0x00000409\n' ;;
		gb|uk) printf '0x00000809\n' ;;
		fr)    printf '0x0000040C\n' ;;
		be)    printf '0x0000080C\n' ;;
		es)    printf '0x0000040A\n' ;;
		it)    printf '0x00000410\n' ;;
		nl)    printf '0x00000413\n' ;;
		pl)    printf '0x00000415\n' ;;
		pt)    printf '0x00000816\n' ;;
		br)    printf '0x00000416\n' ;;
		ru)    printf '0x00000419\n' ;;
		ua)    printf '0x00000422\n' ;;
		tr)    printf '0x0000041F\n' ;;
		jp)    printf '0x00000411\n' ;;
		kr)    printf '0x00000412\n' ;;
		se)    printf '0x0000041D\n' ;;
		no)    printf '0x00000414\n' ;;
		dk)    printf '0x00000406\n' ;;
		fi)    printf '0x0000040B\n' ;;
		cz)    printf '0x00000405\n' ;;
		sk)    printf '0x0000041B\n' ;;
		hu)    printf '0x0000040E\n' ;;
		*)     return 1 ;;
	esac
}

# rf_auto_scale
# How much the desktop scales X11 programs that scale themselves, in percent,
# in RF_AUTO_SCALE. The apps are then drawn that much bigger on the server, so
# they come out sharp and the right size.
RF_AUTO_SCALE=100

rf_auto_scale() {
	local s dpi
	RF_AUTO_SCALE=100
	s="$(awk -F= '/^\[/ { section = $0 } section == "[Xwayland]" && $1 == "Scale" { print $2 }' \
		"$RF_XDG_CONFIG/kwinrc" 2>/dev/null | tail -n1)"
	if [[ $s =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		RF_AUTO_SCALE="$(awk -v s="$s" 'BEGIN { printf "%d", s * 100 + 0.5 }')"
	elif rf_have xrdb; then
		dpi="$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ { print $2 }')"
		[[ $dpi =~ ^[0-9]+$ ]] && RF_AUTO_SCALE=$(( (dpi * 100 + 48) / 96 ))
	fi
	[[ $RF_AUTO_SCALE -lt 100 ]] && RF_AUTO_SCALE=100
	[[ $RF_AUTO_SCALE -gt 500 ]] && RF_AUTO_SCALE=500
	return 0
}

# rf_share_dir
# The folder the apps may see, from the Share setting. Nothing for off.
rf_share_dir() {
	local dir=''
	case "$CFG_SHARE" in
		home)      dir="$HOME" ;;
		documents) rf_have xdg-user-dir && dir="$(xdg-user-dir DOCUMENTS)" ;;
		downloads) rf_have xdg-user-dir && dir="$(xdg-user-dir DOWNLOAD)" ;;
	esac
	# xdg-user-dir answers with the home folder for a folder that is not set
	# up. Sharing all of it then would be a surprise.
	[[ $CFG_SHARE != home && ${dir%/} == "${HOME%/}" ]] && return 1
	[[ -n $dir && -d $dir ]] || return 1
	printf '%s\n' "$dir"
}

# _rf_drive_name <dir>
# A name for a shared folder, as the app shows it: the folder's own name,
# without what Windows does not allow in one.
_rf_drive_name() {
	local name="${1%/}"
	name="${name##*/}"
	name="${name//[\\\/:*?\"<>|,;]/_}"
	printf '%s\n' "${name:-Linux}"
}

# _rf_drive_path <dir>
# The folder as FreeRDP can take it. /drive splits at commas, so a folder with
# one in its path is shared through a link that has none.
_rf_drive_path() {
	local dir="$1" link
	if [[ $dir != *,* ]]; then
		printf '%s\n' "$dir"
		return
	fi
	link="$RF_RUNDIR/links/$(_rf_drive_name "$dir")"
	link="${link//,/_}"
	mkdir -p "${link%/*}" && ln -sfn "$dir" "$link" && printf '%s\n' "$link"
}

# rf_ask_password <account>
# For when the keyring has none: in the terminal if there is one, else in a
# small window.
rf_ask_password() {
	local prompt password
	prompt="$(rf_msg "Password for %s:" "$1")"
	if [[ -t 0 ]]; then
		IFS= read -rsp "  $prompt " password || return 1
		printf '\n' >&2
	elif rf_have kdialog; then
		password="$(kdialog --title "$RF_PRETTY" --password "$prompt" 2>/dev/null)" || return 1
	elif rf_have zenity; then
		password="$(zenity --password --title "$prompt" 2>/dev/null)" || return 1
	else
		return 1
	fi
	[[ -n $password ]] || return 1
	printf '%s' "$password"
}

# rf_launch_error <log>
# Why FreeRDP gave up, in words, from what it logged.
rf_launch_error() {
	local log="$1" last
	if grep -qE 'ERRCONNECT_(PASSWORD_EXPIRED|PASSWORD_MUST_CHANGE|PASSWORD_CERTAINLY_EXPIRED)' "$log"; then
		rf_msg "Your password has expired. Change it on Windows or on the RD Web page, then sign in again in rdfeed."
	elif grep -qE 'ERRCONNECT_ACCOUNT_LOCKED_OUT' "$log"; then
		rf_msg "Your account is locked. Ask your IT department."
	elif grep -qE 'ERRCONNECT_(LOGON_FAILURE|WRONG_PASSWORD|AUTHENTICATION_FAILED)|STATUS_LOGON_FAILURE' "$log"; then
		rf_msg "The server did not accept the password. Sign in again in rdfeed."
	elif grep -qE 'ERRCONNECT_(DNS_NAME_NOT_FOUND|DNS_ERROR|CONNECT_FAILED|CONNECT_TRANSPORT_FAILED)' "$log"; then
		rf_msg "Could not reach the server. Check the internet connection."
	else
		last="$(grep '\[ERROR\]' "$log" | tail -n1 | sed 's/^.*\] - \[[^]]*\]: *//')"
		rf_msg "FreeRDP stopped: %s" "${last:-?}"
	fi
}

# rf_launch <id> <app> [file]
rf_launch() {
	local id="$1" slug="$2" file="${3:-}" i title='' type='' icon rdp password log rcfile rc line kbd share
	local drive='' remote='' temprdp='' dir name rel
	local -a args env

	rf_ws_load "$id"
	rf_ws_apps_load "$id"
	for i in "${!RF_APP_SLUGS[@]}"; do
		if [[ ${RF_APP_SLUGS[i]} == "$slug" ]]; then
			title="${RF_APP_TITLES[i]}" type="${RF_APP_TYPES[i]}"
		fi
	done
	rdp="$RF_DATADIR/$id/rdp/$slug.rdp"
	icon="$RF_DATADIR/$id/icons/$slug.png"
	[[ -f $icon ]] || icon=rdfeed
	if [[ -z $title || ! -f $rdp ]]; then
		rf_bad "$(rf_msg "There is no app %s. See \`%s list\`." "$id/$slug" "$RF_NAME")"
		return 1
	fi

	if [[ -n $file ]]; then
		file="$(realpath -e -- "$file" 2>/dev/null)" && [[ -f $file ]] || {
			rf_bad "$(rf_msg "File not found: %s" "${3:-}")"
			rf_notify "$title" "$(rf_msg "File not found: %s" "${3:-}")" dialog-error
			return 1
		}
	fi

	if ! rf_freerdp; then
		rf_bad "$(rf_msg "FreeRDP 3 is missing. Install it to start the apps (the package is called freerdp).")"
		rf_notify "$title" "$(rf_msg "FreeRDP 3 is missing. Install it to start the apps (the package is called freerdp).")" dialog-error
		return 1
	fi

	password="$(rf_secret_get "$id" "$WS_ACCOUNT")" || password=''
	if [[ -z $password ]]; then
		password="$(rf_ask_password "$WS_ACCOUNT")" || {
			rf_notify "$title" "$(rf_msg "No password saved for %s. Sign in again in rdfeed." "$WS_NAME")" dialog-error
			return 1
		}
	fi

	rf_config_load
	args=("$rdp" "/u:$WS_USER")
	[[ -n $WS_DOMAIN && $WS_USER != *@* ]] && args+=("/d:$WS_DOMAIN")
	args+=("/p:$password" /cert:tofu +clipboard)
	kbd="$(rf_kbd_layout)" && args+=("/kbd:layout:$kbd")
	[[ $CFG_SOUND == yes ]] && args+=(/sound)
	if [[ $CFG_SCALE == auto ]]; then
		rf_auto_scale
	else
		RF_AUTO_SCALE="$CFG_SCALE"
	fi
	[[ $RF_AUTO_SCALE -gt 100 ]] && args+=("/scale-desktop:$RF_AUTO_SCALE")
	if share="$(rf_share_dir)"; then
		name="$(_rf_drive_name "$share")"
		args+=("/drive:$name,$(_rf_drive_path "$share")")
		# A file in the shared folder needs no drive of its own.
		if [[ -n $file && $file == "${share%/}"/* ]]; then
			drive="$name"
			rel="${file#"${share%/}"/}"
			remote="\\\\tsclient\\$name\\${rel//\//\\}"
		fi
	fi
	if [[ -n $file && -z $remote ]]; then
		dir="${file%/*}"
		drive="$(_rf_drive_name "$dir")"
		args+=("/drive:$drive,$(_rf_drive_path "${dir:-/}")")
		remote="\\\\tsclient\\$drive\\${file##*/}"
	fi
	if [[ -n $remote ]]; then
		# The app gets the file as its command line, in a copy of the .rdp.
		mkdir -p "$RF_RUNDIR"
		temprdp="$(mktemp "$RF_RUNDIR/$id--$slug.XXXXXX.rdp")"
		RF_CMDLINE="\"$remote\"" awk '
			BEGIN { line = "remoteapplicationcmdline:s:" ENVIRON["RF_CMDLINE"] }
			tolower($0) ~ /^remoteapplicationcmdline:s:/ { if (!done) print line "\r"; done = 1; next }
			{ print }
			END { if (!done) print line "\r" }
		' "$rdp" > "$temprdp"
		args[0]="$temprdp"
	fi
	[[ $type == Desktop ]] && args+=(/dynamic-resolution)

	env=(WLOG_LEVEL="${WLOG_LEVEL:-INFO}" RDFEED_GW_WAIT="$CFG_MFAWAIT" RDFEED_GW_DELAY="$RF_GW_DELAY")
	[[ $CFG_GRAPHICS == gfx ]] || env+=(RDFEED_NO_GFX=1)
	[[ -f $RF_HOOK ]] && env+=(LD_PRELOAD="$RF_HOOK${LD_PRELOAD:+:$LD_PRELOAD}")

	mkdir -p "$RF_CACHEDIR"
	log="$RF_CACHEDIR/$id--$slug.log"
	rcfile="$(mktemp "$RF_CACHEDIR/.exit.XXXXXX")"
	: > "$log"

	if [[ -n $file ]]; then
		rf_notify "$(rf_msg "Opening %s in %s" "${file##*/}" "$title")" \
			"$(rf_msg "If it does not open by itself, open it in the app from the drive %s." "$drive")" "$icon"
	else
		rf_notify "$(rf_msg "Starting %s" "$title")" \
			"$(rf_msg "If your company uses MFA, confirm the sign-in in your authenticator app.")" "$icon"
	fi

	{
		printf '%s\n' "${args[@]}" | env "${env[@]}" "$RF_FREERDP" /args-from:stdin 2>&1
		printf '%s\n' "${PIPESTATUS[1]}" > "$rcfile"
	} | while IFS= read -r line; do
		printf '%s\n' "$line" >> "$log"
		if [[ $line == "[rdfeed] gateway-delay"* ]]; then
			rf_notify "$(rf_msg "A second sign-in is coming")" \
				"$(rf_msg "Confirm the second prompt in your authenticator app too. It comes in about %d seconds." "$RF_GW_DELAY")" "$icon"
		fi
	done
	rc="$(< "$rcfile")"
	rm -f "$rcfile"
	[[ -n $temprdp ]] && rm -f "$temprdp"

	# Below 128 the session ended the normal way: closed, logged off, or taken
	# over by the next app of the same workspace.
	if [[ $rc =~ ^[0-9]+$ ]] && (( rc >= 128 )) && ! grep -q ERRCONNECT_CONNECT_CANCELLED "$log"; then
		rf_notify "$(rf_msg "%s could not start" "$title")" "$(rf_launch_error "$log")" dialog-error
		rf_bad "$(rf_launch_error "$log")"
		rf_note "$(rf_msg "Log: %s" "$log")"
		return 1
	fi
	return 0
}
