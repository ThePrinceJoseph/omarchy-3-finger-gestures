import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// 3 Finger Gestures: the dock for minimized windows (the Lua half lives in
// hypr/minimize.lua, installed to ~/.config/hypr/). A floating, centred card
// along the bottom that only exists while the hidden workspace
// `special:minimized` holds windows. One tile per window: a picture of it,
// its app icon and title. The selected tile carries an accent border and a
// dot; hovering shows a larger preview above the dock and a ✕ to close.
//
// Selection: hovering selects. The dock takes the keyboard as soon as a tile
// lands (and on the tray key), so Left/Right (or Tab) move the selection,
// Enter/Up restores, Backspace/Delete closes. Escape, Down or the tray key
// hand the keyboard back; restoring a tile or emptying the dock does too.
// The selected tile is what a three-finger swipe up brings back (its address
// is written to `selectedPath`, which minimize.lua reads).

Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string minimizedWorkspace: "special:minimized"
  readonly property string selectedPath: Quickshell.env("HOME") + "/.local/state/omarchy/minimized-tray-selected"
  readonly property string settingsPath: Quickshell.env("HOME") + "/.local/state/omarchy/minimized-tray-settings.json"
  readonly property string thumbDir: Quickshell.env("HOME") + "/.cache/threefinger-tray"

  // From gestures.lua via the settings file.
  property bool reserveSpace: false
  property bool thumbnails: true

  property var windows: []
  property int selectedIndex: -1
  property bool focusMode: false
  property int hoverIndex: -1
  property int previewIndex: -1
  property var firstSeen: ({})
  property int seenCounter: 0
  property bool refreshPending: false

  readonly property string selectedAddress: (selectedIndex >= 0 && selectedIndex < windows.length)
    ? windows[selectedIndex].address : ""

  function log(message) { console.log("minimized-tray " + message) }

  function applySettings(text) {
    try {
      var cfg = JSON.parse(text || "{}")
      root.reserveSpace = cfg.reserveSpace === true
      root.thumbnails = cfg.thumbnails !== false
    } catch (e) {
      root.log("could not parse " + root.settingsPath + ": " + e)
    }
  }

  // Browser web apps (Omarchy's `omarchy-launch-webapp`, Chrome's "install as
  // app") get a window class like `chrome-discord.com__channels_@me-Default`
  // that no desktop entry names. Pull the host out of it so the entry that
  // launches that site can be found by its Exec line.
  function webAppHost(appClass) {
    var m = /^(?:chrome|chromium|brave|msedge|vivaldi)-([^_]+?)(?:__.*)?(?:-[A-Za-z]+)?$/.exec(appClass)
    return m ? m[1] : ""
  }

  function entryForClass(appClass) {
    if (!appClass) return null
    var entry = DesktopEntries.heuristicLookup(appClass)
    if (entry) return entry
    var wanted = appClass.toLowerCase()
    var host = webAppHost(appClass).toLowerCase()
    var apps = DesktopEntries.applications ? (DesktopEntries.applications.values || []) : []
    var byExec = null
    for (var i = 0; i < apps.length; i++) {
      var e = apps[i]
      if (!e) continue
      var startup = String(e.startupClass || "").toLowerCase()
      if (startup && startup === wanted) return e
      if (host && !byExec) {
        var exec = String(e.execString || e.command || "").toLowerCase()
        if (exec.indexOf(host) !== -1 && (exec.indexOf("webapp") !== -1 || exec.indexOf("--app=") !== -1)) byExec = e
      }
    }
    return byExec
  }

  function iconFor(client) {
    var candidates = [client["class"], client.initialClass]
    for (var i = 0; i < candidates.length; i++) {
      var id = String(candidates[i] || "")
      if (!id) continue
      var entry = entryForClass(id)
      if (entry && entry.icon) {
        var path = Quickshell.iconPath(entry.icon, true)
        if (path) return path
      }
      var direct = Quickshell.iconPath(id.toLowerCase(), true)
      if (direct) return direct
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  function isMinimized(list, address) {
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (c && String(c.address) === address)
        return !!c.workspace && c.workspace.name === root.minimizedWorkspace
    }
    return false
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
    // A tile that left the dock but whose window still exists was restored
    // (by swipe, click or Enter): the dock is done, hand the keyboard back.
    // A closed window just disappears and the dock stays in use.
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
        thumb: "file://" + root.thumbDir + "/" + address.replace(/[^0-9a-zA-Z]/g, "") + ".jpg?t=" + Date.now(),
        order: seen[address]
      })
    }
    next.sort(function(a, b) { return a.order - b.order })
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
    if (root.previewIndex >= next.length) root.previewIndex = -1
    if (next.length === 0 || restored) root.focusMode = false
    else if (newest) root.focusMode = true
  }

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
    if (clientsProc.running) { root.refreshPending = true; return }
    clientsProc.running = true
  }

  function restore(address) {
    if (!address) return
    root.focusMode = false
    root.previewIndex = -1
    // hyprctl dispatch wants a dispatcher back, so wrap the call.
    Quickshell.execDetached(["hyprctl", "dispatch",
      "(function() Minimize.restore('" + address + "'); return hl.dsp.no_op() end)()"])
  }

  function closeWindow(address) {
    if (!address) return
    root.previewIndex = -1
    // Resolve the window first: a close with no target would hit the focused
    // window if this tile's window vanished a moment ago.
    Quickshell.execDetached(["hyprctl", "dispatch",
      "(function() local w = hl.get_window('address:" + address + "'); "
      + "if w then hl.dispatch(hl.dsp.window.close({ window = w })) end; return hl.dsp.no_op() end)()"])
  }

  function toggleFocus() {
    if (root.windows.length === 0) { root.focusMode = false; return }
    root.focusMode = !root.focusMode
  }

  // Hover preview: a short delay so sweeping across the dock does not flash.
  function hoverTile(index) {
    root.hoverIndex = index
    if (index < 0) { previewTimer.stop(); previewHide.restart() }
    else { previewHide.stop(); if (root.previewIndex >= 0) root.previewIndex = index; else previewTimer.restart() }
  }
  Timer { id: previewTimer; interval: 220; onTriggered: if (root.hoverIndex >= 0 && root.thumbnails) root.previewIndex = root.hoverIndex }
  Timer { id: previewHide; interval: 120; onTriggered: if (root.hoverIndex < 0) root.previewIndex = -1 }

  FileView { id: selectedFile; path: root.selectedPath; printErrors: false }

  FileView {
    id: settingsFile
    path: root.settingsPath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.applySettings(text())
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseClients(text) }
    onRunningChanged: if (!running && root.refreshPending) { root.refreshPending = false; root.refresh() }
  }

  Timer { id: refreshTimer; interval: 80; repeat: false; onTriggered: root.refresh() }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "movewindow" || name === "movewindowv2" || name === "openwindow"
          || name === "closewindow" || name === "windowtitle" || name === "windowtitlev2"
          || name === "configreloaded") refreshTimer.restart()
    }
  }

  Component.onCompleted: refresh()

  // Sizes shared by the dock, the preview and the flying proxy.
  readonly property int edge: Style.space(20)      // clearance to the screen sides
  readonly property int pad: Style.space(10)       // card padding
  readonly property int gap: Style.space(8)        // between tiles
  readonly property int maxTileWidth: Style.space(156)
  readonly property int minTileWidth: Style.space(72)
  readonly property int bottomMargin: Style.space(10)
  readonly property int thumbGap: Style.space(8)   // picture to label
  readonly property int labelRowHeight: Style.space(18)
  readonly property int labelGap: Style.space(6)   // label to dot
  readonly property int dotSize: Style.space(5)
  readonly property int frameRadius: Style.cornerRadius > 0 ? Style.space(8) : 0

  property var dockGeometry: ({ x: 0, width: 0, height: 0 })

  function focusedScreen() {
    var screens = Quickshell.screens
    var name = Hyprland.focusedMonitor && Hyprland.focusedMonitor.name ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < screens.length; i++) if (screens[i] && screens[i].name === name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }
  function tileWidthFor(n, screenWidth) {
    n = Math.max(1, n)
    var avail = screenWidth - 2 * root.edge - 2 * root.pad - (n - 1) * root.gap
    return Math.max(root.minTileWidth, Math.min(root.maxTileWidth, Math.floor(avail / n)))
  }
  function thumbHeightFor(w) { return Math.round(w * 9 / 16) }
  function tileHeightFor(w) { return (root.thumbnails ? thumbHeightFor(w) + root.thumbGap : 0) + root.labelRowHeight + root.labelGap + root.dotSize }
  // Where tile <index> of <n> tiles sits on screen (its picture frame, or the
  // whole tile when thumbnails are off), in that screen's logical coordinates.
  function tileRect(index, n, scr) {
    var sw = scr ? scr.width : 1280, sh = scr ? scr.height : 800
    var w = tileWidthFor(n, sw)
    var dockW = n * w + (n - 1) * root.gap + 2 * root.pad
    var dockH = tileHeightFor(w) + 2 * root.pad
    var dockX = Math.round((sw - dockW) / 2)
    var dockY = sh - root.bottomMargin - dockH
    var h = root.thumbnails ? thumbHeightFor(w) : tileHeightFor(w)
    return { x: dockX + root.pad + index * (w + root.gap), y: dockY + root.pad, w: w, h: h }
  }

  // One dock per screen; only the one on the focused screen takes the keyboard.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: dock
      required property var modelData
      screen: modelData
      readonly property bool onFocusedScreen: {
        var focused = Hyprland.focusedMonitor
        if (!focused || !focused.name || !dock.screen || !dock.screen.name) return true
        return focused.name === dock.screen.name
      }
      readonly property int tileWidth: root.tileWidthFor(root.windows.length, dock.screen ? dock.screen.width : 1280)
      visible: root.windows.length > 0
      anchors { bottom: true }
      margins { bottom: root.bottomMargin }
      implicitWidth: card.width
      implicitHeight: card.height
      color: "transparent"
      exclusionMode: root.reserveSpace ? ExclusionMode.Auto : ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-minimized-tray"
      // Overlay, not Top: Hyprland draws fullscreen windows above the Top
      // layer, and the dock must stay reachable while one is up.
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: (root.focusMode && dock.onFocusedScreen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      Connections {
        target: root
        function onFocusModeChanged() { if (root.focusMode && dock.onFocusedScreen) keyCatcher.forceActiveFocus() }
      }

      onWidthChanged: if (dock.onFocusedScreen) root.dockGeometry = { x: Math.round(((dock.screen ? dock.screen.width : 1280) - width) / 2), width: width, height: height }
      onHeightChanged: if (dock.onFocusedScreen) root.dockGeometry = { x: Math.round(((dock.screen ? dock.screen.width : 1280) - width) / 2), width: width, height: height }

      Rectangle {
        id: card
        width: tilesRow.width + 2 * root.pad
        height: tilesRow.height + 2 * root.pad
        radius: Style.cornerRadius > 0 ? Math.max(Style.cornerRadius, Style.space(12)) : 0
        color: Util.alpha(Color.popups.background, 0.9)
        border.width: 1
        border.color: root.focusMode ? Util.alpha(Color.accent, 0.55) : Util.alpha(Color.popups.border, 0.35)
        Behavior on border.color { ColorAnimation { duration: 140 } }

        Item {
          id: keyCatcher
          anchors.fill: parent
          focus: true
          Keys.onPressed: function(event) {
            if (!root.focusMode) return
            switch (event.key) {
            case Qt.Key_Left: case Qt.Key_Backtab: root.moveSelection(-1); event.accepted = true; break
            case Qt.Key_Right: case Qt.Key_Tab: root.moveSelection(1); event.accepted = true; break
            case Qt.Key_Home: root.setSelected(0); event.accepted = true; break
            case Qt.Key_End: root.setSelected(root.windows.length - 1); event.accepted = true; break
            case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space: case Qt.Key_Up:
              root.restore(root.selectedAddress); event.accepted = true; break
            case Qt.Key_Delete: case Qt.Key_Backspace:
              root.closeWindow(root.selectedAddress); event.accepted = true; break
            case Qt.Key_Escape: case Qt.Key_Down: root.focusMode = false; event.accepted = true; break
            }
          }
        }

        Row {
          id: tilesRow
          anchors.centerIn: parent
          spacing: root.gap
          move: Transition { NumberAnimation { properties: "x"; duration: 220; easing.type: Easing.OutCubic } }

          Repeater {
            model: root.windows

            delegate: Item {
              id: tile
              required property var modelData
              required property int index
              readonly property bool selected: index === root.selectedIndex
              readonly property bool hovered: index === root.hoverIndex
              readonly property bool showThumb: root.thumbnails
              readonly property int thumbHeight: root.thumbHeightFor(dock.tileWidth)
              width: dock.tileWidth
              height: root.tileHeightFor(dock.tileWidth)

              // Whole-tile handler, declared first so the ✕ sits above it.
              MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                onEntered: { root.setSelected(tile.index); root.hoverTile(tile.index) }
                onExited: if (root.hoverIndex === tile.index) root.hoverTile(-1)
                onClicked: function(event) {
                  if (event.button === Qt.MiddleButton) root.closeWindow(tile.modelData.address)
                  else root.restore(tile.modelData.address)
                }
              }

              // Thumbnail card with the accent frame when selected.
              Rectangle {
                id: frame
                visible: tile.showThumb
                width: tile.width
                height: tile.thumbHeight
                radius: root.frameRadius
                color: Util.alpha(Color.bar.text, 0.06)
                border.width: tile.selected ? 2 : 1
                border.color: tile.selected ? Color.accent : Util.alpha(Color.bar.text, tile.hovered ? 0.35 : 0.14)
                Behavior on border.color { ColorAnimation { duration: 120 } }

                // Soft glow behind the selected frame.
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: -Style.space(3)
                  radius: parent.radius + Style.space(3)
                  color: "transparent"
                  border.width: Style.space(3)
                  border.color: Util.alpha(Color.accent, tile.selected ? 0.22 : 0)
                  z: -1
                  Behavior on border.color { ColorAnimation { duration: 160 } }
                }

                Image {
                  id: thumb
                  anchors.fill: parent
                  anchors.margins: 2
                  source: tile.modelData.thumb
                  cache: false
                  asynchronous: true
                  fillMode: Image.PreserveAspectCrop
                  smooth: true
            mipmap: true
                  clip: true
                  visible: status === Image.Ready
                }
                // Fallback when the capture is missing: a big icon on the card.
                Image {
                  anchors.centerIn: parent
                  width: Style.space(32); height: width
                  source: tile.modelData.icon
                  sourceSize: Qt.size(width, height)
                  visible: thumb.status !== Image.Ready
                  opacity: 0.8
                }

                // Close button, top right, on hover or when keyboard-selected.
                Rectangle {
                  id: closeButton
                  z: 2
                  anchors { top: parent.top; right: parent.right; margins: Style.space(5) }
                  width: Style.space(20); height: width; radius: width / 2
                  readonly property bool hot: closeMouse.containsMouse
                  // Mouse only (Backspace closes the selected tile from the keyboard); fades with the hover.
                  opacity: tile.hovered ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                  enabled: opacity > 0.5
                  color: hot ? Util.alpha(Color.urgent, 0.85) : Util.alpha(Color.popups.background, 0.85)
                  border.width: 1
                  border.color: Util.alpha(Color.foreground, hot ? 0.6 : 0.3)
                  Text { anchors.centerIn: parent; text: "✕"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; textFormat: Text.PlainText }
                  MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    enabled: closeButton.enabled
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.hoverTile(tile.index)
                    onClicked: root.closeWindow(tile.modelData.address)
                  }
                }
              }

              // Icon + title under the picture.
              Item {
                id: labelRow
                anchors { left: parent.left; right: parent.right; top: tile.showThumb ? frame.bottom : parent.top; topMargin: tile.showThumb ? root.thumbGap : 0 }
                height: root.labelRowHeight
                Image {
                  id: icon
                  anchors { left: parent.left; leftMargin: Style.space(4); verticalCenter: parent.verticalCenter }
                  width: Style.space(18); height: width
                  source: tile.modelData.icon
                  sourceSize: Qt.size(width, height)
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                }
                Text {
                  id: title
                  anchors { left: icon.right; leftMargin: Style.space(6); right: parent.right; rightMargin: Style.space(2); verticalCenter: parent.verticalCenter }
                  text: tile.modelData.title
                  color: tile.selected ? Color.foreground : Util.alpha(Color.bar.text, 0.85)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
              }

              // Indicator dot.
              Rectangle {
                id: dot
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom }
                width: root.dotSize; height: width; radius: width / 2
                color: tile.selected ? Color.accent : Util.alpha(Color.bar.text, 0.3)
                Behavior on color { ColorAnimation { duration: 120 } }
              }
            }
          }
        }
      }
    }
  }

  // Larger preview right above the hovered tile: the full title and a bigger
  // picture. Drawn on a full-screen transparent surface so it can be placed
  // by exact coordinates; fades in and out.
  readonly property var previewEntry: (previewIndex >= 0 && previewIndex < windows.length) ? windows[previewIndex] : null
  property var lastPreviewEntry: null
  onPreviewEntryChanged: if (previewEntry) lastPreviewEntry = previewEntry

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: previewWindow
      required property var modelData
      screen: modelData
      readonly property bool mine: {
        var focused = Hyprland.focusedMonitor
        if (!focused || !focused.name || !previewWindow.screen || !previewWindow.screen.name) return true
        return focused.name === previewWindow.screen.name
      }
      readonly property bool wanted: root.previewEntry !== null && root.thumbnails && mine
      visible: wanted || previewCard.opacity > 0.01
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-minimized-preview"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}

      Rectangle {
        id: previewCard
        readonly property var entry: root.previewEntry || root.lastPreviewEntry
        readonly property int imgW: Math.min(Style.space(520), Math.round(previewWindow.width * 0.42))
        readonly property var tileR: root.tileRect(Math.max(0, root.previewIndex), Math.max(1, root.windows.length), previewWindow.screen)
        width: imgW + 2 * root.pad
        height: previewTitle.height + Style.space(8) + previewImage.height + 2 * root.pad
        // Centred over the tile, kept inside the screen, sitting just above the dock.
        x: Math.max(root.edge, Math.min(previewWindow.width - root.edge - width, tileR.x + tileR.w / 2 - width / 2))
        y: tileR.y - root.pad - Style.space(10) - height
        radius: Style.cornerRadius > 0 ? Style.space(12) : 0
        color: Util.alpha(Color.popups.background, 0.96)
        border.width: 1
        border.color: Util.alpha(Color.popups.border, 0.5)
        opacity: previewWindow.wanted ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Row {
          id: previewTitle
          anchors { top: parent.top; left: parent.left; right: parent.right; margins: root.pad }
          height: Style.space(20)
          spacing: Style.space(8)
          Image {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(18); height: width
            source: previewCard.entry ? previewCard.entry.icon : ""
            sourceSize: Qt.size(width, height)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: previewTitle.width - Style.space(26)
            text: previewCard.entry ? previewCard.entry.title : ""
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
        }
        Rectangle {
          anchors { top: previewTitle.bottom; topMargin: Style.space(8); left: parent.left; leftMargin: root.pad }
          width: previewCard.imgW
          height: previewImage.height
          radius: root.frameRadius
          color: Util.alpha(Color.bar.text, 0.06)
          border.width: 1
          border.color: Util.alpha(Color.bar.text, 0.15)
          Image {
            id: previewImage
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 2 }
            height: status === Image.Ready && implicitWidth > 0 ? Math.round(width * implicitHeight / implicitWidth) : Math.round(width * 9 / 16)
            source: previewCard.entry ? previewCard.entry.thumb : ""
            cache: false
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
          }
        }
      }
    }
  }

  // Flights: a picture of the window that shrinks from where the window was
  // into its tile (minimize) or grows from the tile back to where the window
  // goes (restore). minimize.lua drives them over IPC and swaps the real
  // window in or out without animation underneath, so what you see moving is
  // always a picture. Several can be in the air at once (restore-all); each
  // has its own proxy and timers. Coordinates arrive global and are drawn in
  // the named monitor's own space.
  ListModel { id: flightsModel }

  function screenNamed(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i] && screens[i].name === name) return screens[i]
    return root.focusedScreen()
  }

  function startFlight(payload, out) {
    var p
    try { p = JSON.parse(payload || "{}") } catch (e) { root.log("bad flight payload: " + e); return "bad json" }
    var addr = String(p.address || "")
    var scr = p.monitor ? root.screenNamed(String(p.monitor)) : root.focusedScreen()
    var ox = Number(p.mx) || 0, oy = Number(p.my) || 0
    var n = root.windows.length, idx = -1
    for (var i = 0; i < n; i++) if (root.windows[i].address === addr) idx = i
    if (out) { if (idx < 0) { idx = n; n = n + 1 } }
    else if (idx < 0) return "not in dock"
    var tileR = root.tileRect(idx, n, scr)
    var winR = { x: (Number(p.x) || 0) - ox, y: (Number(p.y) || 0) - oy, w: Math.max(1, Number(p.w) || 1), h: Math.max(1, Number(p.h) || 1) }
    var from = out ? winR : tileR, to = out ? tileR : winR
    var entry = idx < root.windows.length ? root.windows[idx] : null
    // One flight per window: a new one replaces the old.
    for (var f = flightsModel.count - 1; f >= 0; f--) if (flightsModel.get(f).address === addr) flightsModel.remove(f)
    flightsModel.append({
      address: addr, out: out, screenName: scr ? scr.name : "",
      thumb: entry ? entry.thumb : ("file://" + root.thumbDir + "/" + addr.replace(/[^0-9a-zA-Z]/g, "") + ".jpg?t=" + Date.now()),
      icon: entry ? entry.icon : "",
      fromX: from.x, fromY: from.y, fromW: from.w, fromH: from.h,
      toX: to.x, toY: to.y, toW: to.w, toH: to.h, generation: 0
    })
    return "ok"
  }

  // Mid-flight retarget (a restored tiled window lands wherever the layout puts it).
  function retargetFlight(payload) {
    var p
    try { p = JSON.parse(payload || "{}") } catch (e) { return "bad json" }
    var addr = String(p.address || ""), ox = Number(p.mx) || 0, oy = Number(p.my) || 0
    for (var f = 0; f < flightsModel.count; f++) {
      if (flightsModel.get(f).address !== addr) continue
      flightsModel.setProperty(f, "toX", (Number(p.x) || 0) - ox)
      flightsModel.setProperty(f, "toY", (Number(p.y) || 0) - oy)
      flightsModel.setProperty(f, "toW", Math.max(1, Number(p.w) || 1))
      flightsModel.setProperty(f, "toH", Math.max(1, Number(p.h) || 1))
      flightsModel.setProperty(f, "generation", flightsModel.get(f).generation + 1)
      return "ok"
    }
    return "no flight"
  }

  function endFlight(address) {
    for (var f = flightsModel.count - 1; f >= 0; f--) if (!address || flightsModel.get(f).address === address) flightsModel.remove(f)
  }

  // One transparent full-screen surface per screen carries that screen's proxies.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: flyWindow
      required property var modelData
      screen: modelData
      readonly property int flightsHere: {
        var n = 0
        for (var f = 0; f < flightsModel.count; f++) if (flightsModel.get(f).screenName === (flyWindow.screen ? flyWindow.screen.name : "")) n++
        return n
      }
      visible: flightsHere > 0
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-minimized-flight"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}

      Repeater {
        model: flightsModel

        delegate: Rectangle {
          id: proxy
          required property var model
          required property int index
          visible: model.screenName === (flyWindow.screen ? flyWindow.screen.name : "")
          x: model.fromX; y: model.fromY; width: model.fromW; height: model.fromH
          radius: root.frameRadius
          color: Util.alpha(Color.popups.background, 0.96)
          border.width: 1
          border.color: Util.alpha(Color.accent, 0.7)
          clip: true

          Image {
            id: proxyImage
            anchors.fill: parent
            anchors.margins: 1
            source: proxy.model.thumb
            cache: false
            asynchronous: false
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            visible: status === Image.Ready
          }
          Image {
            anchors.centerIn: parent
            width: Math.min(Style.space(48), parent.height * 0.6); height: width
            source: proxy.model.icon
            sourceSize: Qt.size(width, height)
            visible: proxyImage.status !== Image.Ready && proxy.model.icon !== ""
            opacity: 0.85
          }

          ParallelAnimation {
            id: flightAnim
            property int duration: 320
            NumberAnimation { target: proxy; property: "x"; to: proxy.model.toX; duration: flightAnim.duration; easing.type: Easing.OutCubic }
            NumberAnimation { target: proxy; property: "y"; to: proxy.model.toY; duration: flightAnim.duration; easing.type: Easing.OutCubic }
            NumberAnimation { target: proxy; property: "width"; to: proxy.model.toW; duration: flightAnim.duration; easing.type: Easing.OutCubic }
            NumberAnimation { target: proxy; property: "height"; to: proxy.model.toH; duration: flightAnim.duration; easing.type: Easing.OutCubic }
            onFinished: settle.restart()
          }
          // Hold the landed picture a moment so the real tile / window is
          // there underneath before it goes.
          Timer { id: settle; interval: proxy.model.out ? 120 : 60; onTriggered: root.endFlight(proxy.model.address) }
          // A retarget restarts the motion from wherever the picture is now.
          property int seenGeneration: 0
          onModelChanged: if (model && model.generation !== seenGeneration) { seenGeneration = model.generation; settle.stop(); flightAnim.stop(); flightAnim.duration = 200; flightAnim.start() }
          Component.onCompleted: { if (proxy.visible) flightAnim.start(); else root.endFlight(proxy.model.address) }
        }
      }
    }
  }

  // Window capture through the compositor's toplevel export: the window's own
  // buffer, so nothing overlapping it (the dock, a flight) ends up in the
  // picture. minimize.lua asks for it over IPC and waits for the file.
  property var captureQueue: []
  property var capturing: null   // { address, path, toplevel }

  function toplevelFor(address) {
    var addr = String(address || "").toLowerCase().replace(/^0x/, "")
    var t = Hyprland.toplevels.values
    for (var i = 0; i < t.length; i++) {
      var a = String(t[i].address || "").toLowerCase().replace(/^0x/, "")
      if (a === addr) return t[i].wayland || null
    }
    return null
  }

  function requestCapture(address, path, w, h) {
    var tl = root.toplevelFor(address)
    if (!tl) return "no toplevel for " + address
    root.captureQueue = root.captureQueue.concat([{ address: address, path: path, toplevel: tl, w: Math.max(1, Number(w) || 1), h: Math.max(1, Number(h) || 1) }])
    root.nextCapture()
    return "ok"
  }

  function nextCapture() {
    if (root.capturing || root.captureQueue.length === 0) return
    var job = root.captureQueue[0]
    root.captureQueue = root.captureQueue.slice(1)
    root.capturing = job
    // The view takes the window's own size, so the grab is the window and
    // nothing else; the grab itself happens at the screen's pixel density.
    captureView.width = job.w
    captureView.height = job.h
    captureView.captureSource = job.toplevel
    captureTimeout.restart()
  }

  function finishCapture(ok) {
    captureTimeout.stop()
    captureView.captureSource = null
    var job = root.capturing
    root.capturing = null
    if (job) root.log("capture " + (ok ? "saved " : "FAILED ") + job.path)
    root.nextCapture()
  }

  Timer { id: captureTimeout; interval: 400; onTriggered: root.finishCapture(false) }

  PanelWindow {
    id: captureWindow
    visible: root.capturing !== null
    // Off-screen-ish: 1x1 at the top-left, no input, on the overlay layer.
    anchors { top: true; left: true }
    implicitWidth: 1
    implicitHeight: 1
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-minimized-capture"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    ScreencopyView {
      id: captureView
      live: false
      paintCursor: false
      width: 1
      height: 1
      x: -width
      onHasContentChanged: {
        if (!hasContent || !root.capturing) return
        var job = root.capturing
        captureView.grabToImage(function(result) {
          // Write to a temporary name and rename, so a reader never sees a
          // half-written file.
          var part = job.path + ".part.jpg"
          var ok = result && result.saveToFile(part)
          if (ok === true) Quickshell.execDetached(["mv", "-f", part, job.path])
          root.finishCapture(ok === true)
        })
      }
    }
  }

  IpcHandler {
    target: "minimized-tray"
    function capture(address: string, path: string, w: int, h: int): string { return root.requestCapture(address, path, w, h) }
    function toplevels(): string {
      var t = Hyprland.toplevels.values, w = ToplevelManager.toplevels.values
      return "hypr=" + t.length + " wayland=" + w.length + (t.length ? " first=" + t[0].address + " linked=" + (t[0].wayland ? "yes" : "no") : "")
    }
    function flyOut(payload: string): string { return root.startFlight(payload, true) }
    function flyIn(payload: string): string { return root.startFlight(payload, false) }
    function retarget(payload: string): string { return root.retargetFlight(payload) }
    function endFlight(): string { root.endFlight(""); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }
    function count(): string { return String(root.windows.length) }
    function focus(): string { root.toggleFocus(); return root.focusMode ? "focused" : "unfocused" }
    function focused(): string { return root.focusMode ? "true" : "false" }
    function select(delta: int): string { root.moveSelection(delta); return root.selectedAddress }
    function selected(): string { return root.selectedAddress }
    function restoreSelected(): string { root.restore(root.selectedAddress); return "ok" }
    function icon(appClass: string): string { return root.iconFor({ "class": appClass }) }
    function layout(): string { return String(root.dockGeometry.width) + "x" + String(root.dockGeometry.height) + " at x=" + String(root.dockGeometry.x) }
    // Debug: force the hover preview for tile <index> (-1 hides).
    function preview(index: int): string { root.hoverIndex = index; root.previewIndex = index; return "ok" }
  }
}
