# Fork spec — Omarchy `pass` vault (gw7523)

Handoff for a **new Claude Code session** (`--model fable` / `claude-fable-5`).
This checkout is `https://github.com/gw7523/omarchy-passwordstore` (fork of
hegjon/omarchy-passwordstore @ 1e166ef). Work on branch `personal`.

Token-lean / Fable: one focused session, no mid-session model switch, verify
with `test/lint` + `test/test-*` + `omarchy-plugin-validate .` before claiming
done. Do not dump secrets into QML properties, argv, or `console.log`.

## Goal

Keep the existing search overlay (fuzzy find, copy/reveal/edit/OTP/type).
Add **setup** so a new Omarchy seat can:

1. Create or load a GPG key, then `pass init`.
2. Choose how the vault syncs: **local-only**, **git**, **rclone**, or **custom**.
3. Use the vault (already implemented — do not regress it).
4. **Multiple vaults** on one seat: e.g. a personal store and a shared
   team store (shared GPG recipients), each with its own directory, keys,
   and sync backend. Switch which vault the overlay searches.

## Identity

- Change plugin id to `io.github.gw7523.passwordstore` (manifest, QML
  `pluginId`, IPC toggle strings, tests, README, CLAUDE.md).
- Keep `hegjon.passwordstore` as `clonedFrom` / credit in README.
- Version: `0.3.0`.
- Author: gw7523. License stays MIT.

## Setup UI

First open when there is no usable store (`pass` missing, no
`~/.password-store` / configured `storeDir`, or no GPG id in `.gpg-id`):
show a **setup card** (same Omarchy menu/lock tokens as the search overlay),
not a terminal dump.

Steps (wizard, Back/Next, Esc cancels):

### 1. Dependencies

Offer to install `pass` (and optionally `pass-otp`, `git`, `rclone`, `gnupg`,
`wtype`) via `omarchy pkg add` in a floating terminal. Detect with `command -v`.

### 2. GPG key

- **Use existing:** list secret keys (`gpg --list-secret-keys --with-colons`),
  pick one.
- **Generate:** open a terminal with `gpg --full-generate-key` (user stays at
  the tty/pinentry). Re-scan when the terminal exits.
- **Import:** `gpg --import` from a file path the user types (or a path
  picker if Omarchy already has one — do not invent a file dialog from
  scratch if painful; a TextField + Enter is enough).

Never generate a passphrase-less key automatically. Never pass the
passphrase through QML.

### 3. Init store (per vault)

`pass init <gpg-id...>` with `PASSWORD_STORE_DIR` = that vault's `storeDir`
(default `~/.password-store` for the first vault). `pass init` already
accepts **multiple GPG ids** — use that for a shared vault (encrypt to
everyone's keys). If the directory already has `.gpg-id`, skip init and
show the path.

Each vault is a **separate directory** (separate `PASSWORD_STORE_DIR`),
not a `pass init --path` subfolder. That way personal and shared can use
different git remotes / rclone paths.

Default layout suggestion (user can change):

| Vault id | Label | Directory | Keys |
|---|---|---|---|
| `personal` | Personal | `~/.password-store` | the operator's key |
| `shared` (optional) | Shared | `~/.password-store-shared` | operator + imported teammates (or a shared team key) |

### 4. Sync backend (required choice)

Setting key: `syncBackend` = `local` | `git` | `rclone` | `custom`.

| Backend | Setup | Runtime |
|---|---|---|
| **local** | No remote. Optional “this directory is the whole vault”. | No auto-push. |
| **git** | `pass git init` if needed. Ask for remote URL (https or ssh). `git remote add origin` + first `pass git push -u origin HEAD` (or `master`/`main` as the repo uses). Auth is git/ssh/gpg as usual — run push/pull in a terminal if credentials are needed. | After a successful mutating `pass` action (insert/edit/rm/generate), `pass git push` in the helper (failures notify, do not block copy). Overlay open: optional `pass git pull --rebase` (setting `gitPullOnOpen`, default true). |
| **rclone** | Ask for remote path `remote:bucket/pass` (rclone must already be configured; do not put rclone tokens in the plugin). First `rclone sync` **from** remote if the store is empty, else **to** remote after confirm. | After mutate: `rclone copy`/`sync` store → remote (never delete-remote-by-default; prefer `rclone copy` or `sync` with a setting `rcloneMode` = copy\|sync, default **copy**). Open: optional pull (`rclone copy` remote → store) behind `rclonePullOnOpen` default true. |
| **custom** | Two command strings, with `$STORE` expanded to the store dir, no other interpolation: `syncPushCmd`, `syncPullCmd`. Empty pull is ok. Run via `bash -lc` with cwd=$STORE. Document that secrets must not appear in the command. | Same as git: pull on open (if set), push after mutate. |

Persist backend settings **per vault** (not globals). Bar widget settings:

- `vaults` — JSON array of vault objects (see below). `omarchy bar set`
  with `--json` for the array.
- `activeVaultId` — which vault the overlay lists.

Vault object:

```json
{
  "id": "personal",
  "name": "Personal",
  "storeDir": "~/.password-store",
  "gpgIds": ["0xDEADBEEF"],
  "syncBackend": "git",
  "gitRemote": "git@github.com:me/pass-personal.git",
  "rcloneRemote": "",
  "rcloneMode": "copy",
  "gitPullOnOpen": true,
  "rclonePullOnOpen": true,
  "syncPushCmd": "",
  "syncPullCmd": ""
}
```

Keep `storeDir` as a fallback when `vaults` is empty (migrates a single
existing store into `vaults[0]` id=`personal` on first setup save).

### 5. Done

Drop into the existing search overlay on the **active** vault.

A **Settings** affordance (gear, or `Ctrl+,`) re-opens setup: add vault,
edit vault, switch default, without wiping other stores.

## Multiple vaults (access)

- Overlay header: vault name; `Tab` / `Shift+Tab` (or a small dropdown)
  cycles vaults. Search, recent, copy, edit, and sync apply **only** to
  the active vault (`PASSWORD_STORE_DIR` in the helpers).
- Bar tooltip: `Password Store · <active name>`.
- **Add vault** from setup: name, directory, GPG (existing / generate /
  import), then that vault's sync backend. Shared vault: pick **one or
  more** GPG ids (import teammates' public keys first; or one shared
  secret key imported on each machine — document both, prefer multiple
  recipient ids).
- **Remove vault** removes the plugin record only, never `rm` the
  directory unless the user confirms a separate destructive action
  (default: leave files).
- Helpers take `--store DIR` (already on `passwordstore-list`). Thread
  the active vault's dir through list/action/setup/sync.

## Search overlay (existing — extend, don’t rewrite)

Keep: type-to-filter, Enter copy password, Alt+U username, Alt+O OTP,
Ctrl+Enter type password, Alt+E edit, recent list, 45s clip clear via `pass -c`.

Add (small):

- Empty-store / not-initialized → setup wizard, not a blank list.
- `F2` or a footer hint: “Setup / sync”.
- After `edit`/insert if we add insert later, trigger sync push.
- Optional `n` insert new entry: `pass generate` or `pass insert` in a
  terminal is fine for v0.3 (do not build a full editor in QML).

## Security (non-negotiable)

- Overlay never decrypts. Helpers call `pass` / `gpg` / `rclone` / `git`.
- Secrets: stdin/pipes only, never argv, never QML `property string password`.
- Clipboard: keep `pass -c` / existing `passwordstore-action` behaviour.
- `rclone`/`git` credentials stay in rclone config / ssh agent / git
  credential helper.
- No IpcHandler in the overlay (upstream CLAUDE.md: it segfaulted
  Quickshell). Toggle stays `omarchy-shell shell toggle <pluginId>`.

## Files to add/touch

- `manifest.json` — new id, version, extra barWidget schema keys
  (`vaults`, `activeVaultId`; per-vault sync fields live inside `vaults`).
  Keep a legacy `storeDir` default for one-store installs.
- `PasswordstoreOverlay.qml` / `PasswordstoreWidget.qml` — pluginId, setup
  pages.
- `passwordstore-setup` — new helper: `status`, `gpg-list`, `init`,
  `sync-status`, `sync-pull`, `sync-push`. JSON on stdout. No secrets.
- `passwordstore-action` / `passwordstore-list` — keep; call sync-push after
  mutating actions if backend ≠ local.
- `test/` — setup/status tests with fake `pass`/`gpg`/`rclone` like existing
  action tests. No real GPG key required in CI.
- `README.md` — install from **this fork**, setup wizard, sync table, Super
  keybind note (`SUPER+P` is taken).

## Verify

```bash
test/lint
test/test-manifest
test/test-list
test/test-action
# plus new setup tests
omarchy-plugin-validate .
shellcheck --severity=warning passwordstore-* test/test-*
```

Do not `omarchy plugin add` over a live hegjon checkout on this machine
without asking. Local dev: symlink this repo to
`~/.config/omarchy/plugins/io.github.gw7523.passwordstore` only after
validate passes.

## Out of scope

- Replacing 1Password / Bitwarden (omawarden).
- Storing rclone OAuth in the plugin.
- Age instead of GPG.
- Rewriting `pass` itself.
