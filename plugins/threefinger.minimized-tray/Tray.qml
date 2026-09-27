import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Tray for windows minimized with the three-finger swipe (see
// ~/.config/hypr/minimize.lua, part of Omarchy 3 Finger Gestures). Shows at the bottom of the screen while the
// hidden workspace `special:minimized` holds any windows.
//
// Selection: hovering a tile selects it. The tray takes the keyboard as soon
// as a tile lands in it (and on SUPER+M), so Left/Right (or Tab) move the
// selection, Enter/Up restores, Backspace/Delete closes. Escape, Down or
// SUPER+M hand the keyboard back; restoring a tile or emptying the tray does
// too. The selected tile is what a three-finger swipe up brings back (its
// address is written to `selectedPath`, which minimize.lua reads). Left-click
// restores a tile, the ✕ on it (or middle-click) closes it.

Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string minimizedWorkspace: "special:minimized"
  // Keep in sync with M.tray_height in minimize.lua.
  readonly property int trayHeight: Style.space(40)
  readonly property int maxTitleWidth: Style.space(200)
  // Keep in sync with M.selected_path in minimize.lua.
  readonly property string selectedPath: Quickshell.env("HOME") + "/.local/state/omarchy/minimized-tray-selected"

  property var windows: []
  property int selectedIndex: -1
  property bool focusMode: false
  // Order tiles by when they were first seen, so the newest sits at the right.
  property var firstSeen: ({})
  property int seenCounter: 0
  property bool refreshPending: false

  readonly property string selectedAddress: (selectedIndex >= 0 && selectedIndex < windows.length)
    ? windows[selectedIndex].address : ""

  function log(message) {
    console.log("minimized-tray " + message)
  }

  function iconFor(client) {
    var candidates = [client["class"], client.initialClass]
    for (var i = 0; i < candidates.length; i++) {
      var id = String(candidates[i] || "")
      if (!id) continue
      var entry = DesktopEntries.heuristicLookup(id)
      if (entry && entry.icon) {
        var path = Quickshell.iconPath(entry.icon, true)
        if (path) return path
      }
      var direct = Quickshell.iconPath(id.toLowerCase(), true)
      if (direct) return direct
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  function parseClients(text) {
    var list
    try {
      list = JSON.parse(text || "[]")
    } catch (e) {
      root.log("could not parse hyprctl clients: " + e)
      return
    }
    var seen = root.firstSeen
    var next = []
    var newest = ""
    var restored = false
    var alive = ({})
    for (var a = 0; a < list.length; a++) if (list[a] && list[a].address) alive[String(list[a].address)] = true
    // A tile that left the tray but whose window still exists was restored
    // (by swipe, click or Enter): the tray is done, hand the keyboard back.
    // A closed window just disappears and the tray stays in use.
    for (var gone in seen) if (alive[gone] && !root.isMinimized(list, gone)) restored = true
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c || !c.workspace || c.workspace.name !== root.minimizedWorkspace) continue
      var address = String(c.address)
      if (seen[address] === undefined) {
        seen[address] = ++root.seenCounter
        newest = address
      }
      next.push({
        address: address,
        title: String(c.title || c["class"] || "Window"),
        appClass: String(c["class"] || ""),
        icon: root.iconFor(c),
        order: seen[address]
      })
    }
    next.sort(function(a, b) { return a.order - b.order })
    // Forget addresses that are no longer minimized.
    var kept = ({})
    for (var k = 0; k < next.length; k++) kept[next[k].address] = seen[next[k].address]
    root.firstSeen = kept

    // A freshly minimized window takes the selection, so a swipe up right
    // after a swipe down brings that window back. Otherwise keep the current
    // pick; if it went away, fall back to the newest tile.
    var wanted = newest || root.selectedAddress
    root.windows = next
    var index = -1
    for (var j = 0; j < next.length; j++) if (next[j].address === wanted) index = j
    root.setSelected(index >= 0 ? index : next.length - 1)
    if (next.length === 0 || restored) root.focusMode = false
    else if (newest) root.focusMode = true
  }

  function isMinimized(list, address) {
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (c && String(c.address) === address)
        return !!c.workspace && c.workspace.name === root.minimizedWorkspace
    }
    return false
  }

  onFocusModeChanged: if (focusMode) keyCatcher.forceActiveFocus()

  function setSelected(index) {
    if (index < 0 || index >= root.windows.length) index = -1
    root.selectedIndex = index
    selectedFile.setText(root.selectedAddress)
  }

  function moveSelection(delta) {
    var n = root.windows.length
    if (n === 0) return
    var index = root.selectedIndex < 0 ? n - 1 : root.selectedIndex
    root.setSelected(((index + delta) % n + n) % n)
  }

  function refresh() {
    if (clientsProc.running) {
      root.refreshPending = true
      return
    }
    clientsProc.running = true
  }

  function restore(address) {
    if (!address) return
    root.focusMode = false
    // hyprctl dispatch wants a dispatcher back, so wrap the call.
    Quickshell.execDetached(["hyprctl", "dispatch",
      "(function() Minimize.restore('" + address + "'); return hl.dsp.no_op() end)()"])
  }

  function closeWindow(address) {
    if (!address) return
    Quickshell.execDetached(["hyprctl", "dispatch",
      "hl.dsp.window.close({ window = hl.get_window('address:" + address + "') })"])
  }

  function toggleFocus() {
    if (root.windows.length === 0) {
      root.focusMode = false
      return
    }
    root.focusMode = !root.focusMode
  }

  FileView {
    id: selectedFile
    path: root.selectedPath
    printErrors: false
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseClients(text)
    }
    onRunningChanged: {
      if (!running && root.refreshPending) {
        root.refreshPending = false
        root.refresh()
      }
    }
  }

  // Hyprland fires a burst of events per move; coalesce them into one refresh.
  Timer {
    id: refreshTimer
    interval: 80
    repeat: false
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "movewindow" || name === "movewindowv2" || name === "openwindow"
          || name === "closewindow" || name === "windowtitle" || name === "windowtitlev2"
          || name === "configreloaded") {
        refreshTimer.restart()
      }
    }
  }

  Component.onCompleted: refresh()

  PanelWindow {
    id: panel
    visible: root.windows.length > 0
    anchors { bottom: true; left: true; right: true }
    implicitHeight: root.trayHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Auto
    WlrLayershell.namespace: "omarchy-minimized-tray"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.focusMode ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Color.bar.background

      // Hairline along the top edge so the tray reads as a shelf. Brighter
      // while the tray has the keyboard.
      Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 1
        color: root.focusMode ? Util.alpha(Color.accent, 0.6) : Util.alpha(Color.bar.text, 0.15)
        Behavior on color { ColorAnimation { duration: 120 } }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (!root.focusMode) return
          switch (event.key) {
          case Qt.Key_Left:
          case Qt.Key_Backtab:
            root.moveSelection(-1); event.accepted = true; break
          case Qt.Key_Right:
          case Qt.Key_Tab:
            root.moveSelection(1); event.accepted = true; break
          case Qt.Key_Home:
            root.setSelected(0); event.accepted = true; break
          case Qt.Key_End:
            root.setSelected(root.windows.length - 1); event.accepted = true; break
          case Qt.Key_Return:
          case Qt.Key_Enter:
          case Qt.Key_Space:
          case Qt.Key_Up:
            root.restore(root.selectedAddress); event.accepted = true; break
          case Qt.Key_Delete:
          case Qt.Key_Backspace:
            root.closeWindow(root.selectedAddress); event.accepted = true; break
          case Qt.Key_Escape:
          case Qt.Key_Down:
            root.focusMode = false; event.accepted = true; break
          }
        }
      }

      Row {
        anchors.centerIn: parent
        spacing: Style.space(6)

        Repeater {
          model: root.windows

          delegate: Rectangle {
            id: entry
            required property var modelData
            required property int index

            readonly property bool selected: index === root.selectedIndex
            readonly property bool hovered: mouse.containsMouse
            readonly property bool lit: selected || hovered
            width: content.implicitWidth + Style.space(20)
            height: root.trayHeight - Style.space(10)
            radius: Style.cornerRadius
            color: entry.selected
              ? Style.selectedFillFor(Color.bar.text, Color.accent, Color.urgent)
              : (entry.hovered
                ? Style.hoverFillFor(Color.bar.text, Color.accent, Color.urgent)
                : Style.normalFillFor(Color.bar.text, Color.accent, Color.urgent))
            border.width: 1
            border.color: entry.lit
              ? Util.alpha(Color.accent, entry.selected ? Style.selectedBorderAlpha : Style.hoverBorderAlpha)
              : Util.alpha(Color.bar.text, Style.normalBorderAlpha * 0.5)

            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }

            Row {
              id: content
              anchors.centerIn: parent
              spacing: Style.space(8)

              Image {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(20)
                height: width
                source: entry.modelData.icon
                sourceSize: Qt.size(width, height)
                fillMode: Image.PreserveAspectFit
                smooth: true
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: entry.modelData.title
                color: entry.lit ? Color.accent : Color.bar.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: Math.min(implicitWidth, root.maxTitleWidth)
                textFormat: Text.PlainText
              }

              // Close button: a small ✕ after the title.
              Rectangle {
                id: closeButton
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                height: width
                radius: width / 2
                readonly property bool hovered: closeMouse.containsMouse
                color: hovered ? Util.alpha(Color.urgent, 0.35) : "transparent"
                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                  anchors.centerIn: parent
                  text: "✕"
                  color: closeButton.hovered ? Color.foreground : Util.alpha(Color.bar.text, entry.lit ? 0.8 : 0.45)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                }

                MouseArea {
                  id: closeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.closeWindow(entry.modelData.address)
                }
              }
            }

            MouseArea {
              id: mouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onEntered: root.setSelected(entry.index)
              onClicked: function(event) {
                if (event.button === Qt.MiddleButton) root.closeWindow(entry.modelData.address)
                else root.restore(entry.modelData.address)
              }
            }
          }
        }
      }

      // Key hints while the tray has the keyboard.
      Text {
        anchors { right: parent.right; rightMargin: Style.space(12); verticalCenter: parent.verticalCenter }
        visible: root.focusMode
        text: "←  →  select   ↵ restore   ⌫ close   esc / ↓ / super+m  release keys"
        color: Util.alpha(Color.bar.text, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }
    }
  }

  IpcHandler {
    target: "minimized-tray"
    function refresh(): string { root.refresh(); return "ok" }
    function count(): string { return String(root.windows.length) }
    function focus(): string { root.toggleFocus(); return root.focusMode ? "focused" : "unfocused" }
    function focused(): string { return root.focusMode ? "true" : "false" }
    function select(delta: int): string { root.moveSelection(delta); return root.selectedAddress }
    function selected(): string { return root.selectedAddress }
    function restoreSelected(): string { root.restore(root.selectedAddress); return "ok" }
  }
}
