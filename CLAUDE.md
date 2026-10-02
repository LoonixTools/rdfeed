# CLAUDE.md

## Style

- Keep everything short: replies, explanations, comments, docs.
- Use simple English: short sentences, common words.
- Avoid em dashes (—). Do not just swap them for "-" either. Rewrite the sentence instead, for
  example with a comma, a colon, brackets or two sentences.

## Commits

- English only.
- Conventional Commits prefix: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `ci:`, `build:`.
- Subject as short as possible. Imperative, lowercase, no trailing period.
- Body only when something genuinely cannot be inferred from the diff.
- Never add `Co-Authored-By`, "Generated with" or any other AI attribution to commits or PR descriptions.
- Do not commit or push before I have checked the changes locally and said they are fine. Then
  commit and push. Several attempts at the same thing make one commit, and attempts that did not
  work make none. Different things done in one session get a commit each. This also goes for
  releases and tags.

## Layout

- `src/rdfeed` and `src/lib/*.sh`: the command and its menu, plain bash.
- `src/fetch/rdfeed-fetch`: signs in to the feed (NTLM) and downloads the apps. Python, standard
  library only.
- `src/hook/rdfeed-hook.c`: goes into FreeRDP with `LD_PRELOAD`. Waits before the second gateway
  sign-in so the second MFA prompt comes, and keeps GFX off.
- `res/systemd`: the daily refresh, a user timer.

## Releases

Releases look like the ones of big projects such as Immich. `.github/release-notes.sh <tag>` builds
the notes: the entry from `CHANGELOG.md` (welcome and highlights), a support section, every commit
since the last release sorted by its prefix (`feat`, `fix`, `docs`, ...) with author and link, and
the full changelog link. So commit subjects end up in public: keep them clear.

1. Read `git log <last tag>..HEAD` and pick the version: only fixes → patch, something new → minor,
   something that breaks or needs the user to act → major.
2. Bump the version and add the entry at the top of `CHANGELOG.md`, in one commit (`chore: 1.4.0`).
3. Push, then push the tag: `git tag v1.4.0 && git push origin main v1.4.0`. The `release` workflow
   runs the tests and creates the release. It stops when the entry is missing.
4. PKGBUILDS picks up the new release for the AUR on its own.

A minor or major release (has `### Highlights`, gets a heading and the support section):

```markdown
## v1.4.0

_2026-09-24_

Welcome to rdfeed `v1.4.0`! One or two sentences on what this release is about.

<p align="center">
  <img width="480" alt="What the picture shows" src="https://raw.githubusercontent.com/LoonixTools/rdfeed/v1.4.0/<path>">
</p>

### 🚨 Breaking changes

- Only if there are any: what changed, and what the user has to do.

### Highlights

- First highlight, a few words
- Second highlight
```

A picture under the welcome is optional. To show the menu or another screen of the program, use a
real screenshot of it running in Konsole, in English. Never a text copy of the screen. The same goes
for the README. The highlights stay a plain list: no heading or text per highlight, the list of
commits explains the rest.

A patch release is just a sentence or two, for example: "A small patch. The menu no longer closes
when you press Enter." The list of commits follows on its own.

- Write for users: what they notice, not how the code does it. Friendly and simple.
- Commands and settings they type go in backticks, buttons and labels in bold.
- To change an old release: edit its entry, commit, then
  `gh release edit <tag> --title <tag> --notes "$(.github/release-notes.sh <tag>)"`.

## README

- New UI (a window, a screen, a menu, a setting, a notification) gets a screenshot in the README,
  next to the text about it. Like for releases: a real screenshot of it running, in English.
- When a screen changes, take its screenshot again. The README never shows an old one.
- Screenshots show the demo workspace (Contoso Apps, `CONTOSO\jdoe`) from `tests/fake_rdweb.py`,
  never a real company.

## Testing

Never test against the real setup: the workspaces, the keyring, the timer and the app menu belong
to the user's machine, and a real server counts every wrong password.

- `make test` runs NTLM against the test vectors of MS-NLMP, the feed, the .rdp files and the
  icons, whole subscriptions against `tests/fake_rdweb.py`, the hook, and the command from `add` to
  `remove`. No real server, no root.
- `tests/test_cli.sh` runs in a temporary home, with fakes for `secret-tool`, `systemctl`,
  `notify-send`, `kbuildsycoca6` and `xfreerdp3` on `PATH`. Do the same for anything by hand.
- `python3 tests/fake_rdweb.py [port]` serves the demo workspace (user `jdoe`, domain `CONTOSO`,
  the password is in the file). Point a temporary home at it with `XDG_CONFIG_HOME`,
  `XDG_DATA_HOME`, `XDG_CACHE_HOME` and `RF_LIBDIR=src/lib RF_FETCH=src/fetch/rdfeed-fetch`.
- `make check` after every change. New strings: `po/update-pot.sh`, then translate them in every `po/*.po`.
