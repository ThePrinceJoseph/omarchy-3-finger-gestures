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
  // A value field is being typed into: keep the popup's key handling off it.
  property bool editingValue: false

  function get(key) { return root.setting(key, root.defaults[key]) }

  // Sliders show a plain 0.00–1.00 scale (two decimals), so a setting you
  // liked is easy to remember and get back to; click the number to type one. Each maps to the real config
  // range here; the recommended stop is where the default lands.
  //   follow  0 = the screen lags far behind your fingers (distance 900)
  //           1 = it sticks to them (distance 233); 0.60 = default 500
  //   commit  ratio = 0.02 + d * 0.5;   0.20 = default 0.12
  //   flick   speed = d * 100;          0.25 = default 25; 0 = off
  //   glide   speed = 1 + d * 7;        0.50 = default 4.5; 0 = no glide
  readonly property var scales: ({
    follow: { rec: 0.60, toConfig: function(d) { return Math.round(900 - d * 666.67) },
              fromConfig: function(c) { return (900 - Number(c)) / 666.67 } },
    commit: { rec: 0.20, toConfig: function(d) { return Math.round((0.02 + d * 0.5) * 100) / 100 },
              fromConfig: function(c) { return (Number(c) - 0.02) / 0.5 } },
    flick:  { rec: 0.25, toConfig: function(d) { return Math.round(d * 100) },
              fromConfig: function(c) { return Number(c) / 100 } },
    glide:  { rec: 0.50, toConfig: function(d) { return d <= 0 ? 0 : Math.round((1 + d * 7) * 10) / 10 },
              fromConfig: function(c) { return Number(c) <= 0 ? 0 : (Number(c) - 1) / 7 } }
  })
  function snap(d) { return Math.max(0, Math.min(1, Math.round(d * 100) / 100)) }
  function display(scale, key) { return root.snap(root.scales[scale].fromConfig(root.get(key))) }

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
      blocked: root.editingValue
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
          spacing: Style.space(14)

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

          SettingSlider { label: "Follows your fingers"; low: "lags"; high: "sticks"; recommended: root.scales.follow.rec
            value: root.display("follow", "swipe_distance"); onCommitted: function(d) { root.save({ swipe_distance: root.scales.follow.toConfig(d) }) } }
          SettingSlider { label: "Swipe needed to commit"; low: "a nudge"; high: "a long swipe"; recommended: root.scales.commit.rec
            value: root.display("commit", "swipe_cancel_ratio"); onCommitted: function(d) { root.save({ swipe_cancel_ratio: root.scales.commit.toConfig(d) }) } }
          SettingSlider { label: "Flick commits"; low: "off"; high: "any flick"; recommended: root.scales.flick.rec; zeroText: "off"
            value: root.display("flick", "swipe_min_speed_to_force"); onCommitted: function(d) { root.save({ swipe_min_speed_to_force: root.scales.flick.toConfig(d) }) } }
          SettingSlider { label: "Glide after letting go"; low: "slow"; high: "quick"; recommended: root.scales.glide.rec; zeroText: "off"
            value: root.display("glide", "slide_speed"); onCommitted: function(d) { root.save({ slide_speed: root.scales.glide.toConfig(d) }) } }
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
    id: row
    property string label: ""
    property string low: ""
    property string high: ""
    property string zeroText: ""
    property real recommended: 0.5
    property real value: 0
    signal committed(real value)
    readonly property real shown: slider.dragging ? root.snap(slider.liveValue) : value
    function text(v) { return (v <= 0 && zeroText) ? zeroText : v.toFixed(2) }
    width: parent ? parent.width : 0
    spacing: Style.space(2)

    Item {
      width: parent.width
      height: labelText.implicitHeight
      Text { id: labelText; text: row.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; anchors.left: parent.left; width: parent.width - valueText.width - Style.space(8); elide: Text.ElideRight }
      // Live readout: the value under your finger while dragging, else the set
      // one. Click it to type a value (up to two decimals, 0 to 1).
      Item {
        id: valueText
        anchors.right: parent.right
        width: Math.max(readout.implicitWidth, editBox.width)
        height: labelText.implicitHeight
        property bool editing: false
        function startEdit() {
          editField.text = row.text(row.shown) === row.zeroText ? "0.00" : row.shown.toFixed(2)
          valueText.editing = true
          root.editingValue = true
          editField.forceActiveFocus()
          editField.selectAll()
        }
        function finishEdit(commit) {
          if (commit) {
            var v = parseFloat(editField.text)
            if (!isNaN(v)) row.committed(Math.max(0, Math.min(1, Math.round(v * 100) / 100)))
          }
          valueText.editing = false
          root.editingValue = false
        }
        Text {
          id: readout
          anchors.right: parent.right
          visible: !valueText.editing
          text: row.text(row.shown) + (Math.abs(row.shown - row.recommended) < 0.001 ? "  ✓" : "")
          color: slider.dragging ? Color.accent : (readoutMouse.containsMouse ? Color.accent : root.foreground)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: slider.dragging
          font.underline: readoutMouse.containsMouse
        }
        MouseArea { id: readoutMouse; anchors.fill: readout; hoverEnabled: true; cursorShape: Qt.IBeamCursor; visible: !valueText.editing; onClicked: valueText.startEdit() }
        Rectangle {
          id: editBox
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: valueText.editing
          width: Style.space(56)
          height: labelText.implicitHeight + Style.space(6)
          radius: Style.space(4)
          color: Util.alpha(Color.accent, 0.12)
          border.width: 1
          border.color: Color.accent
          TextInput {
            id: editField
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            verticalAlignment: TextInput.AlignVCenter
            horizontalAlignment: TextInput.AlignRight
            color: root.foreground
            selectionColor: Util.alpha(Color.accent, 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            // Only shapes like 0.47, .5, 1, 1.00 — two decimals at most.
            validator: RegularExpressionValidator { regularExpression: /^(0?\.[0-9]{0,2}|0|1(\.0{0,2})?)$/ }
            onAccepted: valueText.finishEdit(true)
            Keys.onEscapePressed: valueText.finishEdit(false)
            // Clicking elsewhere cancels; only Enter commits.
            onActiveFocusChanged: if (!activeFocus && valueText.editing) valueText.finishEdit(false)
          }
        }
      }
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
        minimum: 0
        maximum: 1
        step: 0.01
        value: row.value
        onReleased: function(v) { row.committed(root.snap(v)) }
      }
      // Recommended stop: a marker under the track. Click it to go back.
      Item {
        id: marker
        readonly property real frac: row.recommended
        // Same clamp PanelSlider uses for its knob, so the arrow sits under it.
        readonly property real centreX: slider.x + Math.max(0, Math.min(slider.width - slider.knobSize, slider.width * frac - slider.knobSize / 2)) + slider.knobSize / 2
        // Keep the label inside the row: it hangs right of the arrow unless
        // that would run off the edge, then left.
        readonly property bool labelRight: centreX + Style.space(10) + markerLabel.implicitWidth < parent.width
        x: labelRight ? centreX - Style.space(7) : centreX + Style.space(7) - width
        anchors.top: parent.verticalCenter
        anchors.topMargin: slider.trackHeight / 2 + Style.space(3)
        width: Style.space(14) + Style.space(4) + markerLabel.implicitWidth
        height: Style.space(12)
        readonly property color tone: Math.abs(row.shown - row.recommended) < 0.001 ? Color.accent : root.dim
        Text {
          id: markerArrow
          x: marker.labelRight ? 0 : parent.width - width
          anchors.verticalCenter: parent.verticalCenter
          text: "▲"
          color: marker.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          id: markerLabel
          x: marker.labelRight ? markerArrow.width + Style.space(4) : 0
          anchors.verticalCenter: parent.verticalCenter
          text: "recommended"
          color: marker.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: row.committed(row.recommended) }
      }
    }

    Item {
      width: parent.width
      height: lowText.implicitHeight + Style.space(6)
      Text { id: lowText; anchors.bottom: parent.bottom; text: row.low; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.left: parent.left; anchors.leftMargin: Style.space(6) }
      Text { anchors.bottom: parent.bottom; text: row.high; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.right: parent.right; anchors.rightMargin: Style.space(6) }
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
