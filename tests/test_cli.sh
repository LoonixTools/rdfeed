#!/usr/bin/env bash
#
# The rdfeed command from start to end, against tests/fake_rdweb.py: add a
# workspace, list, refresh, start an app, remove it again.
#
# Everything happens in a temporary home. secret-tool, systemctl, notify-send,
# kbuildsycoca6 and xfreerdp3 are fakes on PATH, so the real keyring, timers,
# notifications and app menu stay untouched.
#
# Copyright (C) 2026 Felitendo
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
server=''
trap '[[ -n $server ]] && kill "$server" 2>/dev/null; rm -rf -- "$tmp"' EXIT
failed=0

export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache"
export RF_LIBDIR="$root/src/lib" RF_FETCH="$root/src/fetch/rdfeed-fetch" RF_LOCALEDIR="$tmp/locale"
RF_HOOK="$(readlink -f "${RDFEED_HOOK:-$root/build/rdfeed-hook.so}")"
export RF_HOOK
export LANG=C LC_ALL=C NO_COLOR=1 XDG_CURRENT_DESKTOP=test XDG_RUNTIME_DIR="$tmp/run"
mkdir -p "$HOME" "$tmp/bin"

# The fakes. Each writes what it was asked into $tmp, as a log or a file.
cat > "$tmp/bin/secret-tool" <<- 'EOF'
#!/usr/bin/env bash
store="${0%/bin/*}/secrets"; mkdir -p "$store"
cmd="$1"; shift; ws=''
while (( $# )); do [[ $1 == workspace ]] && ws="$2"; shift; done
case "$cmd" in
	store)  cat > "$store/$ws" ;;
	lookup) [[ -f $store/$ws ]] && cat "$store/$ws" ;;
	clear)  rm -f "$store/$ws" ;;
esac
EOF
cat > "$tmp/bin/xfreerdp3" <<- 'EOF'
#!/usr/bin/env bash
out="${0%/bin/*}"
cat > "$out/freerdp-args"
cp "$(head -n1 "$out/freerdp-args")" "$out/freerdp-rdp"
env > "$out/freerdp-env"
echo "[INFO] connected"
echo "[rdfeed] gateway-delay 12" >&2
exit "${FAKE_FREERDP_EXIT:-0}"
EOF
for fake in systemctl notify-send kbuildsycoca6 update-desktop-database; do
	# shellcheck disable=SC2016  # the script expands when it runs, not here
	printf '#!/usr/bin/env bash\necho "%s $*" >> "${0%%/bin/*}/calls"\n[[ $1 == --user && $2 == cat ]] && exit 1\nexit 0\n' "$fake" > "$tmp/bin/$fake"
done
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"

rdfeed() { bash "$root/src/rdfeed" "$@"; }

check() {
	if eval "$2"; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n' "$1"
		failed=1
	fi
}

# The URL helpers, on their own.
url_helpers() (
	source "$RF_LIBDIR/common.sh"; source "$RF_LIBDIR/config.sh"; source "$RF_LIBDIR/workspace.sh"
	for pair in "rdweb.contoso.com|https://rdweb.contoso.com/RDWeb/Feed/webfeed.aspx" \
	            "office.contoso.com/rdweb/feed/webfeed|https://office.contoso.com/rdweb/feed/webfeed.aspx" \
	            "https://x.test/RDWeb/Pages/en-US/Default.aspx|https://x.test/RDWeb/Feed/webfeed.aspx" \
	            "HTTPS://x.test:8443/RDWeb/|https://x.test:8443/RDWeb/Feed/webfeed.aspx" \
	            "https://x.test/custom/feed.aspx|https://x.test/custom/feed.aspx"; do
		rf_feed_url "${pair%%|*}"
		[[ $RF_URL == "${pair#*|}" ]] || { echo "  $RF_URL != ${pair#*|}"; exit 1; }
	done
	rf_split_user 'CONTOSO\jdoe'; [[ $RF_USER == jdoe && $RF_DOMAIN == CONTOSO ]] || exit 1
	rf_split_user 'jdoe@contoso.com'; [[ $RF_USER == jdoe@contoso.com && -z $RF_DOMAIN ]] || exit 1
	rf_split_user 'jdoe'; [[ $RF_USER == jdoe && $RF_DOMAIN == - ]] || exit 1
	[[ $(rf_ws_id_for "https://Office.Contoso.COM/RDWeb/Feed/webfeed.aspx") == office-contoso-com ]] || exit 1
)
if url_helpers; then check "addresses, user names and ids" true; else check "addresses, user names and ids" false; fi

python3 "$root/tests/fake_rdweb.py" > "$tmp/url" &
server=$!
for _ in $(seq 50); do [[ -s $tmp/url ]] && break; sleep 0.1; done
url="$(< "$tmp/url")"
id=127-0-0-1
password="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fake_rdweb; print(fake_rdweb.PASSWORD)' "$root/tests")"

out="$(printf 'CONTOSO\\jdoe\nwrong\n' | rdfeed add "$url" 2>&1)"
rc=$?
check "a wrong password is refused" "[[ \$rc -ne 0 ]] && grep -q 'did not accept' <<< \"\$out\""
check "and leaves nothing behind" "[[ ! -e $XDG_CONFIG_HOME/rdfeed/workspaces/$id ]]"

out="$(printf 'jdoe\n%s\n' "$password" | rdfeed add "${url%/RDWeb/*}" 2>&1)"
check "add signs in and loads the apps" "grep -q '4 apps from Contoso Apps are now in your app menu' <<< \"\$out\""
ws="$XDG_CONFIG_HOME/rdfeed/workspaces/$id"
check "the workspace remembers the server's domain" "grep -qx 'Domain=CONTOSO' '$ws' && grep -qx 'User=jdoe' '$ws'"
check "the password is in the keyring, as typed" "[[ \$(< '$tmp/secrets/$id') == \"\$password\" ]]"
entry="$XDG_DATA_HOME/applications/rdfeed-$id--powerpnt.desktop"
check "each app has a menu entry" "[[ \$(ls '$XDG_DATA_HOME/applications' | wc -l) -eq 4 ]]"
check "which starts it" "grep -q 'Exec=$root/src/rdfeed run $id/powerpnt' '$entry'"
check "with its own icon" "grep -qx 'Icon=$XDG_DATA_HOME/rdfeed/$id/icons/powerpnt.png' '$entry'"
word="$XDG_DATA_HOME/applications/rdfeed-$id--winword.desktop"
if [[ -r /usr/share/mime/globs2 ]]; then
	check "Word is offered for .docx files" "grep -q '^MimeType=.*application/vnd.openxmlformats-officedocument.wordprocessingml.document;' '$word' && grep -q 'run $id/winword %f\$' '$word'"
	check "Excel for the types of the feed" "grep -qx 'MimeType=.*text/csv;.*' '$XDG_DATA_HOME/applications/rdfeed-$id--excel.desktop' || grep -q 'MimeType=.*csv' '$XDG_DATA_HOME/applications/rdfeed-$id--excel.desktop'"
fi
check "the desktop for none" "! grep -q MimeType '$XDG_DATA_HOME/applications/rdfeed-$id--desktop.desktop'"
if command -v desktop-file-validate > /dev/null; then
	check "the entries are valid" "desktop-file-validate --no-hints '$XDG_DATA_HOME'/applications/*.desktop"
fi
check "the workspace has a folder" "grep -q '<Category>X-rdfeed-$id</Category>' '$XDG_CONFIG_HOME/menus/applications-merged/rdfeed-$id.menu' && grep -qx 'Name=Contoso Apps' '$XDG_DATA_HOME/desktop-directories/rdfeed-$id.directory'"

out="$(rdfeed list 2>&1)"
check "list shows the apps" "grep -q '$id/powerpnt *PowerPoint' <<< \"\$out\""

out="$(rdfeed refresh < /dev/null 2>&1)"
check "refresh takes the password from the keyring" "grep -q 'Contoso Apps: 4 apps' <<< \"\$out\""

rdfeed run powerpnt > /dev/null 2>&1
check "run hands FreeRDP the .rdp file first" "[[ \$(head -n1 '$tmp/freerdp-args') == '$XDG_DATA_HOME/rdfeed/$id/rdp/powerpnt.rdp' ]]"
check "with the user, domain and password" "grep -qx '/u:jdoe' '$tmp/freerdp-args' && grep -qx '/d:CONTOSO' '$tmp/freerdp-args' && grep -qxF \"/p:\$password\" '$tmp/freerdp-args'"
check "and the hook, with GFX left on" "grep -qx 'LD_PRELOAD=$RF_HOOK' '$tmp/freerdp-env' && ! grep -q 'RDFEED_NO_GFX' '$tmp/freerdp-env'"
check "the log has what FreeRDP said" "grep -q 'gateway-delay 12' '$XDG_CACHE_HOME/rdfeed/$id--powerpnt.log'"
check "a notification says a second prompt comes" "grep -q 'notify-send .*A second sign-in is coming' '$tmp/calls'"

mkdir -p "$HOME/Downloads" "$HOME/Documents/Reports"
: > "$HOME/Downloads/Report, final.docx"
rdfeed run "$id/winword" "$HOME/Downloads/Report, final.docx" > /dev/null 2>&1
check "a file opens through its shared folder" "grep -qxF 'remoteapplicationcmdline:s:\"\\\\tsclient\\Downloads\\Report, final.docx\"'\$'\\r' '$tmp/freerdp-rdp' && grep -qx '/drive:Downloads,$HOME/Downloads' '$tmp/freerdp-args'"
check "and its copy of the .rdp is gone after" "[[ -z \$(ls -A '$XDG_RUNTIME_DIR/rdfeed' 2>/dev/null) ]]"
check "and a notification names it" "grep -q 'notify-send .*Opening Report, final.docx in Word' '$tmp/calls'"

rdfeed run "$id/winword" "$HOME/nothing.docx" > /dev/null 2>&1
rc=$?
check "a missing file is refused" "[[ \$rc -ne 0 ]]"

# shellcheck disable=SC2016  # user-dirs.dirs wants $HOME as it is
printf 'XDG_DOCUMENTS_DIR="$HOME/Documents"\n' > "$XDG_CONFIG_HOME/user-dirs.dirs"
printf 'Share=documents\nGraphics=classic\nSound=no\nOpenWith=no\n' > "$XDG_CONFIG_HOME/rdfeed/config"
: > "$HOME/Documents/Reports/q3.xlsx"
rdfeed run "$id/excel" "$HOME/Documents/Reports/q3.xlsx" > /dev/null 2>&1
check "a file in the shared folder needs no drive of its own" "grep -qF 'tsclient\\Documents\\Reports\\q3.xlsx' '$tmp/freerdp-rdp' && [[ \$(grep -c '^/drive:' '$tmp/freerdp-args') -eq 1 ]]"
check "the settings reach FreeRDP" "grep -qx 'RDFEED_NO_GFX=1' '$tmp/freerdp-env' && ! grep -qx '/sound' '$tmp/freerdp-args'"

rdfeed refresh < /dev/null > /dev/null 2>&1
check "with Open with off the entries name no file types" "! grep -q MimeType '$word' && grep -q 'run $id/winword\$' '$word'"

FAKE_FREERDP_EXIT=131 rdfeed run "$id/powerpnt" > /dev/null 2>&1
rc=$?
check "a failed start says so" "[[ \$rc -ne 0 ]] && grep -q 'notify-send .*PowerPoint could not start' '$tmp/calls'"

rdfeed run nothing > /dev/null 2>&1
rc=$?
check "an unknown app is refused" "[[ \$rc -ne 0 ]]"

rdfeed remove "$id" > /dev/null 2>&1
check "remove takes everything away" "[[ ! -e '$ws' && ! -e '$tmp/secrets/$id' && ! -d '$XDG_DATA_HOME/rdfeed/$id' ]] && ! ls '$XDG_DATA_HOME'/applications/rdfeed-* > /dev/null 2>&1"

exit "$failed"
