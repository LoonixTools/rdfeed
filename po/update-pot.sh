#!/usr/bin/env bash
#
# Collects every translatable string into po/rdfeed.pot and brings the
# translations up to date with it.
#
# The settings labels and headings live in an array in menu.sh and reach
# gettext at run time, so xgettext cannot see them; they are pulled out here
# first.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

version="$(make -s version)"

# The labels, as calls xgettext understands, pointing back at menu.sh.
awk -F'|' '/^\t"(user|entries|timer)\|/ { sub(/"$/, "", $5); print "rf_msg \"" $5 "\"" }
          /^\t"group\|/ { sub(/"$/, "", $2); print "rf_msg \"" $2 "\"" }' src/lib/menu.sh > "$tmp/settings.sh"

xgettext --from-code=UTF-8 --add-comments=TRANSLATORS --package-name=rdfeed --package-version="$version" \
	--msgid-bugs-address=https://github.com/LoonixTools/rdfeed/issues \
	-L Shell -k --keyword=rf_msg --keyword=rf_msg_into:2 --keyword=rf_msg_in:2 \
	-o po/rdfeed.pot src/rdfeed src/lib/*.sh "$tmp/settings.sh"
sed -i "s|$tmp/settings.sh:[0-9]*|src/lib/menu.sh|g" po/rdfeed.pot
sed -i -e '1i # Translation template for rdfeed.\n# Copyright (C) 2026 Felitendo\n# This file is distributed under the same license as rdfeed.' -e '1,4d' \
	po/rdfeed.pot

for po in po/*.po; do
	[[ -e $po ]] || continue
	msgmerge --quiet --update --backup=none --no-fuzzy-matching "$po" po/rdfeed.pot
done
echo "po/rdfeed.pot: $(grep -c '^msgid' po/rdfeed.pot) strings"
