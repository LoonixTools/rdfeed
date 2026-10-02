/*
 * rdfeed-hook: works around two FreeRDP problems, loaded with LD_PRELOAD.
 *
 * 1. The second MFA prompt. A connection broker sends the client on to the
 *    server that hosts the session, so FreeRDP opens a second tunnel through
 *    the RD Gateway right away. With MFA on the gateway (the Azure MFA NPS
 *    extension), that second sign-in needs a second prompt. When it comes
 *    less than about 10 seconds after the first one was confirmed, no prompt
 *    is sent and the gateway waits forever. Windows does not run into this.
 *    So a new connection to port 443 waits a little first.
 *
 *    RDFEED_GW_WAIT   auto (the default), always or never. auto waits only
 *                     when the first sign-in took long enough for somebody to
 *                     confirm a prompt.
 *    RDFEED_GW_DELAY  how long to wait, in seconds (12).
 *
 *    Before waiting it prints "[rdfeed] gateway-delay <seconds>" to stderr,
 *    so rdfeed can tell the user a second prompt is coming.
 *
 * 2. The graphics pipeline. FreeRDP 3 always turns GFX on, there is no switch
 *    to turn it off, and in RemoteApp mode xfreerdp does not repaint a window
 *    after it was minimized or resized. With RDFEED_NO_GFX set, every attempt
 *    to turn it on is turned into off, and the classic drawing is used.
 *
 * It also makes stdout line buffered, so FreeRDP's log reaches rdfeed as it
 * happens.
 *
 * Copyright (C) 2026 Felitendo
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* A pause this long between two connections means a new tunnel, not the
 * second channel of the same one or an IPv6 to IPv4 fallback. */
#define NEW_TUNNEL_SECONDS 2.0
/* A first sign-in that took this long had a person confirming a prompt. */
#define MFA_SECONDS 2.5

static int (*real_connect)(int, const struct sockaddr *, socklen_t);
static int (*real_set_bool)(void *, int, int);

static double first_connect = -1;
static double last_connect = -1;

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

__attribute__((constructor)) static void init(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
}

/* RTLD_NEXT only finds libfreerdp3 when it was loaded globally, as it is in
 * xfreerdp. Otherwise ask the library itself. */
static void *freerdp_sym(const char *name)
{
	void *sym = dlsym(RTLD_NEXT, name);
	if (!sym) {
		void *lib = dlopen("libfreerdp3.so.3", RTLD_LAZY | RTLD_NOLOAD);
		if (lib)
			sym = dlsym(lib, name);
	}
	return sym;
}

static long gfx_key(void)
{
	static long key = -2;
	if (key == -2) {
		key = -1;
		if (getenv("RDFEED_NO_GFX")) {
			ssize_t (*by_name)(const char *) =
				(ssize_t (*)(const char *))freerdp_sym("freerdp_settings_get_key_for_name");
			if (by_name)
				key = (long)by_name("FreeRDP_SupportGraphicsPipeline");
		}
	}
	return key;
}

int freerdp_settings_set_bool(void *settings, int id, int val)
{
	if (!real_set_bool)
		real_set_bool = (int (*)(void *, int, int))freerdp_sym("freerdp_settings_set_bool");
	if (!real_set_bool)
		return 0;
	if (val && id == gfx_key())
		val = 0;
	return real_set_bool(settings, id, val);
}

static int should_wait(double t)
{
	const char *mode = getenv("RDFEED_GW_WAIT");

	if (last_connect < 0 || t - last_connect < NEW_TUNNEL_SECONDS)
		return 0;
	if (mode && strcmp(mode, "never") == 0)
		return 0;
	if (mode && strcmp(mode, "always") == 0)
		return 1;
	return t - first_connect >= MFA_SECONDS;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
	if (!real_connect)
		real_connect = (int (*)(int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "connect");

	int port = -1;
	if (addr && addr->sa_family == AF_INET)
		port = ntohs(((const struct sockaddr_in *)addr)->sin_port);
	else if (addr && addr->sa_family == AF_INET6)
		port = ntohs(((const struct sockaddr_in6 *)addr)->sin6_port);

	if (port == 443) {
		double t = now();
		if (first_connect < 0)
			first_connect = t;
		if (should_wait(t)) {
			const char *env = getenv("RDFEED_GW_DELAY");
			unsigned left = env ? (unsigned)atoi(env) : 12;
			fprintf(stderr, "[rdfeed] gateway-delay %u\n", left);
			fflush(stderr);
			while (left)
				left = sleep(left);
			t = now();
		}
		last_connect = t;
	}
	return real_connect(fd, addr, len);
}
