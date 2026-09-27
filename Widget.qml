import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// 3 Finger Gestures: bar button + settings popup.
//
// The popup never writes Lua itself. Settings are persisted in this widget's
// inline shell.json entry (so `omarchy bar set threefinger.gestures <key>
// <value>` works too) and handed to threefinger-apply, which owns the
// generated ~/.config/hypr/gestures-settings.lua and reloads Hyprland.
Panel {
  id: root
  moduleName: "threefinger.gestures"
  ipcTarget: "threefinger.gestures"

  readonly property string applyPath: Qt.resolvedUrl("threefinger-apply").toString().replace("file://", "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var defaults: ({
    minimize: true, swipe_distance: 500, swipe_cancel_ratio: 0.12, swipe_min_speed_to_force: 25,
    slide_speed: 4.5, instant_keyboard_switch: true, persistent_workspaces: 5,
    tray_key: "SUPER + M", tray_max: 5, tray_thumbnails: true, tray_height: 0, tray_reserve_space: false
  })
  readonly property bool minimizeOn: get("minimize") === true

  // Windows currently in the tray, for the badge on the bar button.
  property int minimizedCount: 0

  function get(key) { return root.setting(key, root.defaults[key]) }

  function save(patch) {
    root.settings = Object.assign({}, root.settings, patch)
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    applyDebounce.restart()
  }

  function apply() {
    if (applyProc.running) { applyDebounce.restart(); return }
    var merged = Object.assign({}, root.defaults, root.settings || {})
    applyProc.command = [root.applyPath, JSON.stringify(merged)]
    applyProc.running = true
  }

  function refreshCount() { countProc.running = true }

  Timer { id: applyDebounce; interval: 350; onTriggered: root.apply() }

  Process {
    id: applyProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) console.warn("threefinger-apply:", text.trim()) }
  }

  Process {
    id: countProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var list = JSON.parse(text || "[]"); var n = 0
          for (var i = 0; i < list.length; i++) if (list[i].workspace && list[i].workspace.name === "special:minimized") n++
          root.minimizedCount = n
        } catch (e) {}
      }
    }
  }

  Timer { id: countDebounce; interval: 120; onTriggered: root.refreshCount() }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "movewindow" || name === "movewindowv2" || name === "openwindow" || name === "closewindow") countDebounce.restart()
    }
  }

  // Regenerate whenever the persisted settings change, including the first
  // hand-over from the shell: a freshly enabled widget starts empty, so this
  // is also what installs the Lua side on a new machine.
  onSettingsChanged: applyDebounce.restart()
  Component.onCompleted: { applyDebounce.restart(); refreshCount() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.minimizedCount > 0 ? "󱂬 " + root.minimizedCount : "󱂬"
    tooltipText: root.minimizedCount > 0
      ? root.minimizedCount + " minimized. Click for gesture settings, right-click for the tray keyboard."
      : "3 Finger Gestures settings. Right-click: tray keyboard."
    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.bar) root.bar.run("omarchy-shell minimized-tray focus") }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroSwitch.implicitHeight)
            Text {
              id: heroIcon
              text: "󱂬"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Column {
              id: heroLabels
              anchors { left: heroIcon.right; leftMargin: Style.space(14); right: heroSwitch.left; rightMargin: Style.space(10); verticalCenter: parent.verticalCenter }
              spacing: Style.space(2)
              Text { text: "3 Finger Gestures"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true; width: parent.width; elide: Text.ElideRight }
              Text {
                text: (root.minimizeOn ? "SWIPE · MINIMIZE · TRAY" : "WORKSPACE SWIPE ONLY") + (root.minimizedCount > 0 ? " · " + root.minimizedCount + " IN TRAY" : "")
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.2; width: parent.width; elide: Text.ElideRight
              }
            }
            ToggleSwitch {
              id: heroSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.minimizeOn
              foreground: root.foreground
              onToggled: root.save({ minimize: !root.minimizeOn })
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- Workspace swipe ----------
          PanelSectionHeader { text: "WORKSPACE SWIPE"; foreground: root.foreground; fontFamily: root.fontFamily }

          SettingSlider { label: "Follows fingers"; hint: "slow ← → fast"; minimum: 200; maximum: 1200; step: 50; integer: true
            value: 1400 - Number(root.get("swipe_distance")); onCommitted: function(v) { root.save({ swipe_distance: 1400 - v }) } }
          SettingSlider { label: "Swipe needed to commit"; hint: "little ← → a lot"; minimum: 0.05; maximum: 0.6; step: 0.01
            value: Number(root.get("swipe_cancel_ratio")); onCommitted: function(v) { root.save({ swipe_cancel_ratio: Math.round(v * 100) / 100 }) } }
          SettingSlider { label: "Glide speed"; hint: "0 turns the glide off"; minimum: 0; maximum: 10; step: 0.5
            value: Number(root.get("slide_speed")); onCommitted: function(v) { root.save({ slide_speed: v }) } }
          Toggle {
            width: parent.width; label: "Instant SUPER+1..0"; description: "Keyboard switches skip the glide."
            checked: root.get("instant_keyboard_switch") === true; foreground: root.foreground; fontFamily: root.fontFamily
            onClicked: root.save({ instant_keyboard_switch: root.get("instant_keyboard_switch") !== true })
          }
          SettingNumber { label: "Persistent workspaces"; from: 0; to: 10; value: Number(root.get("persistent_workspaces")); onCommitted: function(v) { root.save({ persistent_workspaces: v }) } }

          PanelSeparator { foreground: root.foreground }

          // ---------- Tray ----------
          Column {
            width: parent.width
            spacing: Style.space(12)
            opacity: root.minimizeOn ? 1.0 : 0.45
            Behavior on opacity { NumberAnimation { duration: 160 } }

            PanelSectionHeader { text: "MINIMIZE TRAY"; foreground: root.foreground; fontFamily: root.fontFamily }
            SettingNumber { label: "Capacity"; from: 1; to: 12; value: Number(root.get("tray_max")); onCommitted: function(v) { root.save({ tray_max: v }) } }
            Toggle {
              width: parent.width; label: "Thumbnails"; description: "A picture of each window in its tile. Taken as the window minimizes."
              checked: root.get("tray_thumbnails") === true; foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.save({ tray_thumbnails: root.get("tray_thumbnails") !== true })
            }
            Toggle {
              width: parent.width; label: "Reserve space"; description: "Tiled windows make room for the tray instead of it floating over the bottom edge."
              checked: root.get("tray_reserve_space") === true; foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.save({ tray_reserve_space: root.get("tray_reserve_space") !== true })
            }
            SettingNumber { label: "Height (0 = automatic)"; from: 0; to: 160; stepSize: 4; value: Number(root.get("tray_height")); onCommitted: function(v) { root.save({ tray_height: v }) } }
            Dropdown {
              width: parent.width
              label: "Tray keyboard key"
              options: ["SUPER + M", "SUPER + SHIFT + M", "SUPER + N", "none"]
              value: String(root.get("tray_key"))
              foreground: root.foreground
              fontFamily: root.fontFamily
              onValueChanged: if (value && value !== String(root.get("tray_key"))) root.save({ tray_key: value })
            }
          }

          Text {
            width: parent.width
            text: "Also from a terminal: omarchy bar set threefinger.gestures <key> <value>"
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ---------- small helpers ----------
  component SettingSlider: Column {
    property string label: ""
    property string hint: ""
    property real minimum: 0
    property real maximum: 1
    property real step: 0.05
    property bool integer: false
    property real value: 0
    signal committed(real value)
    width: parent ? parent.width : 0
    spacing: Style.space(4)
    Row {
      width: parent.width
      Text { text: label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; width: parent.width * 0.55; elide: Text.ElideRight }
      Text { text: hint; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; width: parent.width * 0.45; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft }
    }
    Item {
      width: parent.width
      height: Style.spacing.controlHeight
      PanelSlider {
        id: slider
        bar: root.bar
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        minimum: parent.parent.minimum
        maximum: parent.parent.maximum
        step: parent.parent.step
        integer: parent.parent.integer
        value: parent.parent.value
        onReleased: function(v) { parent.parent.committed(v) }
      }
    }
  }

  component SettingNumber: NumberField {
    signal committed(int value)
    width: parent ? parent.width : 0
    foreground: root.foreground
    accent: Color.accent
    fontFamily: root.fontFamily
    onModified: function(v) { committed(v) }
  }
}
