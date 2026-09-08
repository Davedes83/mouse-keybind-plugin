import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "davedes.mouse-keybind-settings"
  ipcTarget: "davedes.mouse-keybind-settings"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent

  // Mouse settings state
  property var status: ({
    devices: [],
    primaryDevice: "Standard Mouse",
    sensitivity: 0.0,
    accel_profile: "adaptive",
    is_flat: false,
    follow_mouse: 1,
    natural_scroll: false,
    left_handed: false,
    scroll_factor: 1.0,
    mouse_refocus: true,
    button_mappings: {
      side_back: "default",
      side_forward: "default",
      middle_click: "default",
      super_left: "move_window",
      super_right: "resize_window",
      super_wheel: "workspace_scroll"
    }
  })

  property string activeTab: "mouse"
  property bool isSaving: false
  property string lastActionNote: ""

  // Buy Me a Coffee button visibility, persisted to a small config file.
  property bool showBuyButton: true

  function buyMeACoffeeUrl() {
    return "https://www.paypal.com/paypalme/DavidDesousa13"
  }

  readonly property string settingsDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"
  readonly property string settingsPath: root.settingsDir + "/davedes.mouse-keybind-settings.json"

  function setShowBuyButton(v) {
    root.showBuyButton = !!v
    // Read-modify-write: the same file also carries keybindConflictMode
    // (written by KeybindsPanel), so never overwrite keys we don't own.
    var data = {}
    try {
      var cur = JSON.parse(buyButtonFile.text())
      if (Util.isPlainObject(cur)) data = cur
    } catch (e) { /* missing or corrupt file -> start fresh */ }
    data.showBuyButton = root.showBuyButton
    root.writePluginSettings(JSON.stringify(data, null, 2) + "\n")
  }

  // Writes go through a mkdir -p first so a fresh machine (no state dir yet)
  // still persists; the latest pending text wins if several writes queue up.
  property string pendingSettingsText: ""

  function writePluginSettings(text) {
    root.pendingSettingsText = text
    if (!settingsDirProc.running) settingsDirProc.running = true
  }

  BoundedProcess {
    id: settingsDirProc
    command: ["mkdir", "-p", root.settingsDir]
    timeoutMs: 5000
    onFinished: {
      if (root.pendingSettingsText.length > 0) {
        buyButtonFile.setText(root.pendingSettingsText)
        root.pendingSettingsText = ""
      }
    }
  }

  function applyPluginSettings(raw) {
    try {
      var data = JSON.parse(raw)
      if (Util.isPlainObject(data) && typeof data.showBuyButton === "boolean") root.showBuyButton = data.showBuyButton
    } catch (e) { /* keep default */ }
  }

  // Persisted plugin settings (shared with KeybindsPanel.qml).
  FileView {
    id: buyButtonFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyPluginSettings(text())
    onLoadFailed: { /* file absent -> use default */ }
  }

  Component.onCompleted: settingsDirProc.running = true

  // Keybind panel references
  property var keybindData: ({})
  property bool keybindLoaded: false
  property string kbSearchQuery: ""
  property string currentKbTab: "active" // "active" | "modified" | "catalog" | "conflicts"
  property string currentKbCategory: "All"

  readonly property var kbCategories: [
    "All", "Window Management", "Workspaces", "Menus & System", "Applications", "Media & Audio"
  ]

  // Filtered Active keybindings (matches full-manager "All Active" tab)
  readonly property var filteredKbActive: root.recomputeKbActive()

  // Filtered Modified & Custom keybindings
  readonly property var filteredKbModified: root.recomputeKbModified()

  // Filtered Catalog presets
  readonly property var filteredKbCatalog: root.recomputeKbCatalog()

  // Filtered Conflicts
  readonly property var filteredKbConflicts: root.keybindData.conflicts || []

  function matchesKb(item, q) {
    return (item.key && item.key.toLowerCase().indexOf(q) !== -1) ||
      (item.description && item.description.toLowerCase().indexOf(q) !== -1) ||
      ((item.command && item.command.toLowerCase().indexOf(q) !== -1) ||
       (item.action && item.action.toLowerCase().indexOf(q) !== -1)) ||
      (item.category && item.category.toLowerCase().indexOf(q) !== -1)
  }

  function recomputeKbActive() {
    var list = root.keybindData && root.keybindData.active ? root.keybindData.active : []
    var q = root.kbSearchQuery.trim().toLowerCase()
    var cat = root.currentKbCategory
    var res = []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (cat !== "All" && item.category !== cat) continue
      if (q.length > 0 && !root.matchesKb(item, q)) continue
      res.push(item)
    }
    return res
  }

  function recomputeKbModified() {
    var list = root.keybindData && root.keybindData.active ? root.keybindData.active : []
    var q = root.kbSearchQuery.trim().toLowerCase()
    var cat = root.currentKbCategory
    var res = []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (item.status !== "modified" && item.status !== "custom") continue
      if (cat !== "All" && item.category !== cat) continue
      if (q.length > 0 && !root.matchesKb(item, q)) continue
      res.push(item)
    }
    return res
  }

  function recomputeKbCatalog() {
    var list = root.keybindData && root.keybindData.catalog ? root.keybindData.catalog : []
    var q = root.kbSearchQuery.trim().toLowerCase()
    var cat = root.currentKbCategory
    var res = []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (cat !== "All" && item.category !== cat) continue
      if (q.length > 0) {
        var hit = (item.name && item.name.toLowerCase().indexOf(q) !== -1) ||
          (item.description && item.description.toLowerCase().indexOf(q) !== -1) ||
          (item.default_key && item.default_key.toLowerCase().indexOf(q) !== -1)
        if (!hit) continue
      }
      res.push(item)
    }
    return res
  }

  function focusKbSearch() {
    Qt.callLater(function() { if (kbSearchInput) kbSearchInput.forceActiveFocus() })
  }

  function clearKbSearch() {
    root.kbSearchQuery = ""
    if (kbSearchInput) kbSearchInput.text = ""
    root.focusKbSearch()
  }

  function refreshKeybindData() {
    root.fetchKeybindSummary()
  }

  onCurrentKbTabChanged: function() { root.focusKbSearch() }
  onCurrentKbCategoryChanged: function() { root.focusKbSearch() }
  onActiveTabChanged: function() {
    if (root.activeTab === "keybinds") root.focusKbSearch()
  }
  onOpenedChanged: function() {
    if (root.opened && root.activeTab === "keybinds") root.focusKbSearch()
  }

  function scriptPath() {
    return Qt.resolvedUrl("mouse_ctl.py").toString().replace(/^file:\/\//, "")
  }

  function fetchStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function fetchKeybindSummary() {
    if (!keybindSummaryProc.running) keybindSummaryProc.running = true
  }

  function updateButtonMapping(key, nextVal) {
    var mappings = {}
    if (root.status && root.status.button_mappings) {
      for (var k in root.status.button_mappings) mappings[k] = root.status.button_mappings[k]
    }
    mappings[key] = nextVal
    root.applySettings({ button_mappings: mappings })
  }

  function applySettings(newValues) {
    var updated = {}
    for (var k in root.status) updated[k] = root.status[k]
    for (var n in newValues) updated[n] = newValues[n]
    root.status = updated
    root.isSaving = true
    applyProc.command = ["python3", root.scriptPath(), "apply", "--json-data", JSON.stringify(newValues)]
    applyProc.running = true
  }

  property double lastToggleMs: 0

  function toggleAccelMode() {
    var now = Date.now()
    if (now - lastToggleMs < 300) return
    lastToggleMs = now
    if (!toggleAccelProc.running) toggleAccelProc.running = true
  }

  property double lastSimMs: 0

  function simLabel(name) {
    if (name === "left") return "Left Btn"
    if (name === "right") return "Right Btn"
    if (name === "middle") return "Middle Btn (274)"
    if (name === "side_back") return "Side Btn 1 (Bck / 275)"
    if (name === "side_forward") return "Side Btn 2 (Fwd / 276)"
    return name
  }

  function simulateButton(name) {
    var now = Date.now()
    if (now - lastSimMs < 300) return
    lastSimMs = now
    simulateProc.command = ["python3", root.scriptPath(), "simulate-button", "--button", name]
    if (!simulateProc.running) simulateProc.running = true
  }
  function toggleNaturalScroll() {
    toggleScrollProc.running = true
  }

  function resetDefaults() {
    resetProc.running = true
  }

  function openMouseConfigEditor() {
    configEditorProc.running = true
  }

  function summonKeybindManager() {
    summonKbProc.command = ["omarchy-shell", "shell", "summon", "davedes.mouse-keybind-settings", "{}"]
    summonKbProc.running = true
    root.close()
  }

  // Summon the full manager with the row to edit. Accepts a model row (preferred,
  // carries the stable id) or a bare key string for older callers.
  function requestEditKeybinding(row) {
    var r = (typeof row === "string") ? { key: row } : (row || {})
    var payload = JSON.stringify({ edit: r.key || "", id: Model.rowId(r) })
    summonKbProc.command = ["omarchy-shell", "shell", "summon", "davedes.mouse-keybind-settings", payload]
    summonKbProc.running = true
    root.close()
  }

  // Periodic poll & initial query
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      root.fetchStatus()
      root.fetchKeybindSummary()
    }
  }

  IpcHandler {
    enabled: true
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleAccel(): void { root.toggleAccelMode() }
  }

  // Mouse settings processes (bounded: capped output, wall-clock deadline,
  // whole-process-group termination on timeout/overflow)
  BoundedProcess {
    id: statusProc
    running: true
    command: ["python3", root.scriptPath(), "status"]
    maxBytes: 262144
    timeoutMs: 5000
    onFinished: {
      if (!success) return
      var output = stdout || ""
      try {
        var data = JSON.parse(output)
        root.status = data
      } catch (e) {
        // ignore transient parse error
      }
    }
  }

  BoundedProcess {
    id: applyProc
    maxBytes: 262144
    timeoutMs: 30000
    onFinished: {
      root.isSaving = false
      var output = stdout || ""
      if (success) {
        try {
          var data = JSON.parse(output)
          if (data.success) {
            root.lastActionNote = "Saved"
          } else {
            root.lastActionNote = data.error ? "Error" : "Failed"
          }
        } catch (e) {
          root.lastActionNote = "Saved"
        }
      } else {
        root.lastActionNote = "Error"
      }
      clearNoteTimer.restart()
    }
  }

  BoundedProcess {
    id: toggleAccelProc
    command: ["python3", root.scriptPath(), "toggle-accel"]
    timeoutMs: 15000
    onFinished: root.fetchStatus()
  }

  BoundedProcess {
    id: toggleScrollProc
    command: ["python3", root.scriptPath(), "toggle-natural-scroll"]
    timeoutMs: 15000
    onFinished: root.fetchStatus()
  }

  BoundedProcess {
    id: resetProc
    command: ["python3", root.scriptPath(), "reset-defaults"]
    timeoutMs: 15000
    onFinished: root.fetchStatus()
  }

  BoundedProcess {
    id: simulateProc
    maxBytes: 262144
    timeoutMs: 15000
    onFinished: {
      if (!success) {
        root.lastActionNote = "Sim N/A"
        clearNoteTimer.restart()
        return
      }
      var output = stdout || ""
      try {
        var data = JSON.parse(output)
        if (data.success) {
          testBox.clickCount += 1
          testBox.testMsg = "Simulated " + root.simLabel(data.button) + " (#" + testBox.clickCount + ")"
          root.lastActionNote = "Sent"
        } else {
          root.lastActionNote = "Sim N/A"
        }
      } catch (e) {
        root.lastActionNote = "Sim N/A"
      }
      clearNoteTimer.restart()
    }
  }

  Process {
    id: configEditorProc
    command: ["omarchy-launch-config-editor", Quickshell.env("HOME") + "/.config/hypr/input.lua"]
  }

  Process {
    id: buyProc
    command: ["xdg-open", root.buyMeACoffeeUrl()]
  }

  Process {
    id: summonKbProc
  }

  // Keybind summary process (bounded)
  BoundedProcess {
    id: keybindSummaryProc
    command: [
      Quickshell.env("HOME") + "/.config/omarchy/plugins/davedes.mouse-keybind-settings/backend/keybinds_manager.py",
      "list"
    ]
    maxBytes: 262144
    timeoutMs: 10000
    onFinished: {
      root.keybindLoaded = true
      if (!success) return
      var text = stdout || ""
      if (text && text.trim().length > 0) {
        try {
          var parsed = JSON.parse(text)
          if (parsed) root.keybindData = parsed
        } catch (e) {
          // ignore
        }
      }
    }
  }

  Timer {
    id: clearNoteTimer
    interval: 2000
    onTriggered: root.lastActionNote = ""
  }

  // Top Bar Icon Button
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍽"
    tooltipText: "Mouse & Keybind Settings"
    active: root.status && root.status.accel_profile === "flat"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        root.toggleAccelMode()
      } else {
        root.toggle()
      }
    }
  }

  // Popup Settings Panel. Uses KeyboardPanel (layer-shell) rather than
  // PopupCard (xdg-popup) because xdg-popups only receive keyboard keys after
  // a click routes focus — the dropdown would never accept typed search input.
  // KeyboardPanel primes WlrKeyboardFocus on open and routes keys to focusTarget.
  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: root.activeTab === "keybinds" ? kbSearchInput : null
    contentWidth: root.activeTab === "keybinds" ? Style.space(560) : Style.space(420)
    contentHeight: Style.space(700)

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(10)

      // Header Row
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)

        Text {
          text: "󰍽"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.space(28)
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.space(2)

          Text {
            text: "Mouse & Keybind"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            text: "Pointer settings & shortcut manager"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
        }
      }

      // Main Tab Navigation (Mouse | Keybinds)
      BorderSurface {
        Layout.fillWidth: true
        implicitHeight: Style.space(36)
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.foreground, root.accent)

        RowLayout {
          anchors.fill: parent
          spacing: Style.space(2)

          // Tab: Mouse
          BorderSurface {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: root.activeTab === "mouse" ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"

            RowLayout {
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                text: "󰍽"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: "Mouse Settings"
                color: root.activeTab === "mouse" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.activeTab === "mouse"
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = "mouse"
            }
          }

          // Tab: Keybinds
          BorderSurface {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: root.activeTab === "keybinds" ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"

            RowLayout {
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: "Keybinds"
                color: root.activeTab === "keybinds" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.activeTab === "keybinds"
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = "keybinds"
            }
          }
        }
      }

      PanelSeparator {
        Layout.fillWidth: true
      }

      // Content Area
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        // ===================== MOUSE TAB =====================
        ColumnLayout {
          anchors.fill: parent
          visible: root.activeTab === "mouse"
          spacing: Style.space(8)

          // Device + Config header
          RowLayout {
            Layout.fillWidth: true

            Text {
              text: Model.formatDeviceName(root.status.primaryDevice) + Model.formatBattery(root.status.battery, false)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              Layout.fillWidth: true
            }

            BorderSurface {
              implicitWidth: Style.space(28)
              implicitHeight: Style.space(28)
              radius: Style.cornerRadius
              color: editIconHover.containsMouse ? Style.normalFillFor(root.foreground, root.accent) : "transparent"
              borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

              Text {
                anchors.centerIn: parent
                text: "󰒓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: editIconHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openMouseConfigEditor()
              }
            }
          }

          // Mouse settings (single scrollable list: motion, scrolling, buttons)
          ScrollView {
            id: mouseScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            WheelHandler {
              target: mouseScroll.contentItem
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: function(event) {
                var dy = event.angleDelta.y
                if (dy === 0) dy = event.pixelDelta.y
                var step = (dy / 120.0) * 100.0
                var flick = mouseScroll.contentItem
                if (flick && flick.contentY !== undefined) {
                  var newY = flick.contentY - step
                  var maxY = Math.max(0, flick.contentHeight - flick.height)
                  flick.contentY = Math.max(0, Math.min(maxY, newY))
                  event.accepted = true
                }
              }
            }

            ColumnLayout {
              width: mouseScroll.availableWidth
              spacing: Style.space(8)
              Layout.alignment: Qt.AlignTop

            // --- MOTION ---
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text {
                text: "Motion"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)

                RowLayout {
                  Layout.fillWidth: true
                  Text {
                    text: "Cursor Speed"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    text: Model.formatSpeed(root.status.sensitivity)
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Text { text: "🐢"; font.pixelSize: Style.font.caption; Layout.alignment: Qt.AlignVCenter }

                  PanelSlider {
                    Layout.fillWidth: true
                    bar: root.bar
                    minimum: -1.0
                    maximum: 1.0
                    step: 0.05
                    value: root.status.sensitivity
                    onReleased: function(v) {
                      root.applySettings({ sensitivity: Math.round(v * 100) / 100 })
                    }
                  }

                  Text { text: "🚀"; font.pixelSize: Style.font.caption; Layout.alignment: Qt.AlignVCenter }
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)

                Text {
                  text: "Pointer Movement Style"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  BorderSurface {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(54)
                    radius: Style.cornerRadius
                    color: root.status.accel_profile === "flat" ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
                    borderSpec: Border.controlSpec(root.status.accel_profile === "flat" ? "selected" : "normal", root.foreground, root.accent)

                    ColumnLayout {
                      anchors.centerIn: parent
                      spacing: 1

                      RowLayout {
                        spacing: 3
                        Text { text: "󰓅"; color: root.foreground; font.family: root.fontFamily }
                        Text { text: "Precision (1:1)"; color: root.foreground; font.bold: true; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1 }
                      }
                      Text { text: "Gaming & Design"; color: root.dim; font.pixelSize: Style.space(8); font.family: root.fontFamily }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.applySettings({ accel_profile: "flat" })
                    }
                  }

                  BorderSurface {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(54)
                    radius: Style.cornerRadius
                    color: root.status.accel_profile !== "flat" ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
                    borderSpec: Border.controlSpec(root.status.accel_profile !== "flat" ? "selected" : "normal", root.foreground, root.accent)

                    ColumnLayout {
                      anchors.centerIn: parent
                      spacing: 1

                      RowLayout {
                        spacing: 3
                        Text { text: "📈"; font.pixelSize: Style.font.caption - 1 }
                        Text { text: "Dynamic"; color: root.foreground; font.bold: true; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1 }
                      }
                      Text { text: "Adaptive Speed"; color: root.dim; font.pixelSize: Style.space(8); font.family: root.fontFamily }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.applySettings({ accel_profile: "adaptive" })
                    }
                  }
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Left-Handed Mode"
                description: "Swap primary / secondary click"
                checked: root.status.left_handed
                onClicked: root.applySettings({ left_handed: !root.status.left_handed })
              }

              Item { Layout.fillHeight: true }
            }

            // --- SCROLLING ---
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text {
                text: "Scrolling"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Toggle {
                Layout.fillWidth: true
                label: "Natural (Mobile) Scrolling"
                description: "Wheel down scrolls content down"
                checked: root.status.natural_scroll
                onClicked: root.applySettings({ natural_scroll: !root.status.natural_scroll })
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)

                RowLayout {
                  Layout.fillWidth: true
                  Text {
                    text: "Scroll Speed Multiplier"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    text: Model.formatScrollSpeed(root.status.scroll_factor)
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Text { text: "🐌"; font.pixelSize: Style.font.caption; Layout.alignment: Qt.AlignVCenter }

                  PanelSlider {
                    Layout.fillWidth: true
                    bar: root.bar
                    minimum: 0.2
                    maximum: 8.0
                    step: 0.2
                    value: root.status.scroll_factor
                    onReleased: function(v) {
                      root.applySettings({ scroll_factor: Math.round(v * 10) / 10 })
                    }
                  }

                  Text { text: "⚡"; font.pixelSize: Style.font.caption; Layout.alignment: Qt.AlignVCenter }
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Focus Follows Cursor"
                checked: root.status.follow_mouse > 0
                onClicked: root.applySettings({ follow_mouse: root.status.follow_mouse > 0 ? 0 : 1 })
              }

              Toggle {
                Layout.fillWidth: true
                label: "Auto-Refocus on Close"
                description: "Refocus window under cursor"
                checked: root.status.mouse_refocus
                onClicked: root.applySettings({ mouse_refocus: !root.status.mouse_refocus })
              }

              Item { Layout.fillHeight: true }
            }

            // --- BUTTONS ---
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text {
                text: "Buttons"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Text {
                text: "Mouse Button Mapping"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              // Side Back
              RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.spacing.controlHeight
                spacing: Style.space(12)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  Text {
                    text: "󰍽 Side Btn 1 (Bck)"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    text: "Physical btn 275"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(9)
                    elide: Text.ElideRight
                  }
                }

                Dropdown {
                  Layout.preferredWidth: Style.space(170)
                  Layout.alignment: Qt.AlignVCenter
                  showLabel: false
                  value: root.status.button_mappings ? root.status.button_mappings.side_back : "default"
                  options: Model.sideBackOptions()
                  onChanged: function(val) { root.updateButtonMapping("side_back", val) }
                }
              }

              // Side Forward
              RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.spacing.controlHeight
                spacing: Style.space(12)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  Text {
                    text: "󰍽 Side Btn 2 (Fwd)"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    text: "Physical btn 276"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(9)
                    elide: Text.ElideRight
                  }
                }

                Dropdown {
                  Layout.preferredWidth: Style.space(170)
                  Layout.alignment: Qt.AlignVCenter
                  showLabel: false
                  value: root.status.button_mappings ? root.status.button_mappings.side_forward : "default"
                  options: Model.sideForwardOptions()
                  onChanged: function(val) { root.updateButtonMapping("side_forward", val) }
                }
              }

              // Middle Click
              RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.spacing.controlHeight
                spacing: Style.space(12)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  Text {
                    text: "󰍽 Middle Btn (Wheel)"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    text: "Physical btn 274"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(9)
                    elide: Text.ElideRight
                  }
                }

                Dropdown {
                  Layout.preferredWidth: Style.space(170)
                  Layout.alignment: Qt.AlignVCenter
                  showLabel: false
                  value: root.status.button_mappings ? root.status.button_mappings.middle_click : "default"
                  options: Model.middleClickOptions()
                  onChanged: function(val) { root.updateButtonMapping("middle_click", val) }
                }
              }

              PanelSeparator { Layout.fillWidth: true }

              // Super + Left Drag: Move Window
              RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.spacing.controlHeight
                spacing: Style.space(12)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  Text {
                    text: "Super + Left Drag"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    text: "Move window"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(9)
                    elide: Text.ElideRight
                  }
                }

                Item {
                  Layout.preferredWidth: Style.space(170)
                  Layout.preferredHeight: Style.spacing.controlHeight
                  Layout.alignment: Qt.AlignVCenter

                  ToggleSwitch {
                    anchors.centerIn: parent
                    checked: root.status.button_mappings ? (root.status.button_mappings.super_left !== "disabled") : true
                    onToggled: {
                      var cur = root.status.button_mappings ? root.status.button_mappings.super_left : "move_window"
                      root.updateButtonMapping("super_left", cur === "disabled" ? "move_window" : "disabled")
                    }
                  }
                }
              }

              // Super + Right Drag: Resize Window
              RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.spacing.controlHeight
                spacing: Style.space(12)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  Text {
                    text: "Super + Right Drag"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    text: "Resize window"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(9)
                    elide: Text.ElideRight
                  }
                }

                Item {
                  Layout.preferredWidth: Style.space(170)
                  Layout.preferredHeight: Style.spacing.controlHeight
                  Layout.alignment: Qt.AlignVCenter

                  ToggleSwitch {
                    anchors.centerIn: parent
                    checked: root.status.button_mappings ? (root.status.button_mappings.super_right !== "disabled") : true
                    onToggled: {
                      var cur = root.status.button_mappings ? root.status.button_mappings.super_right : "resize_window"
                      root.updateButtonMapping("super_right", cur === "disabled" ? "resize_window" : "disabled")
                    }
                  }
                }
              }

              // Super + Scroll: Switch Workspaces
              RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.spacing.controlHeight
                spacing: Style.space(12)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1

                  Text {
                    text: "Super + Scroll"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    text: "Switch workspaces"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(9)
                    elide: Text.ElideRight
                  }
                }

                Item {
                  Layout.preferredWidth: Style.space(170)
                  Layout.preferredHeight: Style.spacing.controlHeight
                  Layout.alignment: Qt.AlignVCenter

                  ToggleSwitch {
                    anchors.centerIn: parent
                    checked: root.status.button_mappings ? (root.status.button_mappings.super_wheel !== "disabled") : true
                    onToggled: {
                      var cur = root.status.button_mappings ? root.status.button_mappings.super_wheel : "workspace_scroll"
                      root.updateButtonMapping("super_wheel", cur === "disabled" ? "workspace_scroll" : "disabled")
                    }
                  }
                }
              }

              Text {
                text: "Simulate Button Press"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Repeater {
                  model: Model.simulateButtons()

                  delegate: BorderSurface {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(38)
                    radius: Style.cornerRadius
                    color: simArea.containsMouse ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
                    borderSpec: Border.controlSpec(simArea.containsMouse ? "hover-cursor" : "normal", root.foreground, root.accent)

                    Text {
                      anchors.centerIn: parent
                      text: modelData.label
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    MouseArea {
                      id: simArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.simulateButton(modelData.value)
                    }
                  }
                }
              }

              // Interactive Test Box
              BorderSurface {
                id: testBox
                Layout.fillWidth: true
                implicitHeight: Style.space(36)
                radius: Style.cornerRadius
                color: testArea.containsMouse ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
                borderSpec: Border.controlSpec(testArea.containsMouse ? "hover-cursor" : "normal", root.foreground, root.accent)

                property string testMsg: "Click or scroll here to test"
                property int clickCount: 0

                RowLayout {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: "󰛤"
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    text: testBox.testMsg
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                MouseArea {
                  id: testArea
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton
                  cursorShape: Qt.PointingHandCursor

                  onClicked: function(mouse) {
                    testBox.clickCount += 1
                    var bName = "Left Btn"
                    if (mouse.button === Qt.RightButton) bName = "Right Btn"
                    else if (mouse.button === Qt.MiddleButton) bName = "Middle Btn (274)"
                    else if (mouse.button === Qt.BackButton) bName = "Side Btn 1 (Bck / 275)"
                    else if (mouse.button === Qt.ForwardButton) bName = "Side Btn 2 (Fwd / 276)"
                    testBox.testMsg = bName + " (#" + testBox.clickCount + ")"
                  }

                  onWheel: function(wheel) {
                    var dir = wheel.angleDelta.y > 0 ? "Up" : "Down"
                    testBox.testMsg = "Scrolled " + dir + " (Delta: " + wheel.angleDelta.y + ")"
                  }
                }
              }
            }
          }
        }

          // Hide / show the Buy Me a Coffee button
          RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.spacing.controlHeight
            spacing: Style.space(12)

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 1

              Text {
                Layout.fillWidth: true
                text: "Buy Me a Coffee button"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                text: "Show the donate button in this panel"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(9)
                elide: Text.ElideRight
              }
            }

            Item {
              Layout.preferredWidth: Style.space(60)
              Layout.preferredHeight: Style.spacing.controlHeight
              Layout.alignment: Qt.AlignVCenter

              ToggleSwitch {
                anchors.centerIn: parent
                checked: root.showBuyButton
                onToggled: root.setShowBuyButton(!root.showBuyButton)
              }
            }
          }

          // Footer: Reset + Status
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            BorderSurface {
              implicitHeight: Style.space(26)
              implicitWidth: Style.space(110)
              radius: Style.cornerRadius
              color: resetHover.containsMouse ? Style.selectedFillFor(root.foreground, root.urgent) : "transparent"
              borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

              RowLayout {
                anchors.centerIn: parent
                spacing: 3

                Text { text: "󰁯"; color: resetHover.containsMouse ? root.urgent : root.foreground; font.family: root.fontFamily }
                Text { text: "Reset Defaults"; color: resetHover.containsMouse ? root.urgent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              }

              MouseArea {
                id: resetHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.resetDefaults()
              }
            }

            // Buy Me a Coffee button (paypal.me/DavidDesousa13); hidden via the
            // "hide" toggle next to it.
            BorderSurface {
              visible: root.showBuyButton
              implicitHeight: Style.space(26)
              implicitWidth: Style.space(138)
              radius: Style.cornerRadius
              color: buyHover.containsMouse ? Util.alpha("#FF813F", 0.22) : Util.alpha("#FF813F", 0.10)
              borderSpec: Border.controlSpec(buyHover.containsMouse ? "hover-cursor" : "normal", root.foreground, root.accent)

              RowLayout {
                anchors.centerIn: parent
                spacing: 3

                Text { text: "☕"; color: "#FF813F"; font.family: root.fontFamily; font.pixelSize: Style.space(13) }
                Text { text: "Buy Me a Coffee"; color: buyHover.containsMouse ? "#FFB347" : "#FF813F"; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1; font.bold: true }
              }

              MouseArea {
                id: buyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  buyProc.running = false
                  buyProc.command = ["xdg-open", root.buyMeACoffeeUrl()]
                  buyProc.running = true
                }
              }
            }

            Item { Layout.fillWidth: true }

            Text {
              text: root.isSaving ? "Saving…" : (root.lastActionNote ? "✓ " + root.lastActionNote : "Live in Hyprland")
              color: root.isSaving ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ===================== KEYBINDS TAB =====================
        ColumnLayout {
          anchors.fill: parent
          visible: root.activeTab === "keybinds"
          spacing: Style.space(12)

          // Keybind Manager Header
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(56)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Text {
                text: ""
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Style.font.title + 6
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 1
                Text {
                  text: "Keybindings"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: "Hyprland Shortcut Manager"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 2
                }
              }

              // Active count
              ColumnLayout {
                spacing: 1
                Layout.alignment: Qt.AlignVCenter
                Text {
                  text: root.keybindData.total_active !== undefined ? String(root.keybindData.total_active) : "…"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: "Active"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 2
                }
              }

              // Modified count
              ColumnLayout {
                spacing: 1
                Layout.alignment: Qt.AlignVCenter
                Text {
                  text: root.keybindData.total_modified !== undefined ? String(root.keybindData.total_modified) : "…"
                  color: root.keybindData.total_modified > 0 ? "#FF9800" : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: "Modified"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 2
                }
              }

              // Conflicts count
              ColumnLayout {
                spacing: 1
                Layout.alignment: Qt.AlignVCenter
                Text {
                  text: root.keybindData.total_conflicts !== undefined ? String(root.keybindData.total_conflicts) : "…"
                  color: root.keybindData.total_conflicts > 0 ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: "Conflicts"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 2
                }
              }
            }
          }

          // Tab bar (compact replica of full manager tabs)
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Button {
              text: "All (" + (root.keybindData.total_active || 0) + ")"
              selected: root.currentKbTab === "active"
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              onClicked: root.currentKbTab = "active"
            }
            Button {
              text: "⭐ Modified (" + (root.keybindData.total_modified || 0) + ")"
              selected: root.currentKbTab === "modified"
              accent: (root.keybindData.total_modified > 0) ? "#FF9800" : root.foreground
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              onClicked: root.currentKbTab = "modified"
            }
            Button {
              text: "Catalog (" + ((root.keybindData.catalog && root.keybindData.catalog.length) || 0) + ")"
              selected: root.currentKbTab === "catalog"
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              onClicked: root.currentKbTab = "catalog"
            }
            Button {
              text: "⚠️ Conflicts (" + (root.keybindData.total_conflicts || 0) + ")"
              selected: root.currentKbTab === "conflicts"
              accent: (root.keybindData.total_conflicts > 0) ? root.urgent : root.foreground
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              onClicked: root.currentKbTab = "conflicts"
            }

            Item { Layout.fillWidth: true }

            Button {
              iconText: ""
              tooltipText: "Refresh Keybindings"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(4)
              onClicked: root.fetchKeybindSummary()
            }
          }

          // Search field — replicates the working full-manager TextField
          // (no BorderSurface wrapper: the Omarchy TextField already draws its
          // own boxed control background, so wrapping it caused a bar-in-a-bar)
          TextField {
            id: kbSearchInput
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(36)
            maximumLength: 256
            placeholderText: "Search shortcuts, actions, commands..."
            text: root.kbSearchQuery
            onTextChanged: root.kbSearchQuery = text

            Button {
              visible: root.kbSearchQuery.length > 0
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: Style.space(22)
              iconText: "✕"
              tooltipText: "Clear search"
              horizontalPadding: 0
              verticalPadding: 0
              onClicked: root.clearKbSearch()
            }
          }

          // Category filter chips (hidden on conflicts tab)
          Flow {
            Layout.fillWidth: true
            visible: root.currentKbTab !== "conflicts"
            spacing: Style.space(5)

            Repeater {
              model: root.kbCategories

              BorderSurface {
                required property string modelData
                height: Style.space(22)
                width: kbCatLabel.implicitWidth + Style.space(16)
                radius: Style.cornerRadius
                readonly property bool isSelected: root.currentKbCategory === modelData

                color: isSelected
                  ? Util.alpha(root.accent, 0.22)
                  : (kbCatMouse.containsMouse ? Util.alpha(root.foreground, 0.08) : Util.alpha(root.foreground, 0.04))
                borderSpec: Border.flat(
                  isSelected ? root.accent : Util.alpha(root.foreground, 0.15),
                  1
                )

                MouseArea {
                  id: kbCatMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.currentKbCategory = modelData
                }

                Text {
                  id: kbCatLabel
                  anchors.centerIn: parent
                  text: modelData
                  color: isSelected ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 2
                  font.bold: isSelected
                }
              }
            }
          }

          // Scrollable keybind list (tab-switched, compact full-manager style)
          ScrollView {
            id: kbScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            WheelHandler {
              target: kbScroll.contentItem
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: function(event) {
                var dy = event.angleDelta.y
                if (dy === 0) dy = event.pixelDelta.y
                var step = (dy / 120.0) * 100.0
                var flick = kbScroll.contentItem
                if (flick && flick.contentY !== undefined) {
                  var newY = flick.contentY - step
                  var maxY = Math.max(0, flick.contentHeight - flick.height)
                  flick.contentY = Math.max(0, Math.min(maxY, newY))
                  event.accepted = true
                }
              }
            }

            ColumnLayout {
              width: kbScroll.availableWidth
              spacing: Style.space(6)
              Layout.alignment: Qt.AlignTop

              // ================= TAB 1: ALL ACTIVE =================
              ColumnLayout {
                visible: root.currentKbTab === "active"
                Layout.fillWidth: true
                spacing: Style.space(6)

                Repeater {
                  model: root.filteredKbActive

                  BorderSurface {
                    id: kbActiveRow
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(56)
                    radius: Style.cornerRadius
                    color: kbActMouse.containsMouse ? Util.alpha(root.foreground, 0.06) : Util.alpha(root.foreground, 0.02)
                    borderSpec: Border.flat(
                      (modelData && modelData.is_conflict)
                        ? root.urgent
                        : (kbActMouse.containsMouse ? Util.alpha(root.foreground, 0.25) : Util.alpha(root.foreground, 0.1)),
                      (modelData && modelData.is_conflict) ? 1.5 : 1
                    )

                    MouseArea {
                      id: kbActMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      onClicked: root.requestEditKeybinding(modelData)
                    }

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(12)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(10)

                      BorderSurface {
                        id: kbActStBadge
                        Layout.preferredHeight: Style.space(20)
                        Layout.preferredWidth: kbActStTxt.implicitWidth + Style.space(10)
                        Layout.alignment: Qt.AlignVCenter
                        radius: Style.cornerRadius
                        readonly property string st: (kbActiveRow.modelData && kbActiveRow.modelData.status) || "default"
                        readonly property bool isConf: Boolean(kbActiveRow.modelData && kbActiveRow.modelData.is_conflict)
                        color: kbActStBadge.isConf ? Util.alpha(root.urgent, 0.2) : (kbActStBadge.st === "custom" ? Util.alpha("#4CAF50", 0.2) : (kbActStBadge.st === "modified" ? Util.alpha("#FF9800", 0.2) : Util.alpha(root.foreground, 0.05)))
                        borderSpec: Border.flat(kbActStBadge.isConf ? root.urgent : (kbActStBadge.st === "custom" ? "#4CAF50" : (kbActStBadge.st === "modified" ? "#FF9800" : Util.alpha(root.foreground, 0.15))), 1)

                        Text {
                          id: kbActStTxt
                          anchors.centerIn: parent
                          text: kbActStBadge.isConf ? "CONFLICT" : kbActStBadge.st.toUpperCase()
                          color: kbActStBadge.isConf ? root.urgent : (kbActStBadge.st === "custom" ? "#4CAF50" : (kbActStBadge.st === "modified" ? "#FF9800" : root.foreground))
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption - 3
                          font.bold: true
                        }
                      }

                      ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1
                        Text {
                          Layout.fillWidth: true
                          text: (kbActiveRow.modelData && kbActiveRow.modelData.description) || "Action"
                          textFormat: Text.PlainText
                          color: kbActiveRow.modelData && kbActiveRow.modelData.status === "disabled" ? Util.alpha(root.foreground, 0.4) : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          font.strikeout: kbActiveRow.modelData && kbActiveRow.modelData.status === "disabled"
                          elide: Text.ElideRight
                        }
                        Text {
                          Layout.fillWidth: true
                          text: (kbActiveRow.modelData && (kbActiveRow.modelData.command || kbActiveRow.modelData.action)) || ""
                          textFormat: Text.PlainText
                          color: Util.alpha(root.foreground, 0.5)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption - 3
                          elide: Text.ElideRight
                        }
                      }

                      KeyBadge {
                        Layout.alignment: Qt.AlignVCenter
                        keyText: (kbActiveRow.modelData && kbActiveRow.modelData.key) || ""
                        highlighted: Boolean(kbActiveRow.modelData && kbActiveRow.modelData.is_conflict)
                      }

                      Button {
                        iconText: "✏️"
                        tooltipText: "Modify"
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(3)
                        onClicked: root.requestEditKeybinding(kbActiveRow.modelData)
                      }
                    }
                  }
                }

                // Empty state for active
                BorderSurface {
                  visible: root.filteredKbActive.length === 0
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(80)
                  radius: Style.cornerRadius
                  color: Util.alpha(root.foreground, 0.02)
                  borderSpec: Border.flat(Util.alpha(root.foreground, 0.1), 1)

                  ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2
                    Text { text: "No active keybinds match filter"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }
                }
              }

              // ================= TAB 2: MODIFIED =================
              ColumnLayout {
                visible: root.currentKbTab === "modified"
                Layout.fillWidth: true
                spacing: Style.space(6)

                Repeater {
                  model: root.filteredKbModified

                  BorderSurface {
                    id: kbModRow
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(56)
                    radius: Style.cornerRadius
                    color: kbModMouse.containsMouse ? Util.alpha(root.foreground, 0.06) : Util.alpha(root.foreground, 0.02)
                    borderSpec: Border.flat(kbModMouse.containsMouse ? Util.alpha(root.foreground, 0.25) : Util.alpha(root.foreground, 0.1), 1)

                    MouseArea {
                      id: kbModMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      onClicked: root.requestEditKeybinding(modelData)
                    }

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(12)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(10)

                      BorderSurface {
                        id: kbModStBadge
                        Layout.preferredHeight: Style.space(20)
                        Layout.preferredWidth: kbModStTxt.implicitWidth + Style.space(10)
                        Layout.alignment: Qt.AlignVCenter
                        radius: Style.cornerRadius
                        readonly property string st: (kbModRow.modelData && kbModRow.modelData.status) || "modified"
                        color: kbModStBadge.st === "custom" ? Util.alpha("#4CAF50", 0.2) : Util.alpha("#FF9800", 0.2)
                        borderSpec: Border.flat(kbModStBadge.st === "custom" ? "#4CAF50" : "#FF9800", 1)

                        Text {
                          id: kbModStTxt
                          anchors.centerIn: parent
                          text: kbModStBadge.st.toUpperCase()
                          color: kbModStBadge.st === "custom" ? "#4CAF50" : "#FF9800"
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption - 3
                          font.bold: true
                        }
                      }

                      ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1
                        Text {
                          Layout.fillWidth: true
                          text: (kbModRow.modelData && kbModRow.modelData.description) || "Action"
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          elide: Text.ElideRight
                        }
                        Text {
                          Layout.fillWidth: true
                          text: (kbModRow.modelData && (kbModRow.modelData.command || kbModRow.modelData.action)) || ""
                          color: Util.alpha(root.foreground, 0.5)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption - 3
                          elide: Text.ElideRight
                        }
                      }

                      KeyBadge {
                        Layout.alignment: Qt.AlignVCenter
                        keyText: (kbModRow.modelData && kbModRow.modelData.key) || ""
                      }

                      Button {
                        iconText: "✏️"
                        tooltipText: "Modify"
                        horizontalPadding: Style.space(6)
                        verticalPadding: Style.space(3)
                        onClicked: root.requestEditKeybinding(kbModRow.modelData)
                      }
                    }
                  }
                }

                BorderSurface {
                  visible: root.filteredKbModified.length === 0
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(80)
                  radius: Style.cornerRadius
                  color: Util.alpha(root.foreground, 0.02)
                  borderSpec: Border.flat(Util.alpha(root.foreground, 0.1), 1)

                  ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2
                    Text { text: "No modified or custom keybinds"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }
                }
              }

              // ================= TAB 3: CATALOG =================
              ColumnLayout {
                visible: root.currentKbTab === "catalog"
                Layout.fillWidth: true
                spacing: Style.space(6)

                Repeater {
                  model: root.filteredKbCatalog

                  BorderSurface {
                    id: kbCatRow
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(56)
                    radius: Style.cornerRadius
                    color: kbCatRowMouse.containsMouse ? Util.alpha(root.foreground, 0.06) : Util.alpha(root.foreground, 0.02)
                    borderSpec: Border.flat(kbCatRowMouse.containsMouse ? Util.alpha(root.foreground, 0.25) : Util.alpha(root.foreground, 0.1), 1)

                    MouseArea {
                      id: kbCatRowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                    }

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(12)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(10)

                      ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1
                        Text {
                          Layout.fillWidth: true
                          text: kbCatRow.modelData.name || "Action"
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          elide: Text.ElideRight
                        }
                        Text {
                          Layout.fillWidth: true
                          text: kbCatRow.modelData.description || ""
                          color: Util.alpha(root.foreground, 0.5)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption - 3
                          elide: Text.ElideRight
                        }
                      }

                      KeyBadge {
                        Layout.alignment: Qt.AlignVCenter
                        keyText: kbCatRow.modelData.current_key || kbCatRow.modelData.default_key || ""
                      }

                      Button {
                        text: kbCatRow.modelData.is_bound ? "Rebind" : "+ Bind"
                        accent: root.accent
                        selected: !kbCatRow.modelData.is_bound
                        horizontalPadding: Style.space(8)
                        verticalPadding: Style.space(3)
                        onClicked: root.summonKeybindManager()
                      }
                    }
                  }
                }

                BorderSurface {
                  visible: root.filteredKbCatalog.length === 0
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(80)
                  radius: Style.cornerRadius
                  color: Util.alpha(root.foreground, 0.02)
                  borderSpec: Border.flat(Util.alpha(root.foreground, 0.1), 1)

                  ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2
                    Text { text: "No catalog actions match"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }
                }
              }

              // ================= TAB 4: CONFLICTS =================
              ColumnLayout {
                visible: root.currentKbTab === "conflicts"
                Layout.fillWidth: true
                spacing: Style.space(6)

                Repeater {
                  model: root.filteredKbConflicts

                  BorderSurface {
                    id: kbConfRow
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(56)
                    radius: Style.cornerRadius
                    color: Util.alpha(root.urgent, 0.06)
                    borderSpec: Border.flat(root.urgent, 1.5)

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(12)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(10)

                      KeyBadge {
                        keyText: kbConfRow.modelData.key || ""
                        highlighted: true
                        accent: root.urgent
                      }

                      Text {
                        Layout.fillWidth: true
                        text: (kbConfRow.modelData.bindings ? kbConfRow.modelData.bindings.length : 2) + " actions colliding on this key"
                        color: root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Button {
                        text: "Resolve"
                        accent: root.urgent
                        horizontalPadding: Style.space(8)
                        verticalPadding: Style.space(3)
                        onClicked: root.summonKeybindManager()
                      }
                    }
                  }
                }

                BorderSurface {
                  visible: root.filteredKbConflicts.length === 0
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(80)
                  radius: Style.cornerRadius
                  color: Util.alpha("#4CAF50", 0.08)
                  borderSpec: Border.flat("#4CAF50", 1)

                  ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2
                    Text { text: "No shortcut conflicts detected! 🎉"; color: "#4CAF50"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }
                }
              }
            }
          }

          // Open Full Manager Button
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(40)
            radius: Style.cornerRadius
            color: launchHover.containsMouse ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec(launchHover.containsMouse ? "hover-cursor" : "normal", root.foreground, root.accent)

            RowLayout {
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                text: "🚀"
                font.pixelSize: Style.font.caption
              }

              Text {
                text: "Open Full Keybind Manager"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            MouseArea {
              id: launchHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.summonKeybindManager()
            }
          }
        }
      }
    }
  }
}