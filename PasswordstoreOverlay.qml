pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Centered type-to-search overlay for pass, the standard unix password
// manager, styled like the Omarchy menu: same surface tokens, same card, same
// rows. Summoned with `omarchy-shell shell toggle hegjon.passwordstore '{}'`
// from a keybinding or the bar button. Without the payload the toggle is a no-op.
//
// The search card never sees a secret. passwordstore-list walks the store
// for the names of the *.gpg files, and passwordstore-action hands a chosen
// entry to pass itself (or wtype, for typing) once the card has closed.
// gpg-agent prompts through pinentry as it would from a terminal.
//
// The editor (Alt+N, Alt+E) is the one place a password is held here: a
// masked field, like the lock screen's, that accepts a paste, can reveal the
// value with each character class in its own colour, and can generate one.
// The value reaches pass over the helper's stdin, never argv, and the field
// is wiped the moment the card leaves the editor. Entries are stored as
// name/username so the list can show both without decrypting anything.
//
// A seat can hold several vaults (a personal store, a shared team store),
// each its own PASSWORD_STORE_DIR with its own keys and sync backend; the
// card searches the active one and Tab switches. When the active vault has
// no usable store yet the same card becomes a setup wizard (vault, tools,
// GPG keys, pass init, sync), driven by passwordstore-setup. Anything that
// could need a passphrase or a credential (key generation, package installs,
// the first push) happens in a terminal the helper waits on; the card only
// ever sees JSON status.
Item {
  id: root

  readonly property string pluginId: "hegjon.passwordstore"

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool opened: false

  // "search" is the card as it always was; "setup" the wizard.
  property string mode: "search"

  // --- state ------------------------------------------------------------

  property var entries: []
  property var recent: []
  property string storePath: ""
  property bool otpAvailable: false
  property string lastError: ""
  property bool initialized: false

  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: true

  // The last `passwordstore-setup status` for the vault it was asked about;
  // usable is what decides the mode.
  property var status: null
  readonly property bool storeUsable: !!(status && status.usable)
  // Route to the wizard automatically only for the open that asked for it.
  property bool autoRoute: false
  property string syncNote: ""

  // --- settings ---------------------------------------------------------

  // Settings live on the bar widget's entry in shell.json (that is where
  // `omarchy bar set` and the widget settings dialog write them), so the
  // overlay reads them from the live shell config, falling back to the
  // manifest defaults when the widget is not on the bar at all.
  readonly property var widgetSettings: {
    var layout = shell && shell.shellConfig && shell.shellConfig.bar ? shell.shellConfig.bar.layout : null
    if (!layout) return ({})
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        var id = typeof entry === "string" ? entry : (entry && entry.id)
        if (id !== pluginId) continue
        return typeof entry === "string" ? ({}) : entry
      }
    }
    return ({})
  }

  function manifestDefault(key, fallback) {
    var defaults = manifest && manifest.barWidget ? manifest.barWidget.defaults : null
    if (defaults && defaults[key] !== undefined && defaults[key] !== null) return defaults[key]
    return fallback
  }

  function setting(key, fallback) {
    var value = widgetSettings ? widgetSettings[key] : undefined
    if (value === undefined || value === null || value === "") return manifestDefault(key, fallback)
    return value
  }

  // `omarchy bar set` stores booleans as strings unless given --json, so a
  // boolean setting has to be coerced rather than read straight through.
  function asBool(value, fallback) {
    if (value === undefined || value === null || value === "") return fallback
    if (typeof value === "string") return value !== "false" && value !== "0"
    return value !== false
  }

  function boolSetting(key, fallback) { return asBool(setting(key, fallback), fallback) }

  function intSetting(key, fallback, min, max) {
    var value = parseInt(setting(key, fallback), 10)
    if (!isFinite(value)) return fallback
    return Math.max(min, Math.min(max, value))
  }

  readonly property int clipTimeSec: intSetting("clipTimeSec", 60, 5, 600)
  readonly property string usernameKeys: String(setting("usernameKeys", "login,user,username,email")).trim()
  readonly property bool allowTyping: boolSetting("allowTyping", true)
  readonly property bool notifyOnCopy: boolSetting("notifyOnCopy", true)
  // name/username paths (github.com/jack), or pass's classic folder/entry
  // layout where the last segment is the entry and the username lives
  // inside the file.
  readonly property bool usernameInPath: boolSetting("usernameInPath", true)
  // For test/capture: the card's on-screen box, written to the state dir
  // whenever it changes, so a screenshot can be cropped to the card
  // exactly. Off unless the setting says so; nothing secret in it.
  readonly property bool writeCardGeometry: boolSetting("writeCardGeometry", false)
  function publishGeometry() {
    if (!writeCardGeometry || !opened) return
    var x = Math.round(card.x), y = Math.round(card.y), w = Math.round(card.width), h = Math.round(card.height)
    // WxH+X+Y, then the output the card is on, so a capture crops the right screen.
    var where = panel.screen ? String(panel.screen.name) : ""
    Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$2\" > \"$1/card-geometry\"", "sh", recentDir, w + "x" + h + "+" + x + "+" + y + (where !== "" ? " " + where : "")])
  }
  Timer { id: geometryTimer; interval: 120; repeat: false; onTriggered: root.publishGeometry() }
  readonly property bool autofillSubmit: boolSetting("autofillSubmit", false)
  // Forgetting: after idleLockMin minutes without use (0: never), on the
  // session lock, and before sleep, the seat forgets the vault's cached
  // passphrase (by keygrip), the clipboard and any file share left; the
  // next use asks for the passphrase again.
  readonly property int idleLockMin: intSetting("idleLockMin", 0, 0, 1440)
  readonly property bool clearOnLock: boolSetting("clearOnLock", true)
  property double lastUse: 0            // 0: not used since the shell started (or since an idle forget)
  function noteUse() { lastUse = Date.now() }
  // Idle forgets the active vault's; a seat event (lock, sleep) forgets
  // every vault's, since it is the seat that is being left. The stores are
  // handed to the helper one at a time.
  property var forgetQueue: []
  function forget(reason, everyVault) {
    var stores = []
    if (everyVault) {
      for (var i = 0; i < vaults.length; i++) {
        var s = String(vaults[i].storeDir || "")
        if (stores.indexOf(s) < 0) stores.push(s)
      }
    }
    if (stores.length === 0) stores.push(storeDir)
    // The editor is the one place a secret sits in QML, and the card must
    // not still be up, revealed, when the seat comes back. A share the
    // picker is about to send is left to it.
    if (opened) {
      if (mode === "edit") resetEditor()
      if (mode === "share" && !shareSending) leaveShare(true)
      dismiss()
    }
    savePayload = ""
    // Union with whatever is still queued: a seat-wide forget under way
    // must not be cut short by an idle one.
    var queue = forgetQueue.slice()
    for (var j = 0; j < stores.length; j++) if (queue.indexOf(stores[j]) < 0) queue.push(stores[j])
    forgetQueue = queue
    console.log("passwordstore: forgetting cached passphrases:", reason)
    forgetNext()
  }
  function forgetNext() {
    if (forgetProcess.running || forgetQueue.length === 0) return
    var s = forgetQueue[0]
    forgetQueue = forgetQueue.slice(1)
    var command = [setupPath, "forget"]
    if (s !== "") command.push("--store", s)
    forgetProcess.command = command
    forgetProcess.running = true
  }
  Process {
    id: forgetProcess
    running: false
    command: []
    stdout: StdioCollector { id: forgetStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(String(forgetStdout.text || "")) } catch (e) { parsed = null }
      if (exitCode !== 0 || !parsed || !parsed.ok) console.log("passwordstore: forget did not clear:", parsed && parsed.error ? parsed.error : "exit " + exitCode)
      root.forgetNext()
    }
  }
  Timer {
    interval: 60000
    repeat: true
    running: root.idleLockMin > 0 && root.lastUse > 0
    onTriggered: {
      // An open card is in use. A closed one left idle forgets once, then
      // waits for the next use before counting again.
      if (root.opened || Date.now() - root.lastUse <= root.idleLockMin * 60000) return
      root.lastUse = 0
      root.forget("idle for " + root.idleLockMin + " min", false)
    }
  }
  // The session lock is ext-session-lock, not a layer; `hyprctl locked`
  // says. Polled while the setting is on; the transition to locked forgets.
  property bool sessionLocked: false
  Process {
    id: lockedProcess
    running: false
    command: ["hyprctl", "locked"]
    stdout: StdioCollector { id: lockedStdout; waitForEnd: true }
    onExited: function(exitCode) {
      // A compositor that could not be asked is not an unlock.
      if (exitCode !== 0) return
      var out = String(lockedStdout.text || "").trim().toLowerCase()
      var now = out === "true" || out === "yes" || out === "1"
      if (now && !root.sessionLocked) root.forget("session locked", true)
      root.sessionLocked = now
    }
  }
  Timer {
    interval: 5000
    repeat: true
    running: root.clearOnLock
    onTriggered: if (!lockedProcess.running) lockedProcess.running = true
  }
  // logind announces sleep on the system bus; gdbus prints each signal. If
  // gdbus goes away (missing, bus restarted) it is tried again later.
  // (running stays a binding: the retry flips a flag, so the setting keeps its say.)
  property bool sleepWanted: true
  Process {
    id: sleepProcess
    running: root.clearOnLock && root.sleepWanted
    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"]
    stdout: SplitParser { onRead: function(line) { if (/PrepareForSleep \(true/.test(line)) root.forget("sleep", true) } }
    onExited: function(exitCode) { root.sleepWanted = false; sleepRetry.start() }
  }
  Timer { id: sleepRetry; interval: 30000; repeat: false; onTriggered: root.sleepWanted = true }

  // The lockout pinentry-omarchy reports through status: while it holds,
  // nothing that decrypts is attempted and the legend shows the wait.
  readonly property var lockout: status && status.lockout ? status.lockout : null
  property int lockoutRemaining: 0
  readonly property bool locked: lockoutRemaining > 0
  function syncLockout() {
    lockoutRemaining = lockout && lockout.locked ? Math.max(0, Number(lockout.remaining) || 0) : 0
  }
  onLockoutChanged: syncLockout()
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.lockoutRemaining > 0
    onTriggered: {
      root.lockoutRemaining = Math.max(0, root.lockoutRemaining - 1)
      if (root.lockoutRemaining === 0) root.runSetup("status", [], "", root.activeVault)
    }
  }
  function formatRemaining(seconds) {
    return Math.floor(seconds / 60) + ":" + (seconds % 60 < 10 ? "0" : "") + (seconds % 60)
  }

  // --- vaults -----------------------------------------------------------

  // A vault record with every field present. `legacy` marks the one-store
  // configuration from before vaults existed: its sync fields are the
  // entry's own keys, and the first save turns it into vaults[0].
  function normalizeVault(raw, legacy) {
    var get = function(key, fallback) {
      var v = raw ? raw[key] : undefined
      if (v !== undefined && v !== null && v !== "") return v
      if (legacy) return setting(key, fallback)
      return manifestDefault(key, fallback)
    }
    var backend = String(get("syncBackend", "local")).trim()
    if (["local", "git", "rclone", "custom"].indexOf(backend) < 0) backend = "local"
    var gpgIds = raw && Array.isArray(raw.gpgIds) ? raw.gpgIds.map(String) : []
    return {
      id: String((raw && raw.id) || "personal"),
      name: String((raw && raw.name) || "Personal"),
      storeDir: String(get("storeDir", "")).trim(),
      gpgIds: gpgIds,
      syncBackend: backend,
      gitRemote: String(get("gitRemote", "")).trim(),
      gitPullOnOpen: asBool(get("gitPullOnOpen", true), true),
      gitSign: asBool(get("gitSign", false), false),
      rcloneRemote: String(get("rcloneRemote", "")).trim(),
      rcloneMode: String(get("rcloneMode", "copy")).trim() === "sync" ? "sync" : "copy",
      rclonePullOnOpen: asBool(get("rclonePullOnOpen", true), true),
      syncPushCmd: String(get("syncPushCmd", "")).trim(),
      syncPullCmd: String(get("syncPullCmd", "")).trim(),
      legacy: !!legacy
    }
  }

  // Vaults on record. `omarchy bar set … vaults` without --json leaves a
  // string holding the array, which is accepted too.
  readonly property var vaults: {
    var raw = widgetSettings ? widgetSettings.vaults : undefined
    if (typeof raw === "string") { try { raw = JSON.parse(raw) } catch (error) { raw = [] } }
    var out = []
    if (Array.isArray(raw)) {
      for (var i = 0; i < raw.length; i++) {
        if (raw[i] && typeof raw[i] === "object" && typeof raw[i].id === "string" && raw[i].id !== "")
          out.push(normalizeVault(raw[i], false))
      }
    }
    if (out.length === 0) out.push(normalizeVault({ id: "personal", name: "Personal" }, true))
    return out
  }
  readonly property bool vaultsOnRecord: vaults.length > 0 && !vaults[0].legacy

  // The active vault: the setting, or a switch that could not be saved
  // (widget not on the bar), else the first.
  property string activeOverride: ""
  readonly property string activeVaultId: {
    var wanted = activeOverride !== "" ? activeOverride : String(setting("activeVaultId", ""))
    for (var i = 0; i < vaults.length; i++) if (vaults[i].id === wanted) return wanted
    return vaults[0].id
  }
  readonly property var activeVault: {
    for (var i = 0; i < vaults.length; i++) if (vaults[i].id === activeVaultId) return vaults[i]
    return vaults[0]
  }
  readonly property string storeDir: activeVault.storeDir
  readonly property bool syncActive: activeVault.syncBackend !== "local"
  readonly property bool pullOnOpen: activeVault.syncBackend === "git" ? activeVault.gitPullOnOpen
    : activeVault.syncBackend === "rclone" ? activeVault.rclonePullOnOpen
    : activeVault.syncBackend === "custom" ? activeVault.syncPullCmd !== ""
    : false

  function vaultById(id) {
    for (var i = 0; i < vaults.length; i++) if (vaults[i].id === id) return vaults[i]
    return null
  }

  // The helper arguments that pin a call to one vault. --vault is only
  // given for a vault on record (or the legacy one, which the helper knows
  // as "personal"); a draft that is not saved yet goes by --store alone.
  function vaultArgs(vault) {
    var args = []
    if (vault.storeDir !== "") args.push("--store", vault.storeDir)
    if (vault.legacy || vaultById(vault.id) !== null) args.push("--vault", vault.id)
    return args
  }

  // Writes one setting onto the bar entry, the same place `omarchy bar set`
  // writes. Returns "" or a reason.
  function saveSetting(key, value) {
    var registry = shell ? shell.pluginRegistry : null
    if (!registry || typeof registry.setBarWidget !== "function")
      return "This shell cannot save widget settings"
    var error = registry.setBarWidget(pluginId, key, value, {})
    if (error && String(error).indexOf("could not find widget") >= 0)
      return "Put the widget on the bar first: omarchy plugin enable " + pluginId
    return error ? String(error) : ""
  }

  // The record as stored: no derived flags.
  function vaultRecord(vault) {
    return {
      id: vault.id, name: vault.name, storeDir: vault.storeDir, gpgIds: vault.gpgIds,
      syncBackend: vault.syncBackend, gitRemote: vault.gitRemote, gitPullOnOpen: vault.gitPullOnOpen, gitSign: vault.gitSign,
      rcloneRemote: vault.rcloneRemote, rcloneMode: vault.rcloneMode, rclonePullOnOpen: vault.rclonePullOnOpen,
      syncPushCmd: vault.syncPushCmd, syncPullCmd: vault.syncPullCmd
    }
  }

  // Saves the whole list (a legacy single store becomes vaults[0] here) and
  // the active id. Returns "" or a reason.
  function saveVaults(list, activeId) {
    var records = []
    for (var i = 0; i < list.length; i++) records.push(vaultRecord(list[i]))
    var error = saveSetting("vaults", records)
    if (error !== "") return error
    if (activeId !== undefined && activeId !== null) {
      error = saveSetting("activeVaultId", activeId)
      if (error !== "") return error
      activeOverride = ""
    }
    return ""
  }

  function switchVault(delta) {
    disarmPreselect()
    if (vaults.length < 2) return
    var at = 0
    for (var i = 0; i < vaults.length; i++) if (vaults[i].id === activeVaultId) at = i
    var next = vaults[(at + delta + vaults.length) % vaults.length].id
    activateVault(next)
  }

  // Make ID the active vault without touching the search (the Health
  // page opening a finding in another vault): the listing is re-read,
  // the filter and cursor stay.
  function adoptVault(id) {
    if (vaultById(id) === null || id === activeVaultId) return
    var error = saveSetting("activeVaultId", id)
    if (error !== "") activeOverride = id
    refresh()
  }
  function activateVault(id) {
    if (vaultById(id) === null) return
    var error = saveSetting("activeVaultId", id)
    if (error !== "") activeOverride = id
    filterText = ""
    selectedIndex = 0
    syncNote = ""
    autoRoute = true
    refresh()
    runSetup("status", [], "", activeVault)
  }

  // Qt.resolvedUrl yields a file:// URL; Process wants a plain path.
  readonly property string listPath:
    Qt.resolvedUrl("passwordstore-list").toString().replace(/^file:\/\//, "")
  readonly property string actionPath:
    Qt.resolvedUrl("passwordstore-action").toString().replace(/^file:\/\//, "")
  readonly property string setupPath:
    Qt.resolvedUrl("passwordstore-setup").toString().replace(/^file:\/\//, "")

  // Recently used names live outside the store so they are never committed
  // with it, and outside the plugin dir so a reinstall keeps them. One list
  // per vault; the first keeps the file name from before vaults existed.
  readonly property string recentDir: {
    var state = Quickshell.env("XDG_STATE_HOME")
    if (!state) state = Quickshell.env("HOME") + "/.local/state"
    return state + "/omarchy-passwordstore"
  }
  readonly property string recentFile:
    recentDir + (activeVaultId === "personal" ? "/recent" : "/recent-" + activeVaultId.replace(/[^A-Za-z0-9._-]/g, "_"))

  readonly property string keyGlyph: String.fromCodePoint(0xF0306)     // nf-md-key
  readonly property string clockGlyph: String.fromCodePoint(0xF0954)   // nf-md-history
  readonly property string checkGlyph: String.fromCodePoint(0xF012C)   // nf-md-check
  readonly property string boxGlyph: String.fromCodePoint(0xF0131)     // nf-md-checkbox_blank_outline
  readonly property string boxCheckedGlyph: String.fromCodePoint(0xF0132) // nf-md-checkbox_marked
  readonly property string vaultGlyph: String.fromCodePoint(0xF0BB4)   // nf-md-safe_square_outline
  readonly property string plusGlyph: String.fromCodePoint(0xF0415)    // nf-md-plus
  readonly property string eyeGlyph: String.fromCodePoint(0xF0208)     // nf-md-eye
  readonly property string eyeOffGlyph: String.fromCodePoint(0xF0209)  // nf-md-eye_off

  // --- look: the menu's tokens ------------------------------------------

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowSpacing: Style.space(2)
  property int rowHeight: Math.max(Style.space(50), Style.font.heading + Style.spacing.rowPaddingX * 2)
  // The legend wraps in the menu-width card; its height feeds the card's.
  readonly property int footerHeight: footerLabel.implicitHeight
  property int maxVisibleRows: 10

  // Search stays menu-width; setup and the editor have fields and buttons
  // side by side that do not fit in 420.
  property int cardWidth: Math.min(mode !== "search" ? Style.space(560) : Style.space(420),
                                   panel.width - Style.gapsOut * 2)
  readonly property int visibleRowsHeight: {
    var n = Math.min(rows.length, maxVisibleRows)
    if (n === 0) return rowHeight * 2   // room for the "no matches" message
    return n * rowHeight + (n - 1) * rowSpacing
  }
  readonly property int menuHeight: menuOpen ? menuColumn.implicitHeight + contentSpacing : 0
  readonly property int searchCardHeight:
    contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight + menuHeight + contentSpacing + footerHeight
  readonly property int setupCardHeight:
    contentMargin * 2 + setupColumn.implicitHeight
  readonly property int editCardHeight:
    contentMargin * 2 + editColumn.implicitHeight
  readonly property int shareCardHeight:
    contentMargin * 2 + shareColumn.implicitHeight
  readonly property int cardHeight: Math.min(
    mode === "setup" ? setupCardHeight : (mode === "edit" ? editCardHeight : (mode === "share" ? shareCardHeight : (mode === "history" ? historyCardHeight : searchCardHeight))),
    panel.height - Style.gapsOut * 2)

  // --- open / close (the shell's overlay contract) ----------------------

  // The window the card was opened from, so the entry for it can be
  // preselected: a browser tab titled "Sign in · GitHub" lands on
  // github.com/jack. Read once per open, never stored.
  property string windowTitle: ""
  property string windowClass: ""
  property string windowAddress: ""
  property bool windowMatched: false
  property bool preselectArmed: false   // until the user touches the selection
  property bool autofillAsked: false    // Alt+Enter on a window-picked row asks once
  // Only a browser's title says which site is open; a terminal's title
  // holding "github.com" (a path, a git log) must not pick an entry.
  // Exact app ids, plus the -browser/-stable/-esr/-bin suffixes packaging
  // adds; a prefix match would take zenity for zen.
  readonly property var browserClasses: ["chromium", "chrome", "google-chrome", "brave", "brave-browser", "firefox", "librewolf", "zen", "vivaldi", "vivaldi-stable", "epiphany", "microsoft-edge", "org.mozilla.firefox", "org.chromium.chromium", "org.gnome.epiphany", "floorp", "waterfox", "helium"]
  readonly property bool windowIsBrowser: {
    var c = windowClass.toLowerCase().replace(/-(browser|stable|esr|bin|beta|nightly)$/, "")
    return browserClasses.indexOf(c) >= 0
  }
  property bool preselectDone: false    // once per open: later listings do not re-pick
  Process {
    id: windowProcess
    running: false
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector { id: windowStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(String(windowStdout.text || "")) } catch (e) { parsed = null }
      root.windowTitle = parsed && parsed.title ? String(parsed.title) : ""
      root.windowClass = parsed && parsed.class ? String(parsed.class) : ""
      root.windowAddress = parsed && parsed.address ? String(parsed.address) : ""
      root.preselectByWindow()
    }
  }

  // Pick the entry whose name appears as a whole word in a browser's tab
  // title (the browser's own name stripped): github.com or github in
  // "Sign in · GitHub". The longest match wins. A tab title is the site's
  // to write, so this is a suggestion: autofill from it asks once, and any
  // key the user presses on the list disarms it.
  readonly property string windowTitleBare: windowTitle.replace(/\s*[-–—·|]\s*(Mozilla Firefox|Firefox|Chromium|Google Chrome|Brave|Vivaldi|Zen Browser|LibreWolf|Microsoft Edge)\s*$/i, "")
  function preselectByWindow() {
    if (preselectDone || !preselectArmed || menuOpen || filterText !== "" || mode !== "search" || rows.length === 0) return
    if (windowAddress === "" && windowClass === "" && windowTitle === "") return   // the window is not known yet
    if (!windowIsBrowser) return
    preselectDone = true
    var hay = " " + windowTitleBare.toLowerCase().replace(/[^a-z0-9.]+/g, " ") + " "
    if (hay.trim() === "") return
    var best = -1, bestLen = 0
    for (var i = 0; i < rows.length; i++) {
      var title = String(rows[i].title || "").toLowerCase().replace(/^www\./, "")
      var stem = title.replace(/\.[a-z]+$/, "")   // github.com -> github
      if (title.length >= 4 && hay.indexOf(" " + title + " ") >= 0 && title.length > bestLen) { best = i; bestLen = title.length }
      else if (stem.length >= 4 && stem !== title && hay.indexOf(" " + stem + " ") >= 0 && stem.length > bestLen) { best = i; bestLen = stem.length }
    }
    windowMatched = best >= 0
    if (best >= 0) { cursorActive = true; selectedIndex = best; resultList.positionViewAtIndex(best, ListView.Contain) }
  }
  function disarmPreselect() { preselectArmed = false; windowMatched = false; autofillAsked = false }

  function open(payloadJson) {
    root.noteUse()
    if (root.mode === "edit") root.resetEditor()
    if (root.mode === "share") root.leaveShare(true)
    root.closeMenu()
    if (root.mode === "history") root.leaveHistory()
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.windowMatched = false
    root.windowAddress = ""
    root.preselectArmed = true
    root.preselectDone = false
    root.autofillAsked = false
    root.opened = true
    geometryTimer.restart()
    windowProcess.running = true
    root.autoRoute = true
    root.syncNote = ""
    // The store is re-read on every open: a `find` over a few hundred files
    // is cheap, and it is the only way a `pass insert` from a terminal shows
    // up without a restart. The status check runs alongside it and decides
    // whether the card is the search or the wizard.
    root.refresh()
    // The lockout policy follows the settings; pinentry-omarchy reads it
    // from the runtime dir, so it is handed over on every open.
    root.runSetup("lockout-policy", [], "", root.activeVault)
    root.runSetup("status", [], "", root.activeVault)
    if (root.mode === "setup") root.focusSetupPage()
    else Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.closeMenu()
    if (root.mode === "edit") root.resetEditor()
    if (root.mode === "history") root.leaveHistory()
    // dismiss() reaches here through shell.hide(); a send in flight keeps its file.
    if (root.mode === "share" && !root.shareSending) root.leaveShare(true)
  }

  function dismiss() {
    root.opened = false
    root.closeMenu()
    if (root.mode === "edit") root.resetEditor()
    if (root.mode === "history") root.leaveHistory()
    if (root.mode === "share" && !root.shareSending) root.leaveShare(true)
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // No IpcHandler here on purpose: the shell already exposes
  // `omarchy-shell shell toggle|summon|hide hegjon.passwordstore`
  // for every overlay, and an IpcHandler inside a hot-reloaded plugin has
  // crashed Quickshell when a reload raced a shell restart.

  // --- filtering --------------------------------------------------------

  // Every whitespace-separated token must match; a token matches as a
  // substring first and as an in-order subsequence second, so "ghb" still
  // finds "web/github.com" while plain substrings rank above it. Ties are
  // broken by how early the match begins, then by the store's own order.
  function scoreEntry(name, tokens) {
    var lower = name.toLowerCase()
    var parts = splitName(lower)
    var score = 0
    for (var t = 0; t < tokens.length; t++) {
      var token = tokens[t]
      var at = lower.indexOf(token)
      if (at >= 0) {
        score += 1000 - at
        if (parts.title.indexOf(token) === 0) score += 500          // name starts with it
        else if (parts.username.indexOf(token) === 0) score += 300  // username starts with it
        else if (parts.title.indexOf(token) >= 0) score += 200      // somewhere in the name
        continue
      }
      var pos = 0
      for (var c = 0; c < token.length; c++) {
        pos = lower.indexOf(token[c], pos)
        if (pos < 0) return -1
        pos++
      }
      score += 100
    }
    return score
  }

  // With usernameInPath an entry is stored as name/username
  // (github.com/jack): the last path segment is the username, whatever is
  // before it the application, website or account name. Without it the
  // last segment is the entry (pass's classic web/github.com) and the row
  // shows the folder under it; the username is only inside the file.
  function splitName(name) {
    var slash = name.lastIndexOf("/")
    var conflict = / \(conflict from origin(, [^)]+)?\)$/.test(name)
    if (usernameInPath) {
      var user = slash >= 0 ? name.slice(slash + 1) : ""
      return { name: name, title: slash >= 0 ? name.slice(0, slash) : name, username: user, subtitle: user, conflict: conflict }
    }
    return { name: name, title: slash >= 0 ? name.slice(slash + 1) : name, username: "", subtitle: slash >= 0 ? name.slice(0, slash) : "", conflict: conflict }
  }

  // The card's rows. Without a filter the recent entries come first, then the
  // whole store; with one, the ranked matches.
  readonly property var rows: {
    var tokens = filterText.toLowerCase().split(/\s+/).filter(function(t) { return t !== "" })
    var i, row
    if (tokens.length === 0) {
      var out = []
      var seen = {}
      for (i = 0; i < recent.length; i++) {
        row = splitName(recent[i]); row.recent = true
        out.push(row)
        seen[recent[i]] = true
      }
      for (i = 0; i < entries.length; i++) {
        if (seen[entries[i]]) continue
        row = splitName(entries[i]); row.recent = false
        out.push(row)
      }
      return out
    }
    var scored = []
    for (i = 0; i < entries.length; i++) {
      var s = scoreEntry(entries[i], tokens)
      if (s < 0) continue
      row = splitName(entries[i])
      row.recent = recent.indexOf(entries[i]) >= 0
      row.score = s
      row.order = i
      scored.push(row)
    }
    scored.sort(function(a, b) { return b.score - a.score || a.order - b.order })
    return scored
  }

  onRowsChanged: {
    if (rows.length === 0) selectedIndex = 0
    else if (selectedIndex >= rows.length) selectedIndex = rows.length - 1
    Qt.callLater(function() {
      if (root.rows.length > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(text) {
    if (text === filterText) return
    disarmPreselect()
    filterText = text
    selectedIndex = 0
    cursorActive = true
  }

  // Quickshell has no clipboard API; a hidden TextInput's paste() reads the
  // Qt clipboard for us. One line of it, whitespace collapsed, joins the
  // query.
  function pasteIntoFilter() {
    clipboardProbe.text = ""
    clipboardProbe.paste()
    var pasted = clipboardProbe.text.replace(/\s+/g, " ").trim()
    clipboardProbe.text = ""
    // A pasted URL searches by its host, without the www.
    var m = pasted.match(/^https?:\/\/(?:[^\/?#@]*@)?(\[[^\]]+\]|[^\/:?#]+)/i)
    if (m) pasted = m[1].toLowerCase().replace(/^www\./, "")
    if (pasted !== "") setFilter(filterText + pasted)
  }

  TextInput { id: clipboardProbe; visible: false; width: 0; height: 0 }

  function select(delta) {
    if (rows.length === 0) return
    disarmPreselect()
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(rows.length - 1, selectedIndex + delta))
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (rows.length === 0) return
    disarmPreselect()
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(rows.length - 1, index))
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  readonly property var selectedEntry: rows.length > 0 && selectedIndex >= 0 && selectedIndex < rows.length
    ? rows[selectedIndex] : null

  // --- listing ----------------------------------------------------------

  property bool refreshPending: false

  function refresh() {
    if (listProcess.running) { refreshPending = true; return }
    refreshPending = false
    var command = [listPath, "--recent", recentFile]
    if (storeDir !== "") command.push("--store", storeDir)
    listProcess.command = command
    listProcess.running = true
  }

  function applyListing(text) {
    initialized = true
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      lastError = "The password store helper returned something unreadable"
      return
    }
    if (parsed && parsed.store) storePath = String(parsed.store)
    if (parsed && parsed.error) {
      lastError = String(parsed.error)
      entries = []
      recent = []
      console.warn("passwordstore: listing failed:", lastError)
      return
    }
    lastError = ""
    entries = (parsed && parsed.entries) ? parsed.entries : []
    recent = (parsed && parsed.recent) ? parsed.recent : []
    otpAvailable = !!(parsed && parsed.otp)
    Qt.callLater(preselectByWindow)
  }

  Process {
    id: listProcess
    running: false
    command: []

    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyListing(listStdout.text)
      } else {
        root.initialized = true
        var detail = String(listStderr.text || "").replace(/\s+/g, " ").trim()
        root.lastError = detail !== "" ? detail : "The password store helper exited with code " + exitCode
      }
      if (root.refreshPending) Qt.callLater(root.refresh)
    }
  }

  // --- actions ----------------------------------------------------------

  // One action at a time: a second Enter while gpg-agent is still asking for
  // the passphrase would only queue a second prompt.
  function runAction(action, entry) {
    if (actionProcess.running) return
    noteUse()
    // Nothing that decrypts while locked; the legend says how long.
    if (locked && action !== "insert") return
    var name = entry ? String(entry.name) : ""
    // The card's own editor for new entries and edits; `pass edit` in a
    // terminal stays available (Alt+Shift+E) for an entry in some other format.
    if (action === "edit") { if (name) openEditor(entry); return }
    if (action === "insert") { openEditor(null, name); return }
    if (action === "edit-terminal") action = "edit"
    var terminalAction = action === "edit" || action === "insert" || action === "generate"
    if (!name && !(action === "insert" || action === "generate")) return
    if ((action === "type-password" || action === "type-username" || action === "autofill") && !allowTyping) return
    if (action === "copy-otp" && !otpAvailable) return

    var command = [actionPath, action, name,
                   "--recent", recentFile,
                   "--clip-time", String(clipTimeSec),
                   "--username-keys", usernameKeys]
    if (storeDir !== "") command.push("--store", storeDir)
    if (!notifyOnCopy) command.push("--quiet")
    if (action === "autofill") {
      if (autofillSubmit) command.push("--submit")
      if (windowAddress !== "") command.push("--window", windowAddress)
    }
    // The push after a change is the helper's job, once the terminal closes;
    // it looks the vault's backend up by id.
    if (terminalAction && syncActive) command.push("--sync", "--vault", activeVaultId)

    // Close before acting so a typed password lands in the window the user
    // came from, and so a pinentry dialog is not fighting the card for focus.
    dismiss()
    actionProcess.command = command
    actionProcess.running = true
  }

  function activateSelected(action) {
    // A row the window picked is a suggestion; typing a password into that
    // window takes a second Alt+Enter, with the title on screen.
    if (action === "autofill" && windowMatched && preselectArmed && !autofillAsked) { autofillAsked = true; return }
    runAction(action, selectedEntry)
  }

  // --- the row menu ---------------------------------------------------------

  // Right arrow on a row lists what can be done with it; the modifier keys
  // stay, the menu makes them discoverable.
  property bool menuOpen: false
  property int menuIndex: 0
  readonly property var menuRows: {
    var out = [{ label: "Copy password", keys: "Enter", action: "copy-password" },
               { label: "Copy username", keys: "Alt+U", action: "copy-username" }]
    if (otpAvailable) out.push({ label: "Copy OTP code", keys: "Alt+O", action: "copy-otp" })
    if (allowTyping) out.push({ label: autofillSubmit ? "Autofill username, Tab, password, Enter" : "Autofill username, Tab, password", keys: "Alt+Enter", action: "autofill" },
                              { label: "Type password", keys: "Ctrl+Enter", action: "type-password" })
    out.push({ label: "Open URL", keys: "Alt+L", action: "open-url" },
             { label: "Share over LocalSend", keys: "Alt+S", action: "share" },
             { label: "Edit", keys: "Alt+E", action: "edit" })
    return out
  }
  function openMenu() {
    if (!selectedEntry) return
    menuIndex = 0
    menuOpen = true
  }
  function closeMenu() { menuOpen = false; menuIndex = 0 }
  onMenuRowsChanged: menuIndex = Math.max(0, Math.min(menuRows.length - 1, menuIndex))
  function menuKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left) { closeMenu(); return true }
    if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) { menuIndex = Math.min(menuRows.length - 1, menuIndex + 1); return true }
    if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) { menuIndex = Math.max(0, menuIndex - 1); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { runMenu(menuIndex); return true }
    return false
  }
  function runMenu(index) {
    if (index < 0 || index >= menuRows.length) return
    var action = menuRows[index].action
    var entry = selectedEntry
    closeMenu()
    if (action === "share") openShare(entry)
    else runAction(action, entry)
  }
  // --- history --------------------------------------------------------------

  // Alt+H: the entry's commits (pass git); Enter on one restores that
  // version as a new commit, after a second Enter. Nothing is decrypted.
  property string historyEntry: ""
  property var historyCommits: []
  property int historyIndex: 0
  property string historyConfirm: ""
  property bool historyBusy: false
  property string historyError: ""
  property string historyBuffer: ""
  function openHistory(entry) {
    if (!entry || historyProcess.running || restoreProcess.running) return
    if (!activeVault || activeVault.syncBackend !== "git") { syncNote = "History needs the git backend (F2 → Sync)"; return }
    mode = "history"
    historyEntry = String(entry.name)
    historyCommits = []
    historyIndex = 0
    historyConfirm = ""
    historyError = ""
    historyBusy = true
    historyBuffer = ""
    var command = [setupPath, "history", "--entry", historyEntry].concat(vaultArgs(activeVault))
    historyProcess.command = command
    historyProcess.running = true
  }
  function leaveHistory() {
    mode = "search"
    historyEntry = ""
    historyCommits = []
    historyConfirm = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  Process {
    id: historyProcess
    running: false
    command: []
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.historyBuffer += data } }
    stderr: StdioCollector { id: historyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = root.historyBuffer
      root.historyBuffer = ""
      root.historyBusy = false
      if (root.mode !== "history") return
      var parsed = null
      try { parsed = JSON.parse(text) } catch (e) { parsed = null }
      if (exitCode !== 0 || !parsed || parsed.error) { root.historyError = String((parsed && parsed.error) || historyStderr.text || "").replace(/\s+/g, " ").trim() || "No history"; return }
      root.historyCommits = Array.isArray(parsed.commits) ? parsed.commits : []
    }
  }
  function restoreSelected() {
    if (historyIndex < 0 || historyIndex >= historyCommits.length || restoreProcess.running) return
    var sha = String(historyCommits[historyIndex].sha)
    if (historyConfirm !== sha) { historyConfirm = sha; return }
    historyConfirm = ""
    historyBusy = true
    // The commit lands in this vault whatever the card shows by the time
    // the helper is done: push there, and only redraw if still here.
    restoreEntry = historyEntry
    restoreVault = activeVault
    var command = [setupPath, "restore", "--entry", historyEntry, "--sha", sha].concat(vaultArgs(activeVault))
    restoreProcess.command = command
    restoreProcess.running = true
  }
  property string restoreEntry: ""
  property var restoreVault: null
  Process {
    id: restoreProcess
    running: false
    command: []
    stdout: StdioCollector { id: restoreStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.historyBusy = false
      var parsed = null
      try { parsed = JSON.parse(String(restoreStdout.text || "")) } catch (e) { parsed = null }
      var stillHere = root.mode === "history" && root.historyEntry === root.restoreEntry
      if (exitCode !== 0 || !parsed || !parsed.ok) { if (stillHere) root.historyError = String((parsed && parsed.error) || "Could not restore"); return }
      // The restore is a commit: push it like any change, then show the new history.
      // Not --quiet: a push that fails must say so, on the card and as a notification.
      if (root.restoreVault && String(root.restoreVault.syncBackend || "") === "git") root.runSetup("sync-push", [], "", root.restoreVault)
      root.refresh()
      if (stillHere) root.openHistory({ name: root.historyEntry })
    }
  }
  function historyKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) { if (historyConfirm !== "") historyConfirm = ""; else leaveHistory(); return true }
    if (historyBusy) return false
    if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) { historyIndex = Math.min(historyCommits.length - 1, historyIndex + 1); historyConfirm = ""; return true }
    if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) { historyIndex = Math.max(0, historyIndex - 1); historyConfirm = ""; return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { restoreSelected(); return true }
    return false
  }
  readonly property int historyCardHeight: contentMargin * 2 + historyColumn.implicitHeight


  // Alt+N: the query, if any, becomes the new entry's name.
  function insertNew(action) {
    var typed = filterText.trim()
    runAction(action, typed !== "" ? ({ name: typed }) : null)
  }

  Process {
    id: actionProcess
    running: false
    command: []

    stderr: StdioCollector { id: actionStderr; waitForEnd: true }

    onExited: function(exitCode) {
      var detail = String(actionStderr.text || "").replace(/\s+/g, " ").trim()
      if (exitCode !== 0) console.warn("passwordstore: action failed:", detail || ("exit " + exitCode))
    }
  }

  // --- the editor ---------------------------------------------------------

  // The entry being edited ("" for a new one) and the parts of it that are
  // not in a field: timestamps and the key: value lines the editor does not
  // know (a url:, an otpauth:// line), which are written back as they were.
  property string editEntry: ""
  property string editCreated: ""
  property string editModified: ""
  property var editExtra: []
  property string editUrl: ""
  // One-time codes: read reports whether the entry has an otpauth:// line;
  // the code itself comes from pass otp through the helper, refreshed when
  // the period runs out. Scan (slurp needs the pointer) hides the card.
  property bool editOtp: false
  property int editOtpPeriod: 30
  property var editLoaded: ({})        // the fields as read, to know when there are unsaved edits
  readonly property bool editDirty: (
    passwordField.text !== String(editLoaded.password || "") || notesArea.text !== String(editLoaded.notes || "")
    || urlField.text !== String(editLoaded.url || "") || usernameField.text !== String(editLoaded.username || "")
    || nameField.text !== String(editLoaded.title || ""))
  property bool otpBusy: false          // set / remove: the card hides while pass re-encrypts (pinentry may ask)
  property string otpCode: ""
  property int otpRemaining: 0
  property bool otpScanning: false
  property string otpBuffer: ""
  property string otpSetPayload: ""
  // editOtp says the entry has a code on disk (save keeps it); otpArmed
  // says the countdown is asking for it. A failed fetch stops the asking,
  // never the keeping.
  property bool otpArmed: false
  property string otpFor: ""            // the entry the running otp-code is about
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.mode === "edit" && root.otpArmed
    onTriggered: {
      if (root.otpRemaining > 1) root.otpRemaining -= 1
      else root.fetchOtp()
    }
  }
  function fetchOtp() {
    if (otpProcess.running || editEntry === "" || !otpArmed) return
    otpBuffer = ""
    otpFor = editEntry
    var command = [actionPath, "otp-code", editEntry]
    if (storeDir !== "") command.push("--store", storeDir)
    otpProcess.command = command
    otpProcess.running = true
  }
  Process {
    id: otpProcess
    running: false
    command: []
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.otpBuffer += data } }
    stderr: StdioCollector { id: otpStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = root.otpBuffer
      root.otpBuffer = ""
      if (root.mode !== "edit" || root.editEntry !== root.otpFor) return
      var parsed = null
      try { parsed = JSON.parse(text) } catch (e) { parsed = null }
      if (exitCode !== 0 || !parsed) {
        // No countdown means no more asking; the error stays on the page.
        root.otpCode = ""; root.otpRemaining = 0; root.otpArmed = false
        root.editError = String(otpStderr.text || "").replace(/\s+/g, " ").trim() || "Could not read the code"
        return
      }
      root.otpCode = String(parsed.code || "")
      root.otpRemaining = Math.max(1, Number(parsed.remaining) || 0)
      root.editOtpPeriod = Math.max(1, Number(parsed.period) || 30)
    }
  }
  // Set from a secret typed in (JSON on stdin), scan a QR code from the
  // screen, or remove: each re-encrypts the entry at once and re-reads it.
  // Copy the code without leaving the editor (runAction would dismiss).
  function otpCopy() {
    if (editEntry === "" || otpCopyProcess.running) return
    var command = [actionPath, "copy-otp", editEntry, "--clip-time", String(clipTimeSec)]
    if (storeDir !== "") command.push("--store", storeDir)
    if (!notifyOnCopy) command.push("--quiet")
    editError = ""
    otpCopyProcess.command = command
    otpCopyProcess.running = true
  }
  Process {
    id: otpCopyProcess
    running: false
    command: []
    stderr: StdioCollector { id: otpCopyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 || root.mode !== "edit") return
      root.editError = String(otpCopyStderr.text || "").replace(/\s+/g, " ").trim() || "Could not copy the code"
    }
  }

  function otpSet() {
    var secret = otpSecretField.text.trim()
    if (secret === "" || editEntry === "" || otpSetProcess.running) return
    if (editDirty) { editError = "Save your other changes first; setting a code rewrites the entry"; return }
    otpBusy = true
    otpSetPayload = JSON.stringify({ secret: secret, issuer: nameField.text.trim() })
    otpSecretField.text = ""
    var command = [actionPath, "otp-set", editEntry, "--quiet"]
    if (storeDir !== "") command.push("--store", storeDir)
    if (syncActive) command.push("--sync", "--vault", activeVaultId)
    otpSetProcess.command = command
    otpSetProcess.stdinEnabled = true
    otpSetProcess.running = true
  }
  Process {
    id: otpSetProcess
    running: false
    command: []
    stdinEnabled: true
    stderr: StdioCollector { id: otpSetStderr; waitForEnd: true }
    onStarted: { otpSetProcess.write(root.otpSetPayload + "\n"); root.otpSetPayload = ""; otpSetProcess.stdinEnabled = false }
    onExited: function(exitCode) {
      root.otpSetPayload = ""
      root.otpBusy = false
      if (root.mode !== "edit") return
      if (exitCode !== 0) root.editError = String(otpSetStderr.text || "").replace(/\s+/g, " ").trim() || "Could not set the code"
      else root.reloadEntry()
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    }
  }
  function otpScan() {
    if (editEntry === "" || otpScanProcess.running) return
    if (editDirty) { editError = "Save your other changes first; a scanned code rewrites the entry"; return }
    otpScanning = true
    var command = [actionPath, "otp-scan", editEntry, "--quiet"]
    if (storeDir !== "") command.push("--store", storeDir)
    if (syncActive) command.push("--sync", "--vault", activeVaultId)
    otpScanProcess.command = command
    otpScanProcess.running = true
  }
  Process {
    id: otpScanProcess
    running: false
    command: []
    stderr: StdioCollector { id: otpScanStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.otpScanning = false
      if (root.mode !== "edit") return
      if (exitCode !== 0) root.editError = String(otpScanStderr.text || "").replace(/\s+/g, " ").trim() || "No code was read"
      else root.reloadEntry()
      Qt.callLater(function() { (root.editOtp ? passwordField : otpSecretField).forceActiveFocus() })
    }
  }
  function otpRemove() {
    if (editEntry === "" || otpRemoveProcess.running) return
    if (editDirty) { editError = "Save your other changes first; removing the code rewrites the entry"; return }
    otpBusy = true
    var command = [actionPath, "otp-remove", editEntry, "--quiet"]
    if (storeDir !== "") command.push("--store", storeDir)
    if (syncActive) command.push("--sync", "--vault", activeVaultId)
    otpRemoveProcess.command = command
    otpRemoveProcess.running = true
  }
  Process {
    id: otpRemoveProcess
    running: false
    command: []
    stderr: StdioCollector { id: otpRemoveStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.otpBusy = false
      if (root.mode !== "edit") return
      if (exitCode !== 0) root.editError = String(otpRemoveStderr.text || "").replace(/\s+/g, " ").trim() || "Could not remove the code"
      else root.reloadEntry()
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    }
  }
  // Re-read the entry after an OTP change (which saved it): the fields
  // show what is on disk again.
  function reloadEntry() {
    if (editEntry === "") return
    editReading = true
    readBuffer = ""
    var command = [actionPath, "read", editEntry, "--username-keys", usernameKeys]
    if (storeDir !== "") command.push("--store", storeDir)
    readProcess.command = command
    readProcess.running = true
  }
  property bool editRevealed: false
  property bool editReading: false     // decrypting: the card hides so pinentry can have the keyboard
  // The name and username as read, so an unchanged entry is saved under
  // its own path even when that path is not name/username.
  property string editOrigTitle: ""
  property string editOrigUser: ""
  property string editError: ""
  property string readBuffer: ""
  property string savePayload: ""

  // Generator options; the defaults make a 20-character password from all
  // four classes, which is what pass generate would do as well.
  property int genLength: 20
  property bool genLower: true
  property bool genUpper: true
  property bool genDigits: true
  property bool genSymbols: true

  // One colour per character class when the password is revealed: letters
  // in the text colour, capitals blue, digits orange, symbols pink, in
  // shades that read on the theme's light or dark surface. The generator's
  // class buttons wear the same colours, which makes them the legend.
  readonly property bool darkSurface: background.hslLightness < 0.5
  readonly property color upperColor: darkSurface ? "#8fc7ff" : "#1a5fb4"
  readonly property color digitColor: darkSurface ? "#ffb86c" : "#a85400"
  readonly property color symbolColor: darkSurface ? "#ff8fa3" : "#b3123f"

  function classColor(ch) {
    if (ch >= "a" && ch <= "z") return foreground
    if (ch >= "A" && ch <= "Z") return upperColor
    if (ch >= "0" && ch <= "9") return digitColor
    return symbolColor
  }

  // Rich text for the revealed password: every character wrapped in its
  // class colour, the few characters HTML cares about escaped, spaces kept.
  function colorize(text) {
    var out = ""
    for (var i = 0; i < text.length; i++) {
      var ch = text[i]
      var shown = ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch === " " ? "&nbsp;" : ch
      out += "<font color=\"" + String(classColor(ch)).slice(0, 7) + "\">" + shown + "</font>"
    }
    return out
  }

  function formatStamp(stamp) {
    var s = String(stamp || "")
    return s.length >= 16 ? s.slice(0, 16).replace("T", " ") : s
  }

  property bool deleteConfirm: false

  readonly property string editTitle: editEntry === "" ? "New entry" : "Edit entry"
  readonly property bool editCanSave: !editReading && !genProcess.running && !saveProcess.running
    && nameField.text.trim() !== "" && passwordField.text !== ""

  // Open the editor: blank for a new entry (the query as the name, if any),
  // or decrypting an existing one first.
  function openEditor(entry, presetName) {
    if (editReading) return
    mode = "edit"
    editEntry = entry ? String(entry.name) : ""
    editCreated = ""
    editModified = ""
    editExtra = []
    editRevealed = false
    editError = ""
    deleteConfirm = false
    editOrigTitle = ""
    editOrigUser = ""
    if (entry) {
      var parts = splitName(String(entry.name))
      // Classic layout: the whole path is the name, the file has the username.
      nameField.text = usernameInPath ? parts.title : String(entry.name)
      usernameField.text = parts.username
      editOrigTitle = nameField.text
      editOrigUser = parts.username
    } else {
      var preset = String(presetName || "")
      var slash = usernameInPath ? preset.lastIndexOf("/") : -1
      nameField.text = slash > 0 ? preset.slice(0, slash) : preset
      usernameField.text = slash > 0 ? preset.slice(slash + 1) : ""
    }
    passwordField.text = ""
    notesArea.text = ""
    urlField.text = ""
    otpSecretField.text = ""
    editOtp = false
    otpCode = ""
    if (entry) {
      editReading = true
      readBuffer = ""
      var command = [actionPath, "read", String(entry.name), "--username-keys", usernameKeys]
      if (storeDir !== "") command.push("--store", storeDir)
      readProcess.command = command
      readProcess.running = true
    } else {
      Qt.callLater(function() { nameField.forceActiveFocus() })
    }
  }

  // Everything typed into the editor goes, the password first. savePayload
  // is not touched: saveEntry dismisses the card before the process has
  // started, and onStarted still has to write it.
  function resetEditor() {
    passwordField.text = ""
    notesArea.text = ""
    urlField.text = ""
    otpSecretField.text = ""
    editOtp = false
    otpArmed = false
    otpProcess.running = false
    otpFor = ""
    editLoaded = {}
    healthReturn = false
    otpCode = ""
    otpRemaining = 0
    nameField.text = ""
    usernameField.text = ""
    readBuffer = ""
    editExtra = []
    editEntry = ""
    editRevealed = false
    editError = ""
    deleteConfirm = false
    mode = "search"
  }

  // Delete asks first: Alt+D (or the button) turns the legend into the
  // question and the primary button into "Yes, delete"; Esc keeps the entry.
  function askDelete() {
    if (editEntry === "" || editReading) return
    deleteConfirm = true
    editError = ""
  }

  function deleteEntry() {
    if (!deleteConfirm || editEntry === "") return
    var command = [actionPath, "delete", editEntry]
    if (storeDir !== "") command.push("--store", storeDir)
    if (!notifyOnCopy) command.push("--quiet")
    if (syncActive) command.push("--sync", "--vault", activeVaultId)
    deleteProcess.command = command
    dismiss()
    deleteProcess.running = true
  }

  Process {
    id: deleteProcess
    running: false
    command: []
    stderr: StdioCollector { id: deleteStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("passwordstore: delete failed:", String(deleteStderr.text || "").replace(/\s+/g, " ").trim() || ("exit " + exitCode))
      else root.refresh()
    }
  }

  function leaveEditor() {
    if (editReading) return
    resetEditor()
    if (healthReturn) {
      healthReturn = false
      mode = "setup"
      goToStep(6)
      return
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function applyRead(text) {
    var parsed
    try { parsed = JSON.parse(String(text || "")) } catch (error) { parsed = null }
    if (!parsed || typeof parsed !== "object") { editError = "The helper returned something unreadable"; return }
    passwordField.text = String(parsed.password || "")
    // The decrypted username is the truth. When it disagrees with the last
    // path segment (a classic web/github.com with a login: line inside), the
    // whole path is the name and the segment is not a username; saving
    // without edits then keeps that path, and any edit moves the entry to
    // name/username.
    var inside = String(parsed.username || "")
    if (inside !== "" && inside !== usernameField.text) {
      nameField.text = editEntry
      usernameField.text = inside
      editOrigTitle = editEntry
      editOrigUser = inside
    } else if (usernameField.text === "" && inside !== "") {
      usernameField.text = inside
      editOrigUser = inside
    }
    notesArea.text = String(parsed.notes || "")
    urlField.text = String(parsed.url || "")
    editLoaded = { password: passwordField.text, notes: notesArea.text, url: urlField.text, username: usernameField.text, title: nameField.text }
    editOtp = !!parsed.otp
    otpArmed = editOtp
    editOtpPeriod = Math.max(1, Number(parsed.otpPeriod) || 30)
    otpCode = ""
    otpRemaining = 0
    if (editOtp) fetchOtp()
    editCreated = String(parsed.created || "")
    editModified = String(parsed.modified || "")
    editExtra = Array.isArray(parsed.extra) ? parsed.extra.map(function(l) { return String(l) }) : []
  }

  Process {
    id: readProcess
    running: false
    command: []
    // Chunks are gathered in readBuffer and cleared after parsing; a
    // StdioCollector would keep the decrypted JSON around until the next run.
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.readBuffer += data } }
    stderr: StdioCollector { id: readStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = root.readBuffer
      root.readBuffer = ""
      root.editReading = false
      if (root.mode !== "edit" || !root.opened) return
      if (exitCode === 0) root.applyRead(text)
      else root.editError = String(readStderr.text || "").replace(/\s+/g, " ").trim() || ("Could not read " + root.editEntry)
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    }
  }

  function generatePassword() {
    if (genProcess.running || editReading) return
    var classes = []
    if (genLower) classes.push("lower")
    if (genUpper) classes.push("upper")
    if (genDigits) classes.push("digit")
    if (genSymbols) classes.push("symbol")
    if (classes.length === 0) { editError = "Pick at least one character class"; return }
    editError = ""
    genProcess.command = [actionPath, "generate-password", "", "--length", String(genLength), "--classes", classes.join(",")]
    genProcess.running = true
  }

  Process {
    id: genProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(data) { if (root.mode === "edit") passwordField.text = String(data) } }
    stderr: StdioCollector { id: genStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.editError = String(genStderr.text || "").replace(/\s+/g, " ").trim() || "Could not generate a password"
    }
  }

  function validEntryName(name) {
    return name !== "" && name[0] !== "-" && name[0] !== "/" && name[name.length - 1] !== "/"
      && name.indexOf("..") < 0 && name.indexOf("//") < 0
  }

  // Save: the entry's name is name/username, the content goes to the
  // helper's stdin as JSON, and the card closes like it does for every other
  // action; the helper notifies when it is done (or not).
  function saveEntry() {
    if (!editCanSave) return
    var title = nameField.text.trim().replace(/^\/+|\/+$/g, "")
    var user = usernameField.text.trim()
    if (user.indexOf("/") >= 0) { editError = "A username cannot contain a slash"; return }
    var unchanged = editEntry !== "" && title === editOrigTitle && user === editOrigUser
    var name = unchanged || !usernameInPath ? (editEntry !== "" ? editEntry : title)
      : (user !== "" ? title + "/" + user : title)
    // Classic layout: a renamed entry keeps its username inside the file.
    if (!usernameInPath && editEntry !== "" && title !== editOrigTitle) name = title
    if (!validEntryName(name)) { editError = "That name will not do as a pass entry"; return }
    if (name !== editEntry && entries.indexOf(name) >= 0) { editError = "There is already an entry named " + name; return }
    var url = urlField.text.trim()
    if (url !== "" && !/^[a-z][a-z0-9+.-]*:/i.test(url)) url = "https://" + url
    if (url !== "" && !/^https?:\/\//i.test(url)) { editError = "The URL has to start with http:// or https://"; return }
    var payload = {
      password: passwordField.text,
      username: user,
      url: url,
      otp: editOtp,
      notes: notesArea.text,
      extra: editExtra,
      created: editCreated
    }
    var command = [actionPath, "save", name, "--recent", recentFile, "--username-keys", usernameKeys]
    if (storeDir !== "") command.push("--store", storeDir)
    if (editEntry !== "" && editEntry !== name) command.push("--from", editEntry)
    // A new name must be new on disk as well; the listing could be stale.
    if (name !== editEntry) command.push("--no-overwrite")
    if (!notifyOnCopy) command.push("--quiet")
    if (syncActive) command.push("--sync", "--vault", activeVaultId)
    savePayload = JSON.stringify(payload)
    payload = null
    saveProcess.command = command
    dismiss()
    saveProcess.stdinEnabled = true
    saveProcess.running = true
  }

  Process {
    id: saveProcess
    running: false
    command: []
    stdinEnabled: true
    stderr: StdioCollector { id: saveStderr; waitForEnd: true }
    // The payload is written once the process is up, then stdin is closed
    // so pass sees the end of the entry; the copy held here goes with it.
    onStarted: {
      saveProcess.write(root.savePayload + "\n")
      root.savePayload = ""
      saveProcess.stdinEnabled = false
    }
    // A process that never starts still exits (with -1), so the payload is
    // cleared on either path; nothing else holds the entry once the fields
    // are wiped.
    onExited: function(exitCode) {
      root.savePayload = ""
      if (exitCode !== 0) console.warn("passwordstore: save failed:", String(saveStderr.text || "").replace(/\s+/g, " ").trim() || ("exit " + exitCode))
      else root.refresh()
    }
  }

  // --- sharing over LocalSend ---------------------------------------------

  // Alt+S: the entry is encrypted for a recipient key, or with a one-time
  // passphrase the card shows for reading out over another channel, into
  // a file under the runtime dir; Enter then opens LocalSend's device
  // picker in a terminal, which removes the file when it closes.
  property string shareEntry: ""
  property string shareFile: ""
  property string sharePassphrase: ""
  property string shareError: ""
  property bool shareBusy: false
  property bool shareSending: false
  property bool shareReading: false    // decrypting: the panel hides so pinentry can have the keyboard
  property bool shareAbandoned: false  // left while encrypting: the file is discarded when it appears
  property string shareBuffer: ""

  function openShare(entry) {
    if (!entry || shareProcess.running) return
    mode = "share"
    shareEntry = String(entry.name)
    shareFile = ""
    sharePassphrase = ""
    shareError = ""
    shareSending = false
    recipientField.text = ""
    Qt.callLater(function() { recipientField.forceActiveFocus() })
  }

  // Back to the search; a prepared but unsent file is removed, and one
  // still being made is removed when the helper reports it.
  function leaveShare(discard) {
    if (discard && shareFile !== "") Quickshell.execDetached([actionPath, "discard", "", "--file", shareFile])
    if (discard && shareBusy) shareAbandoned = true
    shareFile = ""
    sharePassphrase = ""
    shareEntry = ""
    shareError = ""
    shareBusy = false
    shareReading = false
    shareSending = false
    recipientField.text = ""
    mode = "search"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function prepareShare() {
    if (shareBusy || shareEntry === "") return
    var to = recipientField.text.replace(/\s+/g, "")
    if (to !== "" && !/^(0x)?[0-9A-Fa-f]{16,40}$/.test(to)) { shareError = "A fingerprint is 16 to 40 hex digits"; return }
    shareError = ""
    shareBusy = true
    shareReading = true
    shareAbandoned = false
    shareBuffer = ""
    var command = [actionPath, "share", shareEntry, "--quiet"]
    if (to !== "") command.push("--to", to)
    if (storeDir !== "") command.push("--store", storeDir)
    shareProcess.command = command
    shareProcess.running = true
  }

  function sendShare() {
    if (shareFile === "" || actionProcess.running) return
    // The helper is started before the card goes, and shareSending keeps
    // close() from discarding the file on the way out.
    shareSending = true
    actionProcess.command = [actionPath, "send", "", "--file", shareFile]
    actionProcess.running = true
    dismiss()
    shareFile = ""
    leaveShare(false)
  }

  Process {
    id: shareProcess
    running: false
    command: []
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.shareBuffer += data } }
    stderr: StdioCollector { id: shareStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = root.shareBuffer
      root.shareBuffer = ""
      root.shareBusy = false
      root.shareReading = false
      var parsed = null
      try { parsed = JSON.parse(text) } catch (e) { parsed = null }
      if (root.shareAbandoned || root.mode !== "share") {
        // Left before the helper finished: the file it made goes.
        root.shareAbandoned = false
        if (parsed && parsed.file) Quickshell.execDetached([root.actionPath, "discard", "", "--file", String(parsed.file)])
        return
      }
      if (exitCode !== 0 || !parsed || !parsed.ok) {
        root.shareError = String(shareStderr.text || "").replace(/\s+/g, " ").trim() || "Could not prepare the entry"
        return
      }
      root.shareFile = String(parsed.file || "")
      root.sharePassphrase = String(parsed.passphrase || "")
      // Encrypted for a key: nothing to read out, straight to the picker.
      if (root.sharePassphrase === "") root.sendShare()
    }
  }

  function shareKey(event) {
    if (event.key === Qt.Key_Escape) { leaveShare(true); return true }
    if (shareBusy) return false
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (shareFile === "") prepareShare(); else sendShare()
      return true
    }
    return false
  }

  // Keys the editor answers to after the focused field has had its turn.
  function editKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var alt = event.modifiers & Qt.AltModifier
    if (event.key === Qt.Key_Escape) {
      if (deleteConfirm) deleteConfirm = false
      else leaveEditor()
      return true
    }
    if (editReading) return false
    if (deleteConfirm && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { deleteEntry(); return true }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && ctrl) { saveEntry(); return true }
    if (ctrl && event.key === Qt.Key_S) { saveEntry(); return true }
    if (alt && event.key === Qt.Key_D) { askDelete(); return true }
    if (alt && event.key === Qt.Key_R) { editRevealed = !editRevealed; return true }
    if (alt && event.key === Qt.Key_G) { generatePassword(); return true }
    return false
  }

  // --- the setup helper -------------------------------------------------

  // Which command setupProcess is running, so onExited knows what the JSON
  // means. Empty when idle.
  property string setupOp: ""
  property string setupBusy: ""
  property string setupError: ""
  property string setupNote: ""
  property bool statusPending: false
  // Non-status calls that arrived while the helper was busy. `status` is
  // coalesced via statusPending; everything else must not be dropped —
  // gpg-list used to vanish because enterSetup ran from onExited while
  // Process.running was still true.
  property var setupQueue: []

  // `vault` pins the call: the active vault, or the wizard's draft.
  function runSetup(op, args, busyText, vault) {
    if (setupProcess.running) {
      if (op === "status") { statusPending = true; return }
      setupQueue.push({ op: op, args: args || [], busyText: busyText || "", vault: vault })
      return
    }
    setupOp = op
    setupBusy = busyText || ""
    if (op !== "status" && op !== "gpg-inspect") setupError = ""
    var target = vault || (mode === "setup" ? draft : activeVault)
    setupProcess.command = [setupPath, op].concat(vaultArgs(target)).concat(args || [])
    setupProcess.running = true
  }

  function drainSetup() {
    if (setupProcess.running) return
    if (setupQueue.length > 0) {
      var next = setupQueue.shift()
      runSetup(next.op, next.args, next.busyText, next.vault)
      return
    }
    if (statusPending) {
      statusPending = false
      runSetup("status", [], "", mode === "setup" ? draft : activeVault)
    }
  }

  Process {
    id: setupProcess
    running: false
    command: []

    stdout: StdioCollector { id: setupStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupStderr; waitForEnd: true }

    onExited: function(exitCode) {
      var op = root.setupOp
      root.setupOp = ""
      root.setupBusy = ""
      var parsed = null
      try { parsed = JSON.parse(String(setupStdout.text || "")) } catch (error) { parsed = null }
      if (!parsed) {
        var detail = String(setupStderr.text || "").replace(/\s+/g, " ").trim()
        if (op !== "status") root.setupError = detail || ("The setup helper exited with code " + exitCode)
        else console.warn("passwordstore: status failed:", detail || ("exit " + exitCode))
      } else {
        root.handleSetupResult(op, parsed)
      }
      Qt.callLater(root.drainSetup)
    }
  }

  Timer {
    id: importInspectTimer
    interval: 350
    repeat: false
    onTriggered: root.inspectImportPath()
  }

  function handleSetupResult(op, parsed) {
    if (op === "lockout-policy") return
    if (op === "audit") {
      if (parsed && parsed.findings) {
        healthFindings = parsed.findings
        healthChecked = Number(parsed.checked) || 0
        healthFailed = Number(parsed.failed) || 0
        healthHibpError = parsed.hibpError ? String(parsed.hibpError) : ""
        setupNote = ""
        setupError = ""
        if (healthFailed > 0 || healthHibpError !== "") setupError = healthShortfall
      } else setupError = String((parsed && parsed.error) || "The check did not run")
      return
    }
    if (op === "pinentry") {
      if (parsed && parsed.ok) {
        setupNote = parsed.pinentry === "omarchy" ? "gpg-agent now asks with Omarchy's prompt." : "gpg-agent is back on its default prompt."
        runSetup("status", [], "", draft)
      } else setupError = String((parsed && parsed.error) || "Could not change the passphrase prompt")
      return
    }
    if (parsed.error) {
      if (op === "status") console.warn("passwordstore: status:", parsed.error)
      else setupError = String(parsed.error)
      return
    }
    switch (op) {
      case "status":
        applyStatus(parsed)
        if (autoRoute) {
          autoRoute = false
          // Re-enter setup even if the last open left mode === "setup";
          // otherwise gpg-list never runs again after a generate in a
          // terminal and the card still says "gpg has no key yet".
          if (!storeUsable) enterSetup(-1)
          else if (storeUsable && mode === "search" && syncActive && pullOnOpen) pullOnOpenNow()
        }
        break
      case "install":
        applyStatus(parsed)
        if (parsed.installStatus !== 0) setupError = "The install did not finish (exit " + parsed.installStatus + ")"
        depSelected = []
        break
      case "gpg-list":
      case "gpg-generate":
      case "gpg-import":
      case "gpg-export":
        gpgKeys = Array.isArray(parsed.keys) ? parsed.keys : []
        if (op === "gpg-import") {
          var kind = String(parsed.kind || (parsed.importedSecret ? "secret" : "public"))
          if (kind === "secret")
            setupNote = "Imported a private (secret) key. This seat can decrypt entries encrypted for it."
              + (parsed.deleted ? " The file was shredded." : (importDeleteFile ? " The file could not be deleted; remove it yourself." : ""))
          else
            setupNote = "Imported a public key (recipient). It cannot decrypt here; select it with your private key for a shared vault."
          gpgImporting = false
          gpgImportKind = ""
          importInspect = {}
          importPathField.text = ""
        }
        if (op === "gpg-generate" && parsed.status === 124) setupNote = "Still waiting for gpg? Press F5 to rescan"
        if (op === "gpg-export") {
          gpgExporting = false
          gpgExportKind = ""
          setupNote = (parsed.kind === "secret"
            ? "Wrote the private key to " + parsed.file + " (" + parsed.bytes + " bytes). Move it where it is going, import it there, then delete it here: shred -u " + parsed.file
            : "Wrote the public key to " + parsed.file + " (" + parsed.bytes + " bytes). Safe to send to anyone who should encrypt for you.")
        }
        preselectStoreKeys()
        break
      case "gpg-inspect":
        if (parsed.defaults !== undefined) {
          importDefaults = parsed.defaults || {}
          if (gpgImporting && String(importPathField.text).trim() === "") {
            var suggested = importDefaults[gpgImportKind]
            if (suggested && suggested.path) {
              importPathField.text = suggested.path
              importInspect = suggested
            }
          }
        } else {
          importInspect = parsed
        }
        break
      case "init":
        applyStatus(parsed)
        if (parsed.needsReencrypt) {
          reencryptOffered = true
          setupNote = String(parsed.detail || "")
        } else {
          reencryptOffered = false
          setupNote = parsed.skipped ? "" : "Store created at " + String(parsed.store || storePath)
          goToStep(5)
        }
        break
      case "sync-setup":
        if (parsed.needsConfirm) {
          syncConfirm = String(parsed.detail || "Upload the store to the remote?")
        } else {
          syncConfirm = ""
          finishSetup(String(parsed.detail || ""))
        }
        break
      case "sync-pull":
        syncNote = parsed.ok ? (parsed.skipped ? "" : "Synced") : "Pull failed: " + String(parsed.error || "")
        refresh()
        break
      case "sync-push":
        if (parsed.ok) break
        if (mode === "history") historyError = "Restored here, but the push failed: " + String(parsed.error || "")
        else setupError = "Push failed: " + String(parsed.error || "")
        break
    }
  }

  function applyStatus(parsed) {
    status = parsed
    if (parsed.store) storePath = String(parsed.store)
    var missing = []
    var deps = parsed.deps || {}
    if (!deps.pass) missing.push("pass")
    if (!deps.gnupg) missing.push("gnupg")
    depSelected = missing
    preselectStoreKeys()
  }

  // The draft's keys, or the store's own, are the natural selection.
  function preselectStoreKeys() {
    if (selectedGpg.length > 0 || gpgKeys.length === 0) return
    var ids = draft && Array.isArray(draft.gpgIds) && draft.gpgIds.length > 0 ? draft.gpgIds
      : (status && Array.isArray(status.gpgIds) ? status.gpgIds : [])
    var picked = []
    for (var i = 0; i < ids.length; i++) {
      var id = String(ids[i])
      for (var k = 0; k < gpgKeys.length; k++) {
        var key = gpgKeys[k]
        if (key.fpr === id || key.id === id || (key.fpr && id.length >= 8 && key.fpr.slice(-id.length) === id.toUpperCase())
            || (key.uid && key.uid.indexOf("<" + id + ">") >= 0)) {
          if (picked.indexOf(key.fpr) < 0) picked.push(key.fpr)
          break
        }
      }
    }
    if (picked.length > 0) {
      selectedGpg = picked
      for (var g = 0; g < gpgKeys.length; g++) if (gpgKeys[g].fpr === picked[0]) gpgIndex = g
    }
  }

  // Pull on open runs in its own Process so the status/list path is never
  // held up by a slow remote.
  function pullOnOpenNow() {
    if (pullProcess.running) return
    syncNote = "Pulling…"
    pullProcess.command = [setupPath, "sync-pull"].concat(vaultArgs(activeVault))
    pullProcess.running = true
  }

  Process {
    id: pullProcess
    running: false
    command: []
    stdout: StdioCollector { id: pullStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(String(pullStdout.text || "")) } catch (error) { parsed = null }
      if (parsed) root.handleSetupResult("sync-pull", parsed)
      else root.syncNote = "Pull failed (exit " + exitCode + ")"
    }
  }

  // --- the wizard -------------------------------------------------------

  // 0 vaults (hub) · 1 vault · 2 dependencies · 3 GPG keys · 4 init · 5 sync
  property int setupStep: 0
  readonly property var stepTitles: ["Vaults", "Vault", "Dependencies", "GPG keys", "Password store", "Sync", "Health"]
  readonly property bool healthHibp: boolSetting("healthHibp", false)
  property var healthFindings: []
  property int healthChecked: -1
  property int healthIndex: 0
  function openHealthEntry(index) {
    if (index < 0 || index >= healthRows.length) return
    var name = healthRows[index].entry
    if (!name) return
    // The findings are the draft vault's; the editor works on the active one.
    if (healthVaultId !== "" && healthVaultId !== activeVaultId) adoptVault(healthVaultId)
    healthReturn = true
    mode = "search"
    openEditor({ name: name })
  }
  function runHealth() {
    healthFindings = []
    healthChecked = -1
    healthFailed = 0
    healthHibpError = ""
    healthIndex = 0
    healthVaultId = draft.id
    runSetup("audit", healthHibp ? ["--hibp"] : [], "Reading every entry of " + draft.name + " (pinentry may ask)…", draft)
  }
  property string healthVaultId: ""     // whose store the findings are about
  property int healthFailed: 0          // entries the audit could not read
  property string healthHibpError: ""   // why the breach check did not run
  // What the last check could not cover; shown with the findings, so it
  // does not vanish with the page's transient error line.
  readonly property string healthShortfall:
    (healthFailed > 0 ? healthFailed + " entries could not be read (a cancelled prompt, a missing key); they were not checked. " : "")
    + (healthHibpError !== "" ? healthHibpError + " No breach check was made." : "")
  property bool healthReturn: false     // the editor was opened from a finding: Esc comes back here
  readonly property var healthRows: {
    // One row per entry, so every one of a reused group can be opened.
    var out = []
    var glyph = { reused: String.fromCodePoint(0xF0453), short: String.fromCodePoint(0xF0092), old: clockGlyph, empty: String.fromCodePoint(0xF0131), pwned: String.fromCodePoint(0xF0029) }
    for (var i = 0; i < healthFindings.length; i++) {
      var f = healthFindings[i]
      var entries = f.entries || []
      for (var j = 0; j < entries.length; j++) {
        var others = entries.filter(function(e) { return e !== entries[j] })
        out.push({ lead: glyph[f.kind] || keyGlyph, title: String(entries[j]), kind: String(f.kind), entry: String(entries[j]),
                   subtitle: String(f.detail || "") + (others.length > 0 ? "  ·  same as " + others.slice(0, 3).join(", ") + (others.length > 3 ? " +" + (others.length - 3) : "") : "") })
      }
    }
    return out
  }

  // The vault being added or edited. Its sync fields live in the text
  // fields and toggles below until Apply writes them back.
  property var draft: normalizeVault({ id: "personal", name: "Personal" }, true)
  property bool draftIsNew: false
  property int vaultIndex: 0
  property string removeConfirm: ""

  property var depSelected: []
  property int depIndex: 0

  property var gpgKeys: []
  property int gpgIndex: 0
  property var selectedGpg: []         // fingerprints
  property bool gpgImporting: false
  property bool gpgExporting: false
  property string gpgExportKind: ""    // "secret" | "public"
  property bool exportAcknowledged: false
  property bool importDeleteFile: true
  property string gpgImportKind: ""    // "secret" (private) | "public"
  property var importInspect: ({})
  property var importDefaults: ({})

  property bool reencryptOffered: false

  property string setupBackend: "local"
  property int syncIndex: 0
  property string setupRcloneMode: "copy"
  property bool setupGitPull: true
  property bool setupGitSign: false
  property bool setupRclonePull: true
  property string syncConfirm: ""

  readonly property var backendRows: [
    { key: "local", title: "Local only", subtitle: "Nothing leaves this machine" },
    { key: "git", title: "git", subtitle: "pass git push after a change, pull --rebase on open" },
    { key: "rclone", title: "rclone", subtitle: "Copy the store to a remote you have configured with rclone config" },
    { key: "custom", title: "Custom commands", subtitle: "Your own push and pull, run in the store with $STORE set" }
  ]

  // The hub's rows: every vault, then "add".
  readonly property var vaultRows: {
    var out = []
    for (var i = 0; i < vaults.length; i++) {
      var v = vaults[i]
      out.push({ kind: "vault", vault: v, title: v.name,
                 subtitle: (v.storeDir !== "" ? v.storeDir : "~/.password-store") + "  ·  " + v.syncBackend
                   + (v.legacy ? "  ·  not saved as a vault yet" : ""),
                 trail: v.id === activeVaultId ? "active" : "" })
    }
    out.push({ kind: "add", vault: null, title: "Add a vault", subtitle: "Another store: a shared team vault, a work vault…", trail: "" })
    return out
  }

  readonly property var depRows: {
    var d = status && status.deps ? status.deps : {}
    var defs = [
      { key: "pass", label: "pass", note: "the password manager", required: true },
      { key: "gnupg", label: "gnupg", note: "encryption", required: true },
      { key: "git", label: "git", note: "for the git backend", required: false },
      { key: "rclone", label: "rclone", note: "for the rclone backend", required: false },
      { key: "pass-otp", label: "pass-otp", note: "OTP codes", required: false },
      { key: "wtype", label: "wtype", note: "typing into windows", required: false }
    ]
    for (var i = 0; i < defs.length; i++) {
      defs[i].present = !!d[defs[i].key]
      defs[i].selected = depSelected.indexOf(defs[i].key) >= 0
    }
    return defs
  }
  readonly property bool requiredDepsMissing: {
    var d = status && status.deps ? status.deps : null
    return !d || !d.pass || !d.gnupg
  }

  readonly property bool storeExists: !!(status && status.storeExists && Array.isArray(status.gpgIds) && status.gpgIds.length > 0)
  readonly property string storeKeyLabel: {
    var ids = status && Array.isArray(status.gpgIds) ? status.gpgIds : []
    return ids.join(", ")
  }
  readonly property string selectedGpgLabel: {
    var names = []
    for (var k = 0; k < gpgKeys.length; k++)
      if (selectedGpg.indexOf(gpgKeys[k].fpr) >= 0) names.push(gpgKeys[k].uid || gpgKeys[k].fpr)
    return names.join(", ")
  }
  readonly property bool selectedGpgHasSecret: {
    for (var k = 0; k < gpgKeys.length; k++)
      if (selectedGpg.indexOf(gpgKeys[k].fpr) >= 0 && gpgKeys[k].secret) return true
    return false
  }

  // A first run goes straight to the vault page; a configured seat gets the
  // hub. -1 asks for that choice.
  function enterSetup(step) {
    mode = "setup"
    setupError = ""
    setupNote = ""
    syncConfirm = ""
    removeConfirm = ""
    reencryptOffered = false
    gpgImporting = false
    gpgImportKind = ""
    importInspect = {}
    gpgExporting = false
    gpgExportKind = ""
    exportAcknowledged = false
    if (step < 0) {
      if (!storeUsable && !vaultsOnRecord) { beginDraft(activeVault, false); step = requiredDepsMissing ? 2 : 1 }
      else step = 0
    }
    for (var i = 0; i < vaults.length; i++) if (vaults[i].id === activeVaultId) vaultIndex = i
    goToStep(step)
    runSetup("gpg-list", [], "", draft)
  }

  function leaveSetup() {
    mode = "search"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Load a vault (or a fresh one) into the wizard's fields.
  function beginDraft(vault, isNew) {
    draftIsNew = isNew
    draft = vault
    vaultNameField.text = vault.name
    vaultDirField.text = vault.storeDir !== "" ? vault.storeDir : defaultDirFor(vault.id)
    selectedGpg = vault.gpgIds.slice()
    setupBackend = vault.syncBackend
    for (var i = 0; i < backendRows.length; i++) if (backendRows[i].key === setupBackend) syncIndex = i
    setupRcloneMode = vault.rcloneMode
    setupGitPull = vault.gitPullOnOpen
    setupGitSign = !!vault.gitSign
    setupRclonePull = vault.rclonePullOnOpen
    gitRemoteField.text = vault.gitRemote
    rcloneRemoteField.text = vault.rcloneRemote
    pushCmdField.text = vault.syncPushCmd
    pullCmdField.text = vault.syncPullCmd
    reencryptOffered = false
    if (!isNew) runSetup("status", [], "", vault)
    else status = null
    preselectStoreKeys()
  }

  function newDraft() {
    var v = normalizeVault({ id: "", name: "" }, false)
    v.id = ""
    v.name = ""
    beginDraft(v, true)
  }

  // The first vault lives where pass looks by default; a second one gets a
  // sibling directory, ~/.password-store-shared being the usual case.
  function defaultDirFor(id) {
    if (id === "personal") return "~/.password-store"
    if (id !== "") return "~/.password-store-" + id
    for (var i = 0; i < vaults.length; i++)
      if (vaults[i].storeDir === "~/.password-store-shared") return ""
    return "~/.password-store-shared"
  }

  function slugOf(name) {
    var slug = String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    return slug !== "" ? slug : "vault"
  }

  // The vault page's Enter: name and directory into the draft, id derived
  // for a new vault (unique among those on record).
  function acceptVaultPage() {
    var name = vaultNameField.text.trim()
    var dir = vaultDirField.text.trim()
    if (name === "") { setupError = "Give the vault a name"; return }
    if (dir === "") { setupError = "Where is the store? (a directory; ~ is fine)"; return }
    var d = Object.assign({}, draft)
    d.name = name
    d.storeDir = dir
    if (draftIsNew) {
      var base = slugOf(name)
      var id = base
      for (var n = 2; vaultById(id) !== null; n++) id = base + "-" + n
      d.id = id
      for (var i = 0; i < vaults.length; i++) {
        if (vaults[i].storeDir === dir || (vaults[i].storeDir === "" && dir === "~/.password-store")) {
          setupError = "That directory is already vault “" + vaults[i].name + "”"; return
        }
      }
    }
    draft = d
    runSetup("status", [], "", d)
    goToStep(requiredDepsMissing ? 2 : 3)
  }

  function goToStep(step) {
    setupStep = Math.max(0, Math.min(stepTitles.length - 1, step))
    setupError = ""
    syncConfirm = ""
    removeConfirm = ""
    focusSetupPage()
  }

  function focusSetupPage() {
    Qt.callLater(function() {
      if (root.setupStep === 1) vaultNameField.forceActiveFocus()
      else if (root.setupStep === 3 && root.gpgImporting) importPathField.forceActiveFocus()
      else if (root.setupStep === 3 && root.gpgExporting) exportPathField.forceActiveFocus()
      else if (root.setupStep === 5 && root.setupBackend === "git") gitRemoteField.forceActiveFocus()
      else if (root.setupStep === 5 && root.setupBackend === "rclone") rcloneRemoteField.forceActiveFocus()
      else if (root.setupStep === 5 && root.setupBackend === "custom") pushCmdField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  function setupBack() {
    if (setupBusy !== "") return
    if (setupStep === 6) { goToStep(0); return }
    if (setupStep === 3 && gpgImporting) { gpgImporting = false; gpgImportKind = ""; importInspect = {}; focusSetupPage(); return }
    if (setupStep === 3 && gpgExporting) { gpgExporting = false; gpgExportKind = ""; focusSetupPage(); return }
    if (setupStep === 1) { if (vaultsOnRecord || storeUsable) goToStep(0); return }
    if (setupStep === 3 && !requiredDepsMissing) { goToStep(1); return }
    if (setupStep > 0) goToStep(setupStep - 1)
  }

  function setupCancel() {
    if (setupBusy !== "") return
    if (setupStep === 3 && gpgImporting) { gpgImporting = false; gpgImportKind = ""; importInspect = {}; focusSetupPage(); return }
    if (setupStep === 3 && gpgExporting) { gpgExporting = false; gpgExportKind = ""; focusSetupPage(); return }
    if (syncConfirm !== "") { syncConfirm = ""; return }
    if (removeConfirm !== "") { removeConfirm = ""; return }
    if (setupStep > 0 && (vaultsOnRecord || storeUsable)) { goToStep(0); return }
    if (storeUsable) leaveSetup()
    else dismiss()
  }

  // Enter, or the primary button, on each page.
  function setupPrimary() {
    if (setupBusy !== "") return
    switch (setupStep) {
      case 0:
        if (removeConfirm !== "") { removeVault(removeConfirm); break }
        if (vaultIndex >= 0 && vaultIndex < vaultRows.length) {
          var row = vaultRows[vaultIndex]
          if (row.kind === "add") newDraft()
          else beginDraft(row.vault, false)
          goToStep(1)
        }
        break
      case 1:
        acceptVaultPage()
        break
      case 2:
        if (depSelected.length > 0) installSelected()
        else if (!requiredDepsMissing) goToStep(3)
        break
      case 6:
        if (healthRows.length > 0) openHealthEntry(healthIndex); else runHealth()
        break
      case 3:
        if (gpgImporting) { importKey(); break }
        if (gpgExporting) { exportKey(); break }
        if (selectedGpg.length === 0 && gpgIndex >= 0 && gpgIndex < gpgKeys.length) toggleGpg(gpgIndex)
        if (selectedGpg.length === 0) { setupError = "Pick at least one key (Space)"; break }
        if (!selectedGpgHasSecret) { setupError = "One of the keys must have its secret part here, or nothing could be decrypted"; break }
        goToStep(4)
        break
      case 4:
        if (storeExists && !reencryptOffered) goToStep(5)
        else if (storeExists && reencryptOffered) goToStep(5)
        else if (selectedGpg.length > 0) runInit(false)
        break
      case 5:
        applySync(syncConfirm !== "")
        break
    }
  }

  function runInit(reencrypt) {
    var args = []
    for (var i = 0; i < selectedGpg.length; i++) args.push("--gpg-id", selectedGpg[i])
    if (reencrypt) args.push("--reencrypt")
    runSetup("init", args, reencrypt ? "Re-encrypting the store…" : "Running pass init…", draft)
  }

  function installSelected() {
    if (depSelected.length === 0) return
    runSetup("install", depSelected, "Installing in the terminal… (sudo may ask for your password)", draft)
  }

  function toggleDep(index) {
    if (index < 0 || index >= depRows.length) return
    var row = depRows[index]
    if (row.present) return
    var next = depSelected.slice()
    var at = next.indexOf(row.key)
    if (at >= 0) next.splice(at, 1); else next.push(row.key)
    depSelected = next
  }

  function toggleGpg(index) {
    if (index < 0 || index >= gpgKeys.length) return
    var fpr = gpgKeys[index].fpr
    var next = selectedGpg.slice()
    var at = next.indexOf(fpr)
    if (at >= 0) next.splice(at, 1); else next.push(fpr)
    selectedGpg = next
    setupError = ""
  }

  function importKey() {
    var path = importPathField.text.trim()
    if (path === "") { setupError = "Type the path of the key file"; return }
    var busy = gpgImportKind === "public"
      ? "Importing a public key…"
      : "Importing a private key… (pinentry may ask for its passphrase)"
    runSetup("gpg-import", ["--file", path].concat(gpgImportKind === "secret" && importDeleteFile ? ["--delete"] : []), busy, draft)
  }

  function beginImport(kind) {
    if (!kind) {
      var hasSecret = false
      for (var k = 0; k < gpgKeys.length; k++) if (gpgKeys[k].secret) { hasSecret = true; break }
      kind = hasSecret ? "public" : "secret"
    }
    gpgImporting = true
    gpgImportKind = kind
    importInspect = {}
    setupError = ""
    importPathField.text = ""
    runSetup("gpg-inspect", [], "", draft)
    focusSetupPage()
  }

  // Export: the warning page first (the secret one has to be acknowledged),
  // then gpg --export into the path given, through passwordstore-setup.
  readonly property var cursorKey: gpgKeys.length > 0 && gpgIndex >= 0 && gpgIndex < gpgKeys.length ? gpgKeys[gpgIndex] : null
  function beginExport(kind) {
    if (!cursorKey) { setupError = "Pick a key first"; return }
    if (kind === "secret" && !cursorKey.secret) { setupError = "That key has no secret part here"; return }
    gpgExporting = true
    gpgExportKind = kind
    exportAcknowledged = false
    setupError = ""
    setupNote = ""
    var short = String(cursorKey.fpr || "").slice(-16)
    exportPathField.text = kind === "secret" ? "~/" + short + ".secret.asc" : "~/Documents/" + short + ".public.asc"
    focusSetupPage()
  }

  function exportKey() {
    if (!gpgExporting || !cursorKey) return
    var path = String(exportPathField.text).trim()
    if (path === "") { setupError = "Where should the file go?"; return }
    if (gpgExportKind === "secret" && !exportAcknowledged) { setupError = "Acknowledge the warning first (Space)"; return }
    setupError = ""
    // Busy: the card hides and drops its grab, so pinentry can ask for the
    // secret key's passphrase, and Esc cannot half-abandon the write.
    runSetup("gpg-export", ["--kind", gpgExportKind, "--gpg-id", String(cursorKey.fpr), "--file", path],
             gpgExportKind === "secret" ? "Writing the private key (pinentry may ask)…" : "Writing the public key…", draft)
  }

  function inspectImportPath() {
    if (!gpgImporting) return
    var path = importPathField.text.trim()
    if (path === "") { importInspect = {}; return }
    runSetup("gpg-inspect", ["--file", path], "", draft)
  }

  readonly property string importKindLabel: {
    var k = importInspect && importInspect.kind ? String(importInspect.kind) : ""
    if (k === "secret") return "Private (secret) key — this seat can decrypt with it."
    if (k === "public") return "Public key — recipient only; this seat cannot decrypt with it."
    if (k === "missing") return "No file at that path yet."
    if (k === "unknown") return "Could not tell whether this is a public or private key."
    return ""
  }
  readonly property bool importKindMismatch: {
    var k = importInspect && importInspect.kind ? String(importInspect.kind) : ""
    return (k === "secret" || k === "public") && gpgImportKind !== "" && k !== gpgImportKind
  }

  // The passphrase prompt gpg-agent uses: pinentry-omarchy (the shell's
  // look) or whatever gpg-agent.conf names. Toggled from the GPG page.
  readonly property string pinentryState: status && status.pinentry ? String(status.pinentry) : ""
  function togglePinentry() {
    // Switching prompts while locked would be the way around the lock.
    if (locked) { setupError = "Locked for " + formatRemaining(lockoutRemaining) + "; the prompt cannot be changed now"; return }
    runSetup("pinentry", [pinentryState === "omarchy" ? "--disable" : "--enable"], "", draft)
  }

  function generateKey() {
    runSetup("gpg-generate", [], "Waiting for gpg --full-generate-key in the terminal…", draft)
  }

  function reencrypt() {
    if (selectedGpg.length === 0 || !reencryptOffered) return
    runInit(true)
  }

  function removeVault(id) {
    removeConfirm = ""
    var remaining = []
    for (var i = 0; i < vaults.length; i++) if (vaults[i].id !== id) remaining.push(vaults[i])
    var nextActive = activeVaultId === id ? (remaining.length > 0 ? remaining[0].id : "") : activeVaultId
    var error = saveVaults(remaining, nextActive)
    if (error !== "") { setupError = error; return }
    setupNote = "Vault record removed; its directory was left alone"
    vaultIndex = 0
  }

  function makeActive(id) {
    var error = saveSetting("activeVaultId", id)
    if (error !== "") { setupError = error; return }
    activeOverride = ""
    setupNote = "Active vault: " + (vaultById(id) ? vaultById(id).name : id)
  }

  // Sync page's Enter: the draft, sync fields included, onto the record,
  // then the backend's first-time wiring.
  function applySync(confirmed) {
    var b = setupBackend
    var d = Object.assign({}, draft)
    d.syncBackend = b
    d.gitRemote = gitRemoteField.text.trim()
    d.gitPullOnOpen = setupGitPull
    d.gitSign = setupGitSign
    d.rcloneRemote = rcloneRemoteField.text.trim()
    d.rcloneMode = setupRcloneMode
    d.rclonePullOnOpen = setupRclonePull
    d.syncPushCmd = pushCmdField.text.trim()
    d.syncPullCmd = pullCmdField.text.trim()
    d.gpgIds = selectedGpg.length > 0 ? selectedGpg.slice()
      : (status && Array.isArray(status.gpgIds) ? status.gpgIds.map(String) : [])
    d.legacy = false
    if (b === "git" && d.gitRemote === "") { setupError = "A remote URL is needed"; return }
    if (b === "rclone" && d.rcloneRemote === "") { setupError = "An rclone remote path is needed"; return }
    if (b === "custom" && d.syncPushCmd === "") { setupError = "A push command is needed"; return }

    var list = []
    var replaced = false
    for (var i = 0; i < vaults.length; i++) {
      if (vaults[i].id === d.id) { list.push(d); replaced = true }
      else if (!vaults[i].legacy) list.push(vaults[i])
    }
    if (!replaced) list.push(d)
    // A vault just set up is the one to search; an edit keeps the active one.
    var nextActive = draftIsNew || !vaultsOnRecord ? d.id : activeVaultId
    var error = saveVaults(list, nextActive)
    if (error !== "") { setupError = error; return }
    draft = d
    draftIsNew = false

    var args = ["--backend", b]
    if (b === "git") args.push("--git-remote", d.gitRemote)
    if (b === "rclone") args.push("--rclone-remote", d.rcloneRemote, "--rclone-mode", d.rcloneMode)
    if (b === "custom") args.push("--push-cmd", d.syncPushCmd, "--pull-cmd", d.syncPullCmd)
    if (confirmed) args.push("--confirm")
    var busy = b === "git" ? "Talking to the remote in the terminal…"
      : b === "rclone" ? "rclone is running in the terminal…"
      : ""
    runSetup("sync-setup", args, busy, d)
  }

  function finishSetup(detail) {
    syncNote = detail
    leaveSetup()
    filterText = ""
    selectedIndex = 0
    refresh()
    runSetup("status", [], "", activeVault)
  }

  function chooseBackend(index) {
    syncIndex = Math.max(0, Math.min(backendRows.length - 1, index))
    setupBackend = backendRows[syncIndex].key
    setupError = ""
    syncConfirm = ""
    focusSetupPage()
  }

  // Keys while the wizard is up. Text fields consume what they need first;
  // only what they ignore (Esc, Up/Down, Alt+arrows) reaches here.
  function setupKey(event) {
    var alt = event.modifiers & Qt.AltModifier
    var ctrl = event.modifiers & Qt.ControlModifier
    // Only a text input counts as "in a field": a Toggle or a button that
    // happens to hold focus must not swallow the page's letter keys.
    var focusItem = panel.activeFocusItem
    var inField = focusItem !== null && focusItem !== keyCatcher && focusItem.cursorPosition !== undefined
    if (event.key === Qt.Key_Escape) { setupCancel(); return true }
    if (event.key === Qt.Key_Left && alt) { setupBack(); return true }
    if (event.key === Qt.Key_Right && alt) { setupPrimary(); return true }
    if (event.key === Qt.Key_F5 && setupStep === 3) { runSetup("gpg-list", [], "", draft); return true }
    if (setupBusy !== "") return false
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { setupPrimary(); return true }
    if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) { moveCursor(1); return true }
    if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) { moveCursor(-1); return true }
    if (inField) return false
    // Single letters are free here: no page of the wizard is type-to-filter.
    var letter = event.text ? event.text.toLowerCase() : ""
    if (setupStep === 0) {
      var row = vaultIndex >= 0 && vaultIndex < vaultRows.length ? vaultRows[vaultIndex] : null
      if (letter === "a") { newDraft(); goToStep(1); return true }
      if (letter === "h" && row && row.kind === "vault") { beginDraft(row.vault, false); goToStep(6); runHealth(); return true }
      if (letter === "d" && row && row.kind === "vault") { makeActive(row.vault.id); return true }
      if (letter === "x" && row && row.kind === "vault" && !row.vault.legacy) {
        removeConfirm = row.vault.id
        setupNote = ""
        return true
      }
    }
    if (setupStep === 2 && event.key === Qt.Key_Space) { toggleDep(depIndex); return true }
    if (setupStep === 2 && letter === "s" && !requiredDepsMissing) { goToStep(3); return true }
    if (setupStep === 3 && event.key === Qt.Key_Space && !gpgImporting && !gpgExporting) { toggleGpg(gpgIndex); return true }
    if (setupStep === 3 && letter === "g" && !gpgImporting && !gpgExporting) { generateKey(); return true }
    if (setupStep === 3 && letter === "i" && !gpgImporting && !gpgExporting) { beginImport("secret"); return true }
    if (setupStep === 3 && letter === "u" && !gpgImporting && !gpgExporting) { beginImport("public"); return true }
    if (setupStep === 3 && letter === "p" && !gpgImporting && !gpgExporting) { togglePinentry(); return true }
    if (setupStep === 3 && letter === "e" && !gpgImporting && !gpgExporting) { beginExport("public"); return true }
    if (setupStep === 3 && letter === "x" && !gpgImporting && !gpgExporting) { beginExport("secret"); return true }
    // Space toggles the acknowledge / delete switch unless a field has it.
    if (setupStep === 3 && gpgExporting && event.key === Qt.Key_Space && !inField) { exportAcknowledged = !exportAcknowledged; return true }
    if (setupStep === 3 && gpgImporting && event.key === Qt.Key_Space && !inField) { importDeleteFile = !importDeleteFile; return true }
    if (setupStep === 4 && letter === "r") { reencrypt(); return true }
    if (setupStep === 5 && letter === "p") { togglePull(); return true }
    if (setupStep === 5 && letter === "k" && setupBackend === "git") { setupGitSign = !setupGitSign; return true }
    if (setupStep === 5 && letter === "m" && setupBackend === "rclone") {
      setupRcloneMode = setupRcloneMode === "copy" ? "sync" : "copy"; return true
    }
    if (setupStep === 5 && letter >= "1" && letter <= "4") { chooseBackend(parseInt(letter, 10) - 1); return true }
    if (setupStep === 6 && letter === "r") { runHealth(); return true }
    if (setupStep === 6 && letter === "b") { saveSetting("healthHibp", !healthHibp); return true }
    return false
  }

  function moveCursor(delta) {
    if (setupStep === 0) { vaultIndex = Math.max(0, Math.min(vaultRows.length - 1, vaultIndex + delta)); removeConfirm = "" }
    else if (setupStep === 2) depIndex = Math.max(0, Math.min(depRows.length - 1, depIndex + delta))
    else if (setupStep === 3 && !gpgImporting && !gpgExporting) gpgIndex = Math.max(0, Math.min(gpgKeys.length - 1, gpgIndex + delta))
    else if (setupStep === 5) chooseBackend(syncIndex + delta)
    else if (setupStep === 6) healthIndex = Math.max(0, Math.min(healthRows.length - 1, healthIndex + delta))
  }

  function togglePull() {
    if (setupBackend === "git") setupGitPull = !setupGitPull
    else if (setupBackend === "rclone") setupRclonePull = !setupRclonePull
  }

  readonly property string setupPrimaryLabel: {
    switch (setupStep) {
      case 0:
        if (removeConfirm !== "") return "Yes, forget it"
        return vaultIndex < vaultRows.length && vaultRows[vaultIndex].kind === "add" ? "Add" : "Edit"
      case 1: return "Next"
      case 2: return depSelected.length > 0 ? "Install selected" : "Next"
      case 3: return gpgImporting
        ? (gpgImportKind === "public" ? "Import public key" : "Import private key")
        : (gpgExporting ? (gpgExportKind === "public" ? "Export public key" : "Export private key") : "Use selected")
      case 4: return storeExists ? "Next" : "Create store"
      case 6: return healthRows.length > 0 ? "Open entry" : "Check again"
      default: return syncConfirm !== "" ? "Yes, upload" : "Apply"
    }
  }
  readonly property bool setupPrimaryEnabled: setupBusy === "" && (
    setupStep === 2 ? (depSelected.length > 0 || !requiredDepsMissing)
    : setupStep === 3 ? (gpgImporting || (gpgExporting ? (gpgExportKind !== "secret" || exportAcknowledged) : gpgKeys.length > 0))
    : setupStep === 4 ? (storeExists || selectedGpg.length > 0)
    : true)

  readonly property string setupHint: {
    switch (setupStep) {
      case 0: return "↑↓ choose  ·  Enter edit  ·  A add  ·  D make active  ·  H health check  ·  X forget"
      case 6: return "↑↓ move  ·  Enter open the entry  ·  R check again  ·  B breach check " + (healthHibp ? "on" : "off") + "  ·  Esc vaults"
      case 1: return "Tab between fields  ·  Enter next"
      case 2: return "Space select  ·  Enter install  ·  S skip"
      case 3: return gpgImporting
        ? "Enter import  ·  Space delete the file afterwards  ·  Esc back to the list"
        : gpgExporting ? (gpgExportKind === "secret" ? "Space acknowledge  ·  Enter export  ·  Esc back" : "Enter export  ·  Esc back")
        : "↑↓ move  ·  Space select  ·  Enter continue  ·  G generate  ·  I/U import private/public  ·  X/E export private/public  ·  P prompt  ·  F5 rescan"
      case 4: return reencryptOffered ? "Enter keep the store's keys  ·  R re-encrypt" : "Enter continue"
      default: return "1–4 or ↑↓ backend  ·  Tab fields  ·  P pull on open" + (setupBackend === "rclone" ? "  ·  M copy/sync" : "") + "  ·  Enter apply"
    }
  }

  // --- the card ---------------------------------------------------------

  // Every Text that can show an entry name, the query or helper output is
  // PlainText. Qt's default AutoText sniffs for HTML, and a store entry named
  // like <img src="…"> (a synced store is not necessarily one's own doing)
  // would otherwise be rendered as rich text and fetch what it points at.

  readonly property string hintText: {
    var hints = ["Enter copy password", "Alt+U username"]
    if (otpAvailable) hints.push("Alt+O OTP")
    if (allowTyping) hints.push("Alt+Enter autofill", "Ctrl+Enter type")
    hints.push("→ more", "Alt+E edit", "Alt+N new")

    if (allowTyping) hints.push("Ctrl+Enter type")
    hints.push("Alt+E edit", "Alt+N new", "Alt+S share")
    if (activeVault.syncBackend === "git") hints.push("Alt+H history")
    if (vaults.length > 1) hints.push("Tab vault")
    hints.push("F2 setup")
    var line = hints.join("  ·  ")
    if (syncNote !== "") line += "\n" + syncNote
    if (status && status.secretKeyPresent === false)
      line += "\nNo secret key for " + storeKeyLabel + " in this keyring (F2)"
    if (locked) line += "\nLocked after too many wrong passphrases  ·  " + formatRemaining(lockoutRemaining)
    if (autofillAsked && selectedEntry) line += "\nAlt+Enter again types " + selectedEntry.name + " into “" + windowTitleBare + "”"
    return line
  }

  component SetupText: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // A selectable line, drawn like a result row.
  component ChoiceRow: BorderSurface {
    id: choice
    property bool hasCursor: false
    property string lead: ""
    property string title: ""
    property string subtitle: ""
    property string trail: ""
    property bool dim: false
    signal picked()
    signal hoveredRow()

    width: parent ? parent.width : implicitWidth
    height: root.rowHeight
    radius: root.cornerRadius
    color: hasCursor ? root.selectedBackground : "transparent"
    borderSpec: hasCursor ? root.selectedBorderSpec : Border.none()
    opacity: dim ? 0.55 : 1

    Text {
      id: leadText
      text: choice.lead
      textFormat: Text.PlainText
      color: choice.hasCursor ? root.selectedText : root.foreground
      opacity: choice.hasCursor ? 1 : 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
      width: Style.space(36)
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      anchors.left: parent.left
      anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      anchors.left: leadText.right
      anchors.leftMargin: Style.space(6)
      anchors.right: trailText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: choice.title
        textFormat: Text.PlainText
        color: choice.hasCursor ? root.selectedText : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.weight: Font.Medium
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: choice.subtitle !== ""
        text: choice.subtitle
        textFormat: Text.PlainText
        color: choice.hasCursor ? root.selectedText : root.foreground
        opacity: 0.52
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }

    Text {
      id: trailText
      anchors.right: parent.right
      anchors.rightMargin: root.rowReservedBorderRight + Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: choice.trail
      textFormat: Text.PlainText
      width: choice.trail !== "" ? implicitWidth : 0
      color: choice.hasCursor ? root.selectedText : root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) choice.hoveredRow()
      onClicked: choice.picked()
    }
  }

  component CardField: TextField {
    width: parent ? parent.width : implicitWidth
    foreground: root.foreground
    accent: root.selectedBackground
    font.family: root.fontFamily
  }

  component CardButton: Button {
    foreground: root.foreground
    accent: root.selectedBackground
    fontFamily: root.fontFamily
    bordered: true
  }

  component EditLabel: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    topPadding: Style.space(2)
  }

  // A field of the editor: the editor's keys (Esc, Ctrl+Enter, Alt+R,
  // Alt+G) are answered before the field sees them, everything else is
  // typed into it.
  component EditField: CardField {
    Keys.onPressed: function(event) {
        root.noteUse(); if (root.editKey(event)) event.accepted = true }
  }

  PanelWindow {
    id: panel
    // Hide and drop the exclusive grab while a helper terminal is running
    // (gpg --full-generate-key, pkg add, first git/rclone push). Otherwise
    // the fullscreen layer eats keys and clicks meant for that terminal or
    // for whatever app is behind the scrim.
    visible: root.opened && root.setupBusy === "" && !root.editReading && !root.shareReading && !root.otpScanning && !root.otpBusy
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-passwordstore"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: (root.opened && root.setupBusy === "" && !root.editReading && !root.shareReading && !root.otpScanning && !root.otpBusy)
      ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }
      onWidthChanged: geometryTimer.restart()
      onHeightChanged: geometryTimer.restart()
      onXChanged: geometryTimer.restart()
      onYChanged: geometryTimer.restart()

      // Wizard keys arrive here after the focused text field, if any, has
      // had its turn; keyCatcher below lets them through in setup mode.
      Keys.onPressed: function(event) {
        root.noteUse()
        if (root.mode === "setup") { if (root.setupKey(event)) event.accepted = true }
        else if (root.mode === "edit") { if (root.editKey(event)) event.accepted = true }
        else if (root.mode === "share") { if (root.shareKey(event)) event.accepted = true }
        else if (root.mode === "history") { if (root.historyKey(event)) event.accepted = true }
      }

      // Type-to-filter, as the menu does: there is no text field to focus,
      // every printable key extends the query. That rules out single-letter
      // shortcuts, so actions are Enter and modifier combinations.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
        root.noteUse()
          if (root.mode !== "search") return
          var ctrl = event.modifiers & Qt.ControlModifier
          var alt = event.modifiers & Qt.AltModifier
          var shift = event.modifiers & Qt.ShiftModifier

          if (root.menuOpen) {
            root.menuKey(event)
            event.accepted = true   // nothing falls through to the list or Qt focus while the menu is up
            return
          }
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.openMenu(); event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.matches(StandardKey.Paste) || (shift && event.key === Qt.Key_Insert)) {
            // Ctrl+V, or the Shift+Insert Omarchy's clipboard picker types
            // after Super+V: the search line has no text field to take it.
            root.pasteIntoFilter(); event.accepted = true
          } else if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
            root.select(1); event.accepted = true
          } else if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
            root.select(-1); event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(root.maxVisibleRows); event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-root.maxVisibleRows); event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0); event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(root.rows.length - 1); event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.switchVault(event.key === Qt.Key_Backtab || shift ? -1 : 1); event.accepted = true
          } else if (event.key === Qt.Key_F5) {
            root.refresh(); event.accepted = true
          } else if (event.key === Qt.Key_F2 || (ctrl && event.key === Qt.Key_Comma)) {
            root.enterSetup(-1); event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (ctrl && shift) root.activateSelected("type-username")
            else if (ctrl) root.activateSelected("type-password")
            else if (alt) root.activateSelected("autofill")
            else root.activateSelected("copy-password")
            event.accepted = true
          } else if (alt && event.key === Qt.Key_U) {
            root.activateSelected("copy-username"); event.accepted = true
          } else if (alt && event.key === Qt.Key_O) {
            root.activateSelected("copy-otp"); event.accepted = true
          } else if (alt && event.key === Qt.Key_E) {
            root.activateSelected(shift ? "edit-terminal" : "edit"); event.accepted = true
          } else if (alt && event.key === Qt.Key_S) {
            root.openShare(root.selectedEntry); event.accepted = true
          } else if (alt && event.key === Qt.Key_L) {
            root.activateSelected("open-url"); event.accepted = true

          } else if (alt && event.key === Qt.Key_H) {
            root.openHistory(root.selectedEntry); event.accepted = true
          } else if (alt && event.key === Qt.Key_N) {
            root.insertNew("insert"); event.accepted = true
          } else if (alt && event.key === Qt.Key_G) {
            // A new entry with a password already generated.
            root.insertNew("insert"); root.generatePassword(); event.accepted = true
          } else if (!ctrl && !alt && event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      // ---------------------------------------------------------- search

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing
        visible: root.mode === "search"

        // The query line, in the menu's heading style; the vault's name
        // and the count at the right.
        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: countText.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Password…"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }

          Text {
            id: countText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: {
              var count = root.initialized && root.lastError === ""
                ? (root.filterText ? root.rows.length + " / " + root.entries.length : String(root.entries.length))
                : ""
              var name = root.vaults.length > 1 || root.vaultsOnRecord ? root.activeVault.name : ""
              var hint = root.windowMatched && root.preselectArmed ? "for “" + (root.windowTitleBare.length > 28 ? root.windowTitleBare.slice(0, 27) + "…" : root.windowTitleBare) + "”" : ""
              return [hint, name, count].filter(function(s) { return s !== "" }).join("  ·  ")
            }
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Item {
          width: parent.width
          height: root.visibleRowsHeight

          ListView {
            id: resultList
            anchors.fill: parent
            model: root.rows
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selectedIndex

            delegate: BorderSurface {
              id: row

              required property var modelData
              required property int index

              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Text {
                id: iconText
                text: root.keyGlyph
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: row.hasCursor ? 1 : 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: contentColumn
                anchors.left: iconText.right
                anchors.leftMargin: Style.space(6)
                anchors.right: trail.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: row.modelData.title
                  textFormat: Text.PlainText
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideLeft
                }

                Text {
                  width: parent.width
                  visible: row.modelData.subtitle !== ""
                  text: row.modelData.subtitle
                  textFormat: Text.PlainText
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: root.usernameInPath ? Text.ElideRight : Text.ElideLeft
                }
              }

              Text {
                id: trail
                anchors.right: parent.right
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.conflict ? "conflict" : (row.modelData.recent ? root.clockGlyph : "")
                width: text !== "" ? implicitWidth : 0
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  if (root.selectedIndex !== row.index) root.disarmPreselect()
                  root.selectedIndex = row.index
                }
                onClicked: function(mouse) {
                  root.selectedIndex = row.index
                  if (mouse.button === Qt.RightButton) root.runAction("copy-username", row.modelData)
                  else if (mouse.button === Qt.MiddleButton) root.runAction("copy-otp", row.modelData)
                  else root.runAction("copy-password", row.modelData)
                }
              }
            }
          }

          // Empty states: an error from the helper, an empty store, or a
          // query nothing matches.
          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            spacing: Style.space(8)
            visible: root.rows.length === 0

            Text {
              width: parent.width
              text: root.lastError !== "" ? String.fromCodePoint(0xF0306) : "󰈉"
              color: root.lastError !== "" ? Color.urgent : root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.lastError !== ""
                ? root.lastError
                : (!root.initialized
                   ? "Reading the store…"
                   : (root.entries.length === 0
                      ? "The store is empty. Alt+N adds an entry, F2 opens the setup."
                      : "No matches for “" + root.filterText + "”"))
              color: root.lastError !== "" ? Color.urgent : root.foreground
              opacity: root.lastError !== "" ? 1 : 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        // The row menu: the selected entry's actions, keys alongside.
        Column {
          id: menuColumn
          width: parent.width
          spacing: root.rowSpacing
          visible: root.menuOpen

          Repeater {
            model: root.menuOpen ? root.menuRows : []
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              hasCursor: root.menuIndex === index
              lead: ""
              title: modelData.label
              subtitle: ""
              trail: modelData.keys
              onHoveredRow: root.menuIndex = index
              onPicked: root.runMenu(index)
            }
          }
        }

        // Key legend, limited to the actions this configuration offers so a
        // store without pass-otp never advertises Alt+O.
        Text {
          id: footerLabel
          width: parent.width
          text: root.hintText
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---------------------------------------------------------- editor

      Column {
        id: editColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(6)
        visible: root.mode === "edit"

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.right: editVaultText.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.editTitle + (root.editEntry !== "" ? "  ·  " + root.editEntry : "")
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }
          Text {
            id: editVaultText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.activeVault.name
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        EditLabel { text: "Application, website or account" }
        EditField {
          id: nameField
          placeholderText: "github.com"
          KeyNavigation.tab: usernameField
          KeyNavigation.backtab: notesArea
          onAccepted: usernameField.forceActiveFocus()
        }

        EditLabel { text: "Username" }
        EditField {
          id: usernameField
          placeholderText: "jack@example.com"
          KeyNavigation.tab: urlField
          KeyNavigation.backtab: nameField
          onAccepted: urlField.forceActiveFocus()
        }

        EditLabel { text: "URL" }
        EditField {
          id: urlField
          placeholderText: "https://github.com/login"
          KeyNavigation.tab: passwordField
          KeyNavigation.backtab: usernameField
          onAccepted: passwordField.forceActiveFocus()
        }

        EditLabel { text: "Password" }
        Item {
          width: parent.width
          height: Math.max(passwordField.implicitHeight, revealButton.implicitHeight)

          // Masked like the lock screen's field; revealed, the field's own
          // text turns transparent and the coloured copy is drawn over it,
          // in the same monospace font so the two line up glyph for glyph.
          EditField {
            id: passwordField
            anchors.left: parent.left
            anchors.right: revealButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            password: !root.editRevealed
            passwordCharacter: "\u2022"
            font.family: Style.font.family
            color: root.editRevealed ? "transparent" : root.foreground
            selectedTextColor: root.editRevealed ? "transparent" : root.foreground
            placeholderText: root.editReading ? "Decrypting…" : "Type or paste, or generate one"
            cursorDelegate: Rectangle {
              width: Math.max(1, Style.space(1))
              color: root.foreground
              visible: passwordField.cursorVisible
            }
            // Tab skips the generator controls (they are mouse and Alt+G
            // territory) and lands in the notes.
            KeyNavigation.tab: root.editOtp || root.editEntry === "" ? notesArea : otpSecretField
            KeyNavigation.backtab: urlField
            onAccepted: notesArea.forceActiveFocus()
          }
          Text {
            visible: root.editRevealed
            x: passwordField.x + passwordField.leftPadding
            anchors.verticalCenter: passwordField.verticalCenter
            width: Math.max(0, passwordField.width - passwordField.leftPadding - passwordField.rightPadding)
            clip: true
            text: root.colorize(passwordField.text)
            textFormat: Text.RichText
            font.family: passwordField.font.family
            font.pixelSize: passwordField.font.pixelSize
          }
          CardButton {
            id: revealButton
            anchors.right: generateButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.editRevealed ? root.eyeOffGlyph : root.eyeGlyph
            tooltipText: root.editRevealed ? "Hide (Alt+R)" : "Reveal (Alt+R)"
            selected: root.editRevealed
            onClicked: root.editRevealed = !root.editRevealed
          }
          CardButton {
            id: generateButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Generate"
            tooltipText: "Alt+G"
            onClicked: root.generatePassword()
          }
        }

        // Generator options; the class buttons double as the colour legend.
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            label: "Length"
            from: 4
            to: 128
            value: root.genLength
            foreground: root.foreground
            accent: root.selectedBackground
            fontFamily: root.fontFamily
            onModified: function(value) { root.genLength = value }
            Component.onCompleted: field.activeFocusOnTab = false
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "a-z"
            selected: root.genLower
            opacity: root.genLower ? 1 : 0.5
            onClicked: root.genLower = !root.genLower
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "A-Z"
            foreground: root.upperColor
            selected: root.genUpper
            opacity: root.genUpper ? 1 : 0.5
            onClicked: root.genUpper = !root.genUpper
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "0-9"
            foreground: root.digitColor
            selected: root.genDigits
            opacity: root.genDigits ? 1 : 0.5
            onClicked: root.genDigits = !root.genDigits
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "#!?"
            foreground: root.symbolColor
            selected: root.genSymbols
            opacity: root.genSymbols ? 1 : 0.5
            onClicked: root.genSymbols = !root.genSymbols
          }
        }

        EditLabel { text: "One-time code" }
        Item {
          width: parent.width
          height: Math.max(otpCodeText.implicitHeight, otpButtons.implicitHeight, otpSecretField.implicitHeight)
          visible: root.editEntry !== ""

          // With a code: the digits large, in the digit colour, and the
          // seconds it has left; without: scan a QR code or paste the secret.
          Text {
            id: otpCodeText
            visible: root.editOtp
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.otpCode !== "" ? root.colorize(root.otpCode.replace(/(\d{3})(?=\d)/g, "$1 ")) : "······"
            textFormat: Text.RichText
            font.family: Style.font.family
            font.pixelSize: Style.font.display
          }
          Text {
            visible: root.editOtp
            anchors.left: otpCodeText.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.otpCode !== "" ? root.otpRemaining + " s" : ""
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Row {
            id: otpButtons
            visible: root.editOtp
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.controlGap
            CardButton { text: "Copy"; tooltipText: "Onto the clipboard, the card stays"; onClicked: root.otpCopy() }
            CardButton { text: "Remove"; foreground: Color.urgent; onClicked: root.otpRemove() }
          }
          CardField {
            id: otpSecretField
            visible: !root.editOtp
            anchors.left: parent.left
            anchors.right: otpSetupButtons.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Paste the secret (base32) or scan the QR code"
            font.family: Style.font.family
            KeyNavigation.tab: notesArea
            KeyNavigation.backtab: passwordField
            onAccepted: root.otpSet()
            Keys.onPressed: function(event) { if (root.editKey(event)) event.accepted = true }
          }
          Row {
            id: otpSetupButtons
            visible: !root.editOtp
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.controlGap
            CardButton { text: "Set"; selected: otpSecretField.text.trim() !== ""; onClicked: root.otpSet() }
            CardButton { text: "Scan QR"; tooltipText: "Draw a box around the code on screen"; onClicked: root.otpScan() }
          }
        }
        EditLabel {
          visible: root.editEntry === ""
          text: "Save the entry first to add a one-time code"
          opacity: 0.45
        }

        EditLabel { text: "Notes" }
        BorderSurface {
          id: notesSurface
          width: parent.width
          height: Style.space(88)
          radius: Style.cornerRadius
          color: Style.controlFill(notesArea.activeFocus, notesArea.hovered, root.foreground, root.selectedBackground)
          borderSpec: Border.controlSpec(notesArea.activeFocus ? "focus" : (notesArea.hovered ? "hover-cursor" : "normal"), root.foreground, root.selectedBackground)

          Flickable {
            id: notesFlick
            anchors.fill: parent
            anchors.margins: Math.max(1, Style.space(2))
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            QQC.TextArea.flickable: QQC.TextArea {
              id: notesArea
              wrapMode: TextEdit.Wrap
              textFormat: TextEdit.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              selectionColor: root.selectedBackground
              selectedTextColor: root.foreground
              placeholderText: "Notes, recovery codes, anything else"
              placeholderTextColor: Qt.darker(root.foreground, 1.6)
              leftPadding: Style.spacing.controlPaddingX
              rightPadding: Style.spacing.controlPaddingX
              topPadding: Style.spacing.inputPaddingY
              bottomPadding: Style.spacing.inputPaddingY
              background: null
              // Tab is a field hop here, not a character.
              Keys.onPressed: function(event) {
        root.noteUse()
                if (event.key === Qt.Key_Tab) { nameField.forceActiveFocus(); event.accepted = true }
                else if (event.key === Qt.Key_Backtab) { passwordField.forceActiveFocus(); event.accepted = true }
                else if (root.editKey(event)) event.accepted = true
              }
            }
            QQC.ScrollBar.vertical: QQC.ScrollBar {}
          }
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: {
            var bits = []
            if (root.editCreated !== "") bits.push("Created " + root.formatStamp(root.editCreated))
            if (root.editModified !== "") bits.push("Modified " + root.formatStamp(root.editModified))
            if (root.editExtra.length > 0) {
              var keys = root.editExtra.map(function(l) { return l.split(":")[0] })
              bits.push("Kept as is: " + keys.join(", "))
            }
            return bits.join("  ·  ")
          }
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.editError !== "" || root.deleteConfirm
          text: root.deleteConfirm
            ? "Delete " + root.editEntry + "? It is removed from this vault" + (root.syncActive ? " and pushed" : "") + "; pass keeps no copy."
            : root.editError
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Legend full width, then Cancel / Save, as the setup pages do.
        Column {
          width: parent.width
          spacing: Style.space(8)
          topPadding: Style.space(4)

          Text {
            id: editHint
            width: parent.width
            text: root.deleteConfirm
              ? "Enter delete  ·  Esc keep"
              : "Tab fields  ·  Ctrl+Enter save  ·  Alt+R reveal  ·  Alt+G generate" + (root.editEntry !== "" ? "  ·  Alt+D delete" : "") + "  ·  Esc back"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Item {
            width: parent.width
            height: editButtons.implicitHeight

            CardButton {
              anchors.left: parent.left
              visible: root.editEntry !== "" && !root.deleteConfirm
              text: "Delete"
              foreground: Color.urgent
              onClicked: root.askDelete()
            }
            Row {
              id: editButtons
              anchors.right: parent.right
              spacing: Style.spacing.controlGap

              CardButton {
                text: root.deleteConfirm ? "Keep" : "Cancel"
                onClicked: root.deleteConfirm ? (root.deleteConfirm = false) : root.leaveEditor()
              }
              CardButton {
                visible: root.deleteConfirm
                text: "Yes, delete"
                foreground: Color.urgent
                selected: true
                onClicked: root.deleteEntry()
              }
              CardButton {
                visible: !root.deleteConfirm
                text: root.editEntry !== "" ? "Save" : "Add"
                selected: root.editCanSave
                opacity: root.editCanSave ? 1 : 0.5
                onClicked: root.saveEntry()
              }
            }
          }
        }
      }

      // --------------------------------------------------------- history

      Column {
        id: historyColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.rowSpacing
        visible: root.mode === "history"

        Item {
          width: parent.width
          height: root.headerHeight
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "History  ·  " + root.historyEntry
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }
        }
        SetupText {
          text: root.historyBusy ? "Reading…" : (root.historyCommits.length === 0 && root.historyError === "" ? "No commits for this entry." : "Every change pass committed, newest first. Enter restores a version as a new commit (nothing is rewritten).")
          opacity: 0.7
          bottomPadding: Style.space(4)
        }
        Repeater {
          model: root.historyCommits
          delegate: ChoiceRow {
            required property var modelData
            required property int index
            hasCursor: root.historyIndex === index
            lead: root.clockGlyph
            title: String(modelData.subject || "")
            subtitle: String(modelData.author || "") + "  ·  " + root.formatStamp(String(modelData.date || ""))
            trail: root.historyConfirm === String(modelData.sha) ? "Enter again to restore" : String(modelData.sha || "").slice(0, 7)
            onHoveredRow: root.historyIndex = index
            onPicked: { root.historyIndex = index; root.restoreSelected() }
          }
        }
        Text {
          width: parent.width
          visible: root.historyError !== ""
          text: root.historyError
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          width: parent.width
          text: "↑↓ choose  ·  Enter restore (twice)  ·  Esc back"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          topPadding: Style.space(6)
        }
      }

      // ----------------------------------------------------------- share

      Column {
        id: shareColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(8)
        visible: root.mode === "share"

        Item {
          width: parent.width
          height: root.headerHeight
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Share  ·  " + root.shareEntry
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }
        }

        SetupText {
          visible: root.sharePassphrase === ""
          text: "The entry is encrypted before it leaves this machine, and LocalSend carries the encrypted file. Give the recipient's GPG key fingerprint (not a name or e-mail, which could match someone else's key) to encrypt for them, or leave it empty for a one-time passphrase you read out to them over another channel."
          opacity: 0.7
        }
        EditLabel { visible: root.sharePassphrase === ""; text: "Recipient's key (optional)" }
        CardField {
          id: recipientField
          visible: root.sharePassphrase === ""
          placeholderText: "the recipient's key fingerprint, e.g. 9271 4414 6315 8686 7128 …"
          enabled: !root.shareBusy
          Keys.onPressed: function(event) {
        root.noteUse(); if (root.shareKey(event)) event.accepted = true }
        }

        SetupText {
          visible: root.sharePassphrase !== ""
          text: "Read this passphrase to the recipient over another channel (a call, in person). They decrypt the file with any gpg: gpg --decrypt. It is not kept anywhere."
          opacity: 0.7
        }
        BorderSurface {
          width: parent.width
          height: passphraseText.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          visible: root.sharePassphrase !== ""
          color: Style.controlFill(false, false, root.foreground, root.selectedBackground)
          borderSpec: Border.controlSpec("normal", root.foreground, root.selectedBackground)
          Text {
            id: passphraseText
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            text: root.colorize(root.sharePassphrase)
            textFormat: Text.RichText
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.family: Style.font.family
            font.pixelSize: Style.font.display
          }
        }

        Text {
          width: parent.width
          visible: root.shareError !== ""
          text: root.shareError
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          topPadding: Style.space(4)
          Text {
            width: parent.width
            text: root.shareBusy ? "Encrypting…"
              : (root.sharePassphrase !== "" ? "Enter opens LocalSend's device picker in a terminal; the file is removed when it closes  ·  Esc discard"
                 : "Enter encrypt  ·  Esc back")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            anchors.right: parent.right
            spacing: Style.spacing.controlGap
            CardButton { text: root.sharePassphrase !== "" ? "Discard" : "Cancel"; onClicked: root.leaveShare(true) }
            CardButton {
              text: root.sharePassphrase !== "" ? "Send" : "Encrypt"
              selected: !root.shareBusy
              opacity: root.shareBusy ? 0.5 : 1
              onClicked: root.shareFile === "" ? root.prepareShare() : root.sendShare()
            }
          }
        }
      }

      // ----------------------------------------------------------- setup

      Column {
        id: setupColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing
        visible: root.mode === "setup"

        // Title line: which page, and for which vault.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.right: stepText.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.stepTitles[root.setupStep]
              + (root.setupStep > 1 && root.draft.name !== "" ? "  ·  " + root.draft.name : "")
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
          Text {
            id: stepText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.setupStep === 0 ? "Password Store setup"
              : (root.setupStep === 6 ? root.draft.name : root.setupStep + " / " + (root.stepTitles.length - 2))
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // -- 0. vaults
        Column {
          width: parent.width
          spacing: root.rowSpacing
          visible: root.setupStep === 0

          SetupText {
            text: "Each vault is its own password store: a directory, the keys it is encrypted for, and how it syncs. The card searches the active one; Tab switches."
            opacity: 0.7
            bottomPadding: Style.space(6)
          }

          Repeater {
            model: root.vaultRows
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              hasCursor: root.vaultIndex === index
              lead: modelData.kind === "add" ? root.plusGlyph : root.vaultGlyph
              title: modelData.title
              subtitle: modelData.subtitle
              trail: modelData.trail
              onHoveredRow: root.vaultIndex = index
              onPicked: { root.vaultIndex = index; root.setupPrimary() }
            }
          }
        }

        // -- 1. vault
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.setupStep === 1

          SetupText {
            text: root.draftIsNew
              ? "A name for the vault and the directory that holds it (each vault is its own PASSWORD_STORE_DIR). A shared team vault is usually ~/.password-store-shared."
              : "The vault's name and directory. Moving the directory here does not move the files."
            opacity: 0.7
          }
          CardField {
            id: vaultNameField
            placeholderText: "Name, e.g. Personal or Shared"
            onAccepted: root.setupPrimary()
          }
          CardField {
            id: vaultDirField
            placeholderText: "~/.password-store"
            onAccepted: root.setupPrimary()
          }
          SetupText {
            visible: !root.draftIsNew && root.draft.id !== ""
            text: "id: " + root.draft.id
            opacity: 0.5
          }
        }

        // -- 2. dependencies
        Column {
          width: parent.width
          spacing: root.rowSpacing
          visible: root.setupStep === 2

          SetupText {
            text: root.requiredDepsMissing
              ? "pass and gnupg are needed; the rest are optional. Selected packages are installed with omarchy pkg add in a terminal."
              : "Everything required is installed. Optional packages can be added here too."
            opacity: 0.7
            bottomPadding: Style.space(6)
          }

          Repeater {
            model: root.depRows
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              hasCursor: root.depIndex === index
              lead: modelData.present ? root.checkGlyph : (modelData.selected ? root.boxCheckedGlyph : root.boxGlyph)
              title: modelData.label + (modelData.required ? "" : "  (optional)")
              subtitle: modelData.note
              trail: modelData.present ? "installed" : (modelData.selected ? "install" : "missing")
              dim: modelData.present
              onHoveredRow: root.depIndex = index
              onPicked: { root.depIndex = index; root.toggleDep(index) }
            }
          }
        }

        // -- 3. GPG keys
        Column {
          width: parent.width
          spacing: root.rowSpacing
          visible: root.setupStep === 3

          SetupText {
            visible: !root.gpgImporting && !root.gpgExporting
            text: root.gpgKeys.length > 0
              ? "The store is encrypted for every key you select. One must be yours (secret part here); a shared vault adds teammates' public keys, imported first."
              : "gpg has no key yet. Generate one (gpg asks for a name, an e-mail and a passphrase in a terminal) or import a backup."
            opacity: 0.7
            bottomPadding: Style.space(6)
          }

          Repeater {
            model: root.gpgImporting || root.gpgExporting ? [] : root.gpgKeys
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              readonly property bool picked_: root.selectedGpg.indexOf(modelData.fpr) >= 0
              hasCursor: root.gpgIndex === index
              lead: picked_ ? root.boxCheckedGlyph : root.boxGlyph
              title: modelData.uid || modelData.id
              subtitle: modelData.fpr + (modelData.secret ? "" : "  ·  public key only")
                + (modelData.expired ? "  ·  expired" : "") + (modelData.revoked ? "  ·  revoked" : "")
              trail: modelData.secret ? "secret" : ""
              dim: modelData.expired || modelData.revoked
              onHoveredRow: root.gpgIndex = index
              onPicked: { root.gpgIndex = index; root.toggleGpg(index) }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.gpgImporting

            SetupText {
              text: root.gpgImportKind === "public"
                ? "Public key (recipient). Teammates keep their secret keys; you only import what gpg --export --armor wrote. This seat cannot decrypt with it."
                : "Private (secret) key. This seat will be able to decrypt every entry encrypted for it. Only import a file that came over a channel you trust (LocalSend or scp from your own seat, a USB stick), compare the fingerprint on both ends, and do not leave the file lying around: it is deleted after the import unless you say otherwise. pinentry asks for the passphrase if the file has one."
              opacity: 0.7
            }
            CardField {
              id: importPathField
              placeholderText: root.gpgImportKind === "public" ? "~/public.asc" : "~/secret.asc"
              onAccepted: root.setupPrimary()
              onTextChanged: importInspectTimer.restart()
            }
            Toggle {
              width: parent.width
              visible: root.gpgImportKind === "secret"
              label: "Delete the file after importing"
              description: "shred -u, so the private key does not linger on disk (Space)"
              checked: root.importDeleteFile
              foreground: root.foreground
              accent: root.selectedBackground
              fontFamily: root.fontFamily
              onClicked: root.importDeleteFile = !root.importDeleteFile
            }
            SetupText {
              visible: root.importKindLabel !== ""
              text: (root.importKindMismatch
                ? (root.importInspect.kind === "secret"
                  ? "This file is a private key, not a public key. "
                  : "This file is a public key, not a private key. ")
                : "") + root.importKindLabel
              color: root.importKindMismatch ? Color.urgent : root.foreground
              opacity: 1
            }
          }

          // Export: what the file means comes first; a private key has to
          // be acknowledged before the button does anything.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.gpgExporting

            SetupText {
              text: root.gpgExportKind === "public"
                ? "Public key of " + (root.cursorKey ? (root.cursorKey.uid || root.cursorKey.fpr) : "") + ". Safe to share: it lets others encrypt entries for you (a shared vault) and verify your signatures. It does not let anyone read your vault."
                : "Private (secret) key of " + (root.cursorKey ? (root.cursorKey.uid || root.cursorKey.fpr) : "") + ". Whoever holds this file and its passphrase can read every entry in every vault encrypted for it, forever."
              opacity: 0.8
            }
            SetupText {
              visible: root.gpgExportKind === "secret"
              text: "Copy it only to media you control: a USB stick you keep offline, or straight to your other seat over LocalSend or scp. Never into a git repository, a cloud folder or a chat. Import it on the other seat, then delete the file on both (shred -u). Keep one copy offline as the backup. A path inside a git checkout or a synced folder is refused."
              color: Color.urgent
              opacity: 1
            }
            CardField {
              id: exportPathField
              placeholderText: root.gpgExportKind === "public" ? "~/Documents/key.public.asc" : "~/key.secret.asc"
              onAccepted: root.setupPrimary()
            }
            Toggle {
              width: parent.width
              visible: root.gpgExportKind === "secret"
              label: "I understand what this file can do"
              description: "Required before a private key is written (Space)"
              checked: root.exportAcknowledged
              foreground: root.foreground
              accent: root.selectedBackground
              fontFamily: root.fontFamily
              onClicked: root.exportAcknowledged = !root.exportAcknowledged
            }
          }

          Grid {
            width: parent.width
            columns: 2
            columnSpacing: Style.spacing.controlGap
            rowSpacing: Style.spacing.controlGap
            topPadding: Style.space(8)
            visible: !root.gpgImporting && !root.gpgExporting
            CardButton {
              text: "Generate a key"
              width: (parent.width - parent.columnSpacing) / 2
              onClicked: root.generateKey()
            }
            CardButton {
              text: "Rescan"
              width: (parent.width - parent.columnSpacing) / 2
              onClicked: root.runSetup("gpg-list", [], "", root.draft)
            }
            CardButton {
              text: "Import private key"
              width: (parent.width - parent.columnSpacing) / 2
              onClicked: root.beginImport("secret")
            }
            CardButton {
              text: "Import public key"
              width: (parent.width - parent.columnSpacing) / 2
              onClicked: root.beginImport("public")
            }
            CardButton {
              text: "Export private key"
              width: (parent.width - parent.columnSpacing) / 2
              onClicked: root.beginExport("secret")
            }
            CardButton {
              text: "Export public key"
              width: (parent.width - parent.columnSpacing) / 2
              onClicked: root.beginExport("public")
            }
          }

          // The passphrase prompt: gpg-agent's default is the GNOME one;
          // pinentry-omarchy asks the way the lock screen does.
          Toggle {
            width: parent.width
            visible: !root.gpgImporting && !root.gpgExporting && root.pinentryState !== ""
            label: "Ask for passphrases with Omarchy's prompt"
            description: root.pinentryState === "omarchy" ? "gpg-agent uses pinentry-omarchy (P toggles)"
              : (root.pinentryState === "other" ? "gpg-agent.conf names another pinentry (P switches)" : "gpg-agent's default prompt (P switches)")
            checked: root.pinentryState === "omarchy"
            foreground: root.foreground
            accent: root.selectedBackground
            fontFamily: root.fontFamily
            onClicked: root.togglePinentry()
          }
        }

        // -- 4. init
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.setupStep === 4

          SetupText {
            text: root.storeExists
              ? "There is a store at " + root.storePath + " encrypted for " + root.storeKeyLabel
                + (root.status && root.status.entries !== undefined ? " (" + root.status.entries + " entries)." : ".")
              : "pass init creates " + (root.draft.storeDir !== "" ? root.draft.storeDir : root.storePath)
                + " and encrypts every entry for the selected keys."
          }
          SetupText {
            visible: root.selectedGpgLabel !== ""
            text: "Selected: " + root.selectedGpgLabel
            opacity: 0.7
          }
          SetupText {
            visible: root.storeExists && root.status && root.status.secretKeyPresent === false
            text: "This keyring has no secret key for that id, so entries cannot be decrypted here. Import the key (step 3) or re-encrypt."
            color: Color.urgent
          }
          Row {
            spacing: Style.spacing.controlGap
            visible: root.storeExists && root.selectedGpg.length > 0
            CardButton {
              text: root.reencryptOffered ? "Re-encrypt for the selected keys" : "Re-encrypt for the selected keys instead"
              onClicked: root.reencryptOffered ? root.reencrypt() : root.runInit(false)
            }
          }
        }

        // -- 5. sync
        Column {
          width: parent.width
          spacing: root.rowSpacing
          visible: root.setupStep === 5

          Repeater {
            model: root.backendRows
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              hasCursor: root.syncIndex === index
              lead: String(index + 1)
              title: modelData.title
              subtitle: modelData.subtitle
              trail: root.draft.syncBackend === modelData.key && !root.draftIsNew ? "current" : ""
              onHoveredRow: {}
              onPicked: root.chooseBackend(index)
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            topPadding: Style.space(8)

            SetupText {
              visible: root.setupBackend === "local"
              text: "Nothing is pushed or pulled. The directory is the whole vault; back it up yourself."
              opacity: 0.7
            }

            CardField {
              id: gitRemoteField
              visible: root.setupBackend === "git"
              placeholderText: "git@github.com:you/pass.git  or  https://…"
              onAccepted: root.setupPrimary()
            }
            SetupText {
              visible: root.setupBackend === "git"
              text: "pass git init if needed, then push -u origin; an existing remote with commits is fetched instead. Credentials are git's and ssh's own; the first push runs in a terminal."
                + "  Pull --rebase on open: " + (root.setupGitPull ? "on" : "off") + " (P)."
                + "  Signed commits with the vault's key: " + (root.setupGitSign ? "on" : "off") + " (K), so a teammate can verify who pushed what."
                + "  Two seats editing one entry offline: this seat's version stays, the other's lands beside it as “(conflict from origin, <commit>)”."
              opacity: 0.7
            }

            CardField {
              id: rcloneRemoteField
              visible: root.setupBackend === "rclone"
              placeholderText: "remote:bucket/pass"
              onAccepted: root.setupPrimary()
            }
            SetupText {
              visible: root.setupBackend === "rclone"
              text: "The remote must already exist in rclone config; its tokens stay there. An empty store is filled from the remote first; a full one is uploaded after you confirm."
                + "  Push mode: " + root.setupRcloneMode + " (M; sync deletes on the remote).  Copy from the remote on open: " + (root.setupRclonePull ? "on" : "off") + " (P)."
              opacity: 0.7
            }

            CardField {
              id: pushCmdField
              visible: root.setupBackend === "custom"
              placeholderText: "push command, e.g. git push  or  rsync -a \"$STORE/\" host:pass/"
              onAccepted: root.setupPrimary()
            }
            CardField {
              id: pullCmdField
              visible: root.setupBackend === "custom"
              placeholderText: "pull command (optional)"
              onAccepted: root.setupPrimary()
            }
            SetupText {
              visible: root.setupBackend === "custom"
              text: "Run with bash -lc in the store, $STORE set to its path, after a change (push) and when the card opens (pull). Never put a secret in a command."
              opacity: 0.7
            }
          }
        }

        // Status line: busy, an error, a note, or a question.
        SetupText {
          visible: text !== ""
          text: root.setupBusy !== "" ? root.setupBusy
            : root.setupError !== "" ? root.setupError
            : root.syncConfirm !== "" ? root.syncConfirm
            : root.removeConfirm !== "" ? "Forget vault “" + (root.vaultById(root.removeConfirm) ? root.vaultById(root.removeConfirm).name : root.removeConfirm)
                + "”? Only the record goes; the directory and its entries stay."
            : root.setupNote
          color: root.setupError !== "" ? Color.urgent : root.foreground
          opacity: root.setupError !== "" || root.syncConfirm !== "" || root.removeConfirm !== "" ? 1 : 0.8
          topPadding: Style.space(4)
        }

        // -- 6. health
        Column {
          width: parent.width
          spacing: root.rowSpacing
          visible: root.setupStep === 6

          SetupText {
            text: root.healthChecked < 0
              ? "Every entry is decrypted once, here, and nothing is written: passwords used more than once, short ones, old ones, empty ones" + (root.healthHibp ? ", and ones seen in breaches (only the first five characters of a hash leave the machine)." : ".")
              : (root.healthFindings.length === 0
                 ? (root.healthShortfall !== "" ? "No findings among " + root.healthChecked + " entries, but the check fell short: " + root.healthShortfall : "Nothing to report across " + root.healthChecked + " entries.")
                 : root.healthFindings.length + " findings across " + root.healthChecked + " entries. Enter opens one in the editor." + (root.healthShortfall !== "" ? "  " + root.healthShortfall : ""))
            opacity: 0.7
            bottomPadding: Style.space(6)
          }
          Repeater {
            model: root.healthRows
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              hasCursor: root.healthIndex === index
              lead: modelData.lead
              title: modelData.title
              subtitle: modelData.subtitle
              trail: modelData.kind
              onHoveredRow: root.healthIndex = index
              onPicked: root.openHealthEntry(index)
            }
          }
          Toggle {
            width: parent.width
            label: "Also check against Have I Been Pwned"
            description: "k-anonymity: only the first five characters of each password's SHA-1 are sent; the answer is compared here (B toggles)"
            checked: root.healthHibp
            foreground: root.foreground
            accent: root.selectedBackground
            fontFamily: root.fontFamily
            onClicked: root.saveSetting("healthHibp", !root.healthHibp)
          }
        }

        // Legend full width, then Back / primary — sharing one row clipped
        // the GPG actions and ate "Import public key".
        Column {
          width: parent.width
          spacing: Style.space(8)

          Text {
            id: setupFooter
            width: parent.width
            text: root.setupHint + "  ·  Esc " + (root.setupStep > 0 && (root.vaultsOnRecord || root.storeUsable) ? "vaults" : (root.storeUsable ? "back to search" : "cancel"))
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            id: buttonRow
            anchors.right: parent.right
            spacing: Style.spacing.controlGap

            CardButton {
              text: "Back"
              visible: root.gpgImporting
                || root.setupStep > 1
                || (root.setupStep === 1 && (root.vaultsOnRecord || root.storeUsable))
              onClicked: root.setupBack()
            }
            CardButton {
              text: root.setupPrimaryLabel
              selected: root.setupPrimaryEnabled
              opacity: root.setupPrimaryEnabled ? 1 : 0.5
              onClicked: root.setupPrimary()
            }
          }
        }
      }
    }
  }
}
