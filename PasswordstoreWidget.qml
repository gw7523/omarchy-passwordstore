import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button for the Password Store overlay. The search card itself is
// PasswordstoreOverlay.qml; this only summons it, the way the Omarchy menu's
// bar button summons the menu. The widget's settings (store directory, clip
// time, …) are stored on this bar entry and read by the overlay from there.
BarWidget {
  id: root

  readonly property string pluginId: "hegjon.passwordstore"
  moduleName: pluginId

  // What the key shows besides itself: a dot for changes not yet pushed
  // or a pull that failed, a lock while the passphrase lockout holds.
  // Asked of passwordstore-setup bar-status every few minutes and when
  // the button is pressed; cheap (git and two files), nothing decrypted.
  readonly property string setupPath: Qt.resolvedUrl("passwordstore-setup").toString().replace(/^file:\/\//, "")
  property int unpushed: 0
  property bool pullFailed: false
  property bool locked: false
  property string barBackend: "local"
  function refreshStatus() {
    if (statusProcess.running) return
    statusProcess.command = [setupPath, "bar-status"]
    statusProcess.running = true
  }
  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(String(statusStdout.text || "")) } catch (e) { parsed = null }
      if (!parsed) return
      root.unpushed = Number(parsed.unpushed) || 0
      root.pullFailed = !!parsed.pullFailed
      root.locked = !!parsed.locked
      root.barBackend = String(parsed.backend || "local")
    }
  }
  Timer { interval: 180000; repeat: true; running: true; triggeredOnStart: true; onTriggered: root.refreshStatus() }
  // Settings writes come in clusters (a vault save is two); one refresh after the last.
  Timer { id: settingsRefresh; interval: 3000; repeat: false; onTriggered: root.refreshStatus() }
  onSettingsChanged: settingsRefresh.restart()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.locked ? String.fromCodePoint(0xF033E) : String.fromCodePoint(0xF0306)   // nf-md-lock / nf-md-key
    // The active vault's name, read from this entry's settings: `vaults` is
    // an array, or a string holding one when set without --json.
    readonly property string activeVaultName: {
      var s = root.settings || {}
      var vaults = s.vaults
      if (typeof vaults === "string") { try { vaults = JSON.parse(vaults) } catch (e) { vaults = [] } }
      if (!Array.isArray(vaults) || vaults.length === 0) return ""
      var active = String(s.activeVaultId || "")
      for (var i = 0; i < vaults.length; i++)
        if (vaults[i] && vaults[i].id === active) return String(vaults[i].name || vaults[i].id)
      return String(vaults[0].name || vaults[0].id || "")
    }
    tooltipText: "Password Store" + (activeVaultName !== "" ? " · " + activeVaultName : "")
      + (root.locked ? " · locked after wrong passphrases" : "")
      + (root.pullFailed ? " · the last pull failed" : (root.unpushed > 0 ? " · " + root.unpushed + " change" + (root.unpushed === 1 ? "" : "s") + " not pushed" : ""))
    slotSize: Style.bar.statusSlot

    onPressed: function(buttonCode) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle " + root.pluginId)
      refreshTimer.restart()
    }

    // The dot: pushed-behind or pull-failed, in the bar's active colour.
    Rectangle {
      visible: root.barBackend !== "local" && (root.unpushed > 0 || root.pullFailed)
      width: Style.space(6); height: width; radius: width / 2
      anchors.right: parent.right; anchors.top: parent.top
      anchors.rightMargin: Style.space(2); anchors.topMargin: Style.space(4)
      color: root.pullFailed ? Color.urgent : Color.bar.active
    }
  }
  // After the card closes something may have been pushed; look again soon.
  Timer { id: refreshTimer; interval: 20000; repeat: false; onTriggered: root.refreshStatus() }
}
