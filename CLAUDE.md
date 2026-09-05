# Working notes for agents

Omarchy overlay + bar-widget plugin, gw7523's fork of hegjon's
(`io.github.gw7523.passwordstore`, `clonedFrom: hegjon.passwordstore`). For
a live copy, symlink this checkout to
`~/.config/omarchy/plugins/io.github.gw7523.passwordstore`; edits are then
live. Never install over a live `hegjon.passwordstore` checkout.

## Verifying changes

- `test/lint` (qmllint), `test/test-manifest`, `test/test-list`,
  `test/test-action`, `test/test-setup`, `omarchy-plugin-validate .` and
  `shellcheck --severity=warning passwordstore-* test/test-*` (no shellcheck
  on this box: `npx -y shellcheck`).
- `test/test-setup` uses real git against a bare repo in a temp dir and
  stand-ins for `pass`, `gpg`, `rclone`, `omarchy`, `notify-send`; the
  terminal is replaced through `PASSWORDSTORE_TERMINAL` (a command that runs
  `bash -c SCRIPT` synchronously). Both helpers honour that hook.
- The shell hot-reloads on file change, but a QML *type* error (a bad
  component file) is cached until `omarchy-restart-shell`. Wait ~8 s after a
  restart, then `journalctl --user --since "30 sec ago" | grep -i passwordstore`.
- IPC: `omarchy-shell shell toggle|summon|hide io.github.gw7523.passwordstore`
  (the shell's generic overlay routing; the plugin registers no IpcHandler).
- The overlay is `keepLoaded`, so a hot reload does not always replace the
  live instance; `omarchy-restart-shell` before trusting a screenshot.
- UI testing without touching a real store: make a directory of empty
  `*.gpg` files plus a `.gpg-id`, point a vault at it
  (`omarchy bar set io.github.gw7523.passwordstore vaults '[{"id":"t","name":"T","storeDir":"<dir>"}]' --json`),
  open the overlay, drive it with `wtype "git"` / `wtype -k Down` / `wtype -k F2`,
  screenshot with `grim -o HDMI-A-1` and `magick -crop`. The card is centered;
  on the 3840×2160 monitor `1400x800+1220+680` frames it. Switch to an empty
  workspace first (`hyprctl dispatch 'hl.dsp.focus({ workspace = "9" })'`) so
  only the wallpaper is behind the card. Restore the settings afterwards.
  `preview.png` is that crop.
- Settings are read by the overlay from `shell.shellConfig.bar.layout` (the
  widget's bar entry) with `manifest.barWidget.defaults` as fallback, and
  written with `shell.pluginRegistry.setBarWidget(id, key, value, {})`, the
  same path as `omarchy bar set`. The widget must be on the bar for a save to
  succeed; the wizard says so otherwise.
- `passwordstore-setup` reads the same entry from `shell.json` itself
  (`$XDG_CONFIG_HOME/omarchy/shell.json`), picks the vault by `--vault` /
  `activeVaultId` / first, and falls back to the entry's own keys when
  `vaults` is empty (the pre-vault single store, which the card calls
  `personal`). Options given on the command line win.
- The recent lists are `~/.local/state/omarchy-passwordstore/recent` (vault
  `personal`) and `recent-<id>`; the tests above leave fake names in them,
  so reset them after UI experiments.
- A real end-to-end copy: `./passwordstore-action copy-password <entry>
  --clip-time 5`. It decrypts, so gpg-agent may raise pinentry; run it under
  `timeout` when nobody is at the screen.

## Things that bit before

- `escape` is a reserved word in QML; a `function escape()` in a component
  makes the whole type unavailable ("Illegal method name").
- An `IpcHandler` in the overlay segfaulted Quickshell
  (`IpcHandler::updateRegistration` during `onPostReload`) when a plugin
  hot-reload raced an `omarchy-restart-shell`. No first-party overlay has one;
  neither does this plugin now. Save files, *then* wait, *then* restart.
- `pass show -cN` copies the *whole* line N, `login: alice` included, which is
  why the username path reads the entry and copies the value itself (with the
  same clear-after-N-seconds behaviour). Password and OTP still go through
  `pass -c` so pass's own clipboard handling is kept.
- The search card is type-to-filter with no TextField (the menu's pattern),
  so single letters are never shortcuts there; actions are Enter plus
  modifiers, and `Tab` switches vaults. `Util.editsFilter` claims Ctrl+U
  (clear) and Backspace. The wizard pages *do* have single-letter keys and
  TextFields: `keyCatcher` ignores keys in setup mode so they bubble to the
  card's `Keys.onPressed`, after the focused field has had its turn.
- `--quiet` only suppresses the success notifications; failures always notify,
  because the popup is gone by the time the script runs.
- A helper that asks a question (rclone's "upload N entries?", init's
  "re-encrypt?") must `exit` after printing it. The first rclone version
  printed the question and then uploaded anyway; `test/test-setup` now checks
  that nothing ran.
- Terminal work is waited on through a status file the wrapper writes, not
  the terminal's exit: `setsid`/`uwsm-app` detach, and a shell restart must
  not kill a half-finished `gpg --full-generate-key`.

## Style

- Comments explain *why*. Secrets never go through argv, `console.log`, or a
  QML property; keep it that way. Entry names and remote URLs are not
  secrets; custom sync commands are stored in `shell.json`, which is why the
  docs say not to put a secret in one.
- Version lives in `manifest.json`.
