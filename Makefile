# rdfeed: build and install
#
# The shell front end and rdfeed-fetch install as they are. The one thing to
# compile is rdfeed-hook.so, which goes into FreeRDP. Translations and the
# man page are optional and skipped when msgfmt or scdoc are missing.

# Overridable so a packager can pass the version it is actually building
# (`make VERSION=$pkgver`). The literal below is the fallback for builds
# straight from a checkout, and is what a release tag has to carry.
VERSION      ?= 1.0.0

PREFIX       ?= /usr
DESTDIR      ?=
BINDIR       ?= $(PREFIX)/bin
DATADIR      ?= $(PREFIX)/share
LIBDIR       ?= $(DATADIR)/rdfeed/lib
LIBEXECDIR   ?= $(PREFIX)/lib/rdfeed
LOCALEDIR    ?= $(DATADIR)/locale
MANDIR       ?= $(DATADIR)/man
ICONDIR      ?= $(DATADIR)/icons/hicolor/scalable/apps

# Where systemd looks for user units, asked of systemd itself for a normal
# install. A build with a prefix of its own keeps them under that prefix.
ifeq ($(PREFIX),/usr)
USERUNITDIR  ?= $(shell pkg-config --variable=systemduserunitdir systemd 2>/dev/null || echo /usr/lib/systemd/user)
else
USERUNITDIR  ?= $(DATADIR)/systemd/user
endif

CC           ?= cc
CFLAGS       ?= -O2 -Wall -Wextra
BUILDDIR     ?= build
HOOK         := $(BUILDDIR)/rdfeed-hook.so

LINGUAS      := de es fr it ja ko nl pl pt_BR ru tr uk zh_CN
MOFILES      := $(patsubst %,po/%.mo,$(LINGUAS))
MANPAGE      := doc/rdfeed.1

LIBS         := $(wildcard src/lib/*.sh)

MSGFMT       := $(shell command -v msgfmt 2>/dev/null)
SCDOC        := $(shell command -v scdoc 2>/dev/null)

.PHONY: all build check test install uninstall clean version

all: build

build: $(HOOK) $(MOFILES) $(MANPAGE)

# The one place the version is written down, for everything that has to agree
# with it: the release workflow checking that the tag it was handed says the
# same thing, and the PKGBUILD.
version:
	@echo $(VERSION)

$(HOOK): src/hook/rdfeed-hook.c
	@mkdir -p $(BUILDDIR)
	$(CC) $(CFLAGS) $(CPPFLAGS) -shared -fPIC $(LDFLAGS) -o $@ $< -ldl

po/%.mo: po/%.po
ifdef MSGFMT
	$(MSGFMT) --check --output-file=$@ $<
else
	@echo "msgfmt not found, skipping $@"
endif

$(MANPAGE): doc/rdfeed.1.scd
ifdef SCDOC
	$(SCDOC) < $< > $@
else
	@echo "scdoc not found, skipping $@"
endif

# Syntax-check every shell file and rdfeed-fetch, and run shellcheck when it
# is available. SC2034 is off: the files share their variables, and
# shellcheck looks at one file at a time.
check:
	@set -e; for f in src/rdfeed $(LIBS) tests/*.sh; do \
		bash -n "$$f" && echo "ok  $$f"; \
	done
	@python3 -m py_compile src/fetch/rdfeed-fetch tests/*.py && echo "ok  python"
	@rm -rf src/fetch/__pycache__ tests/__pycache__
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -e SC1090,SC1091,SC2034 src/rdfeed $(LIBS) tests/*.sh \
			&& echo "ok  shellcheck"; \
	else \
		echo "shellcheck not found, skipped"; \
	fi

# The NTLM sign-in against the test vectors of the spec, the feed, the .rdp
# files and the icons, a whole subscription against a fake RD Web server, and
# the hook. Nothing here talks to a real server or touches the real setup.
test: $(HOOK)
	python3 -m unittest discover -s tests -p 'test_*.py' -v
	RDFEED_HOOK=$(HOOK) bash tests/test_hook.sh
	bash tests/test_cli.sh

install: build
	# the command
	install -Dm755 src/rdfeed "$(DESTDIR)$(BINDIR)/rdfeed"
	install -d "$(DESTDIR)$(LIBDIR)"
	install -Dm644 -t "$(DESTDIR)$(LIBDIR)" $(LIBS)
	sed -i -e 's|@VERSION@|$(VERSION)|g' \
	       -e 's|@LIBDIR@|$(LIBDIR)|g' \
	       -e 's|@LIBEXECDIR@|$(LIBEXECDIR)|g' \
	       -e 's|@LOCALEDIR@|$(LOCALEDIR)|g' \
	       "$(DESTDIR)$(BINDIR)/rdfeed" \
	       "$(DESTDIR)$(LIBDIR)"/*.sh

	# the helpers
	install -Dm755 src/fetch/rdfeed-fetch "$(DESTDIR)$(LIBEXECDIR)/rdfeed-fetch"
	install -Dm755 $(HOOK) "$(DESTDIR)$(LIBEXECDIR)/rdfeed-hook.so"

	# the daily refresh, and the icon of the workspace folders
	install -Dm644 res/systemd/rdfeed-refresh.service "$(DESTDIR)$(USERUNITDIR)/rdfeed-refresh.service"
	install -Dm644 res/systemd/rdfeed-refresh.timer "$(DESTDIR)$(USERUNITDIR)/rdfeed-refresh.timer"
	sed -i -e 's|@BINDIR@|$(BINDIR)|g' "$(DESTDIR)$(USERUNITDIR)/rdfeed-refresh.service"
	install -Dm644 res/rdfeed.svg "$(DESTDIR)$(ICONDIR)/rdfeed.svg"

	# translations
	@for l in $(LINGUAS); do \
		if [ -f "po/$$l.mo" ]; then \
			install -Dm644 "po/$$l.mo" \
				"$(DESTDIR)$(LOCALEDIR)/$$l/LC_MESSAGES/rdfeed.mo"; \
		fi; \
	done

	# documentation
	@if [ -f $(MANPAGE) ]; then \
		install -Dm644 $(MANPAGE) "$(DESTDIR)$(MANDIR)/man1/rdfeed.1"; \
	fi
	install -Dm644 README.md "$(DESTDIR)$(DATADIR)/doc/rdfeed/README.md"

uninstall:
	rm -f  "$(DESTDIR)$(BINDIR)/rdfeed"
	rm -rf "$(DESTDIR)$(DATADIR)/rdfeed"
	rm -rf "$(DESTDIR)$(LIBEXECDIR)"
	rm -f  "$(DESTDIR)$(USERUNITDIR)/rdfeed-refresh.service"
	rm -f  "$(DESTDIR)$(USERUNITDIR)/rdfeed-refresh.timer"
	rm -f  "$(DESTDIR)$(ICONDIR)/rdfeed.svg"
	rm -f  "$(DESTDIR)$(MANDIR)/man1/rdfeed.1"
	rm -rf "$(DESTDIR)$(DATADIR)/doc/rdfeed"
	@for l in $(LINGUAS); do rm -f "$(DESTDIR)$(LOCALEDIR)/$$l/LC_MESSAGES/rdfeed.mo"; done

clean:
	rm -rf $(BUILDDIR) po/*.mo $(MANPAGE)
