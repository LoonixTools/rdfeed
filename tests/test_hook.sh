#!/usr/bin/env bash
#
# rdfeed-hook.so: the wait before a new gateway tunnel, and GFX kept off.
# Connections go to port 443 of this computer, nothing has to answer there.
#
# Copyright (C) 2026 Felitendo
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

hook="$(readlink -f "${RDFEED_HOOK:-build/rdfeed-hook.so}")"
[[ -f $hook ]] || { echo "no hook at $hook, run make first" >&2; exit 1; }
failed=0

check() {
	if [[ $2 == "$3" ]]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s: got "%s", want "%s"\n' "$1" "$2" "$3"
		failed=1
	fi
}

# timings <wait mode> <pause>
# One connection, the pause, then two right after each other. Prints how long
# each one waited, in whole seconds, and whether the hook said so.
timings() {
	LD_PRELOAD="$hook" RDFEED_GW_DELAY=1 RDFEED_GW_WAIT="$1" python3 - "$2" 2>&1 <<- 'EOF'
	import socket, sys, time
	def attempt():
	    start = time.monotonic()
	    s = socket.socket()
	    try:
	        s.connect(("127.0.0.1", 443))
	    except OSError:
	        pass
	    s.close()
	    return round(time.monotonic() - start)
	first = attempt()
	time.sleep(float(sys.argv[1]))
	second = attempt()
	third = attempt()
	print(first, second, third)
	EOF
}

check "auto waits after a long first sign-in" "$(timings auto 3 | tr '\n' ' ')" "[rdfeed] gateway-delay 1 0 1 0 "
check "auto does not wait after a quick one" "$(timings auto 2.1)" "0 0 0"
check "always waits" "$(timings always 2.1 | tail -n1)" "0 1 0"
check "never waits not" "$(timings never 3)" "0 0 0"
check "the same tunnel does not wait" "$(timings always 0.5)" "0 0 0"

# GFX: what FreeRDP's own command line parser makes of it, with and without.
gfx() {
	env "$@" python3 - <<- 'EOF'
	import ctypes
	try:
	    core = ctypes.CDLL("libfreerdp3.so.3", mode=ctypes.RTLD_GLOBAL)
	    client = ctypes.CDLL("libfreerdp-client3.so.3", mode=ctypes.RTLD_GLOBAL)
	except OSError:
	    print("skip")
	    raise SystemExit
	core.freerdp_settings_new.restype = ctypes.c_void_p
	core.freerdp_settings_new.argtypes = [ctypes.c_uint32]
	core.freerdp_settings_get_key_for_name.restype = ctypes.c_ssize_t
	core.freerdp_settings_get_key_for_name.argtypes = [ctypes.c_char_p]
	core.freerdp_settings_get_bool.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
	client.freerdp_client_settings_parse_command_line.argtypes = [
	    ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.c_int]
	settings = core.freerdp_settings_new(0)
	argv = [b"xfreerdp3", b"/v:host.invalid", b"/gfx"]
	client.freerdp_client_settings_parse_command_line(
	    settings, len(argv), (ctypes.c_char_p * len(argv))(*argv), 0)
	key = core.freerdp_settings_get_key_for_name(b"FreeRDP_SupportGraphicsPipeline")
	print("on" if core.freerdp_settings_get_bool(settings, key) else "off")
	EOF
}

with="$(gfx LD_PRELOAD="$hook" RDFEED_NO_GFX=1 WLOG_LEVEL=OFF)"
if [[ $with == skip ]]; then
	echo "skip  GFX: FreeRDP 3 is not installed"
else
	check "GFX stays off with RDFEED_NO_GFX" "$with" "off"
	check "GFX is left alone without it" "$(gfx LD_PRELOAD="$hook" WLOG_LEVEL=OFF)" "on"
fi

exit "$failed"
