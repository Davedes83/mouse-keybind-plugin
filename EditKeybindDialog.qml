import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Modal dialog for adding, modifying, or re-homing a keybinding.
//
// Modes:
//   openCreate(preset)                       new binding (catalog preset or custom)
//   openEdit(row)                            edit an existing row (disabled rows use oldKey "")
//   openRehome(row, lostKey, winnerDesc)     row lost its key to `winnerDesc`; pick a new one,
//                                            disable it, or leave it unbound.
Item {
  id: root

  property bool opened: false
  property bool isEditing: false
  property bool isRehome: false
  property var itemData: null
  property var allBindings: []
  property var catalog: []

  // "ask" | "rehome" | "override" — drives the wording of the live conflict banner.
  property string conflictMode: "rehome"
  // Parent sets this while a backend mutator is running.
  property bool saving: false

  property string actionTitle: ""
  property string actionCommand: ""
  property string actionCategory: "Custom"
  property string actionKey: ""
  property string oldKey: ""
  property string actionType: "preset" // "preset" | "custom"
  // Stable identity passed to the backend as --id ("" for brand-new custom rows).
  property string bindingId: ""
  // Catalog preset's Lua dispatcher (e.g. hl.dsp.window.close()); "" for exec
  // presets and custom/edited rows. Sent as `action` instead of `command`.
  property string actionDispatcher: ""
  // Description snapshot at open time (self-conflict exclusion).
  property string ownDescription: ""
  // "was SUPER + F" hint for disabled rows.
  property string wasKeyHint: ""

  // Rehome state
  property var displacedBinding: null
  property string rehomeBannerText: ""
  property string rehomeLostKey: ""

  // Live backend `check` result for the current chord (null until fresh).
  property var checkResult: null
  property bool checkPending: false

  property color background: Color.background
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent

  readonly property string backendPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/davedes.mouse-keybind-settings/backend/keybinds_manager.py"

  signal saved(string key, string description, string command, string action, string oldKey, string id)
  signal canceled()
  signal closed()
  signal disableRequested(string id, string key)
  signal unboundAccepted(string id)

  readonly property string effectiveId: root.bindingId.length > 0 ? root.bindingId : root.actionTitle.trim().toLowerCase()
  readonly property bool checkFresh: Boolean(root.checkResult && root.checkResult.key !== undefined
                                             && Model.normalizeKey(root.checkResult.key) === Model.normalizeKey(keyRecorder.value))
  readonly property var liveConflict: (root.checkFresh && root.checkResult.conflict) ? root.checkResult.conflict : null
  readonly property var lockedInfo: (root.checkFresh && root.checkResult.locked) ? root.checkResult.locked : null
  readonly property bool keyAcceptable: keyRecorder.complete && (keyRecorder.hasModifier || Model.isStandaloneKey(keyRecorder.mainKey))
  readonly property bool canSave: root.keyAcceptable && root.actionTitle.trim().length > 0 && !root.saving && root.lockedInfo === null
  readonly property bool canDisable: Boolean(root.itemData && (
    (root.itemData.default_key && String(root.itemData.default_key).length > 0) || root.itemData.managed === true))

  readonly property string conflictBannerText: {
    if (root.lockedInfo) {
      var l = root.lockedInfo
      var where = l.file_line ? " (bindings.lua line " + l.file_line + ")" : ""
      var why = l.reason ? ": " + l.reason : ""
      return "This binding is locked" + where + why + ". Edit it in the editor instead."
    }
    if (root.liveConflict) {
      var d = root.liveConflict.description || "another binding"
      var tail
      if (root.conflictMode === "override") tail = "Saving will override it — " + d + " loses its key."
      else if (root.conflictMode === "ask") tail = "Saving will ask what to do with " + d + "."
      else tail = "Saving will ask you to rehome " + d + "."
      return keyRecorder.value + " is " + d + ". " + tail
    }
    return ""
  }

  readonly property string saveLabel: {
    if (root.saving) return "Saving…"
    if (root.liveConflict) return root.conflictMode === "override" ? "Override & Save" : "Save & Rehome"
    return "Save & Apply"
  }

  readonly property string saveHint: {
    if (root.saving) return "Applying the previous change…"
    if (root.lockedInfo) return "Locked binding"
    if (!keyRecorder.complete) return keyRecorder.hasModifier ? "Pick a key to complete the chord" : "Choose a shortcut"
    if (!root.keyAcceptable) return "Add a modifier (or use an F-key / PRINT / XF86 key)"
    if (root.actionTitle.trim().length === 0) return "Give the action a name"
    return ""
  }

  // Smart Suggested Free Combinations
  readonly property var suggestedKeys: {
    var bound = {}
    if (root.allBindings) {
      for (var i = 0; i < root.allBindings.length; i++) {
        var b = root.allBindings[i]
        if (b && b.status !== "disabled" && b.key) {
          bound[Model.normalizeKey(b.key)] = true
        }
      }
    }

    var firstLetter = ""
    if (root.actionTitle && root.actionTitle.trim().length > 0) {
      var cleanTitle = root.actionTitle.trim()
      for (var j = 0; j < cleanTitle.length; j++) {
        var ch = cleanTitle.charAt(j).toUpperCase()
        if (ch >= 'A' && ch <= 'Z') {
          firstLetter = ch
          break
        }
      }
    }

    var candidates = []
    if (firstLetter) {
      candidates.push("SUPER + " + firstLetter)
      candidates.push("SUPER + ALT + " + firstLetter)
      candidates.push("SUPER + SHIFT + " + firstLetter)
      candidates.push("SUPER + CTRL + " + firstLetter)
    }

    var letters = ["B", "D", "E", "H", "M", "N", "R", "T", "U", "Y", "Z", "A", "C", "F", "K", "L", "P", "Q", "S", "W"]
    for (var k = 0; k < letters.length; k++) {
      var l = letters[k]
      if (l !== firstLetter) {
        candidates.push("SUPER + " + l)
        candidates.push("SUPER + ALT + " + l)
        candidates.push("SUPER + SHIFT + " + l)
        candidates.push("SUPER + CTRL + " + l)
      }
    }

    var current = Model.normalizeKey(root.actionKey)
    var suggestions = []
    for (var c = 0; c < candidates.length; c++) {
      var chord = candidates[c]
      var norm = Model.normalizeKey(chord)
      if (!bound[norm] && suggestions.indexOf(chord) === -1 && norm !== current) {
        suggestions.push(chord)
        if (suggestions.length >= 4) break
      }
    }

    return suggestions
  }

  function resetCommon() {
    root.checkResult = null
    root.checkPending = false
    root.wasKeyHint = ""
    root.displacedBinding = null
    root.rehomeBannerText = ""
    root.rehomeLostKey = ""
    root.isRehome = false
    root.actionDispatcher = ""
  }

  function openCreate(presetItem) {
    resetCommon()
    root.isEditing = false
    root.itemData = presetItem || null
    root.oldKey = ""

    if (presetItem) {
      root.actionTitle = presetItem.name || presetItem.description || ""
      root.actionCommand = presetItem.command || ""
      root.actionCategory = presetItem.category || "General"
      root.actionKey = presetItem.default_key || ""
      root.actionType = presetItem.name ? "preset" : "custom"
      // Catalog `id` is a preset id ("win.close"), not a binding id: row_id is
      // the existing binding row for this action, or null for a brand-new one.
      root.bindingId = presetItem.row_id || ""
      root.actionDispatcher = (presetItem.dispatcher && presetItem.dispatcher !== "exec") ? presetItem.dispatcher : ""
    } else {
      root.actionTitle = ""
      root.actionCommand = ""
      root.actionCategory = "Custom"
      root.actionKey = ""
      root.actionType = "custom"
      root.bindingId = ""
    }
    root.ownDescription = ""

    keyRecorder.load(root.actionKey)
    root.opened = true
    root.scheduleCheck()
    Qt.callLater(function() {
      if (descInput) descInput.forceActiveFocus()
    })
  }

  function openEdit(bindingItem) {
    resetCommon()
    var b = bindingItem || null
    root.isEditing = true
    root.itemData = b
    root.actionTitle = (b && b.description) || ""
    root.actionCommand = (b && (b.action || b.command)) || ""
    root.actionCategory = (b && b.category) || "Custom"
    root.actionType = (b && b.source === "default") ? "preset" : "custom"
    root.bindingId = Model.rowId(b)
    root.ownDescription = (b && b.description) || ""

    if (b && b.status === "disabled") {
      // A disabled row holds no key: nothing to release, so oldKey stays "".
      root.oldKey = ""
      var dk = (b.default_key) ? String(b.default_key) : ""
      root.wasKeyHint = dk ? "was " + dk : ""
      // Prefill the default only when nobody else holds it.
      root.actionKey = (dk && Model.holdersOf(root.allBindings, dk, root.bindingId).length === 0) ? dk : ""
    } else {
      root.actionKey = (b && b.key) || ""
      root.oldKey = (b && b.key) || ""
    }

    keyRecorder.load(root.actionKey)
    root.opened = true
    root.scheduleCheck()
    Qt.callLater(function() {
      if (descInput) descInput.forceActiveFocus()
    })
  }

  function openRehome(bindingItem, lostKey, winnerDescription) {
    resetCommon()
    var b = bindingItem || null
    root.isEditing = true
    root.isRehome = true
    root.itemData = b
    root.displacedBinding = b
    root.actionTitle = (b && b.description) || ""
    root.actionCommand = (b && (b.action || b.command)) || ""
    root.actionCategory = (b && b.category) || "Custom"
    root.actionType = (b && b.source === "default") ? "preset" : "custom"
    root.bindingId = Model.rowId(b)
    root.ownDescription = (b && b.description) || ""
    root.oldKey = ""
    root.actionKey = ""
    root.rehomeLostKey = lostKey ? String(lostKey) : ""
    root.wasKeyHint = root.rehomeLostKey ? "was " + root.rehomeLostKey : ""
    root.rehomeBannerText = root.actionTitle + " lost " + (root.rehomeLostKey || "its key") + " to "
      + (winnerDescription || "another binding") + ". Pick a new key or disable it."

    keyRecorder.load("")
    root.opened = true
    root.scheduleCheck()
    Qt.callLater(function() {
      if (root.opened && root.isRehome) keyRecorder.startRecording()
    })
  }

  // Close without deciding. For a rehome dialog the parent keeps the binding
  // queued (it still needs a key); the user can come back via "Pick key…".
  function close() {
    if (!root.opened) return
    root.opened = false
    root.canceled()
  }

  function commitSave() {
    if (!root.canSave) return
    var key = keyRecorder.value
    var id = root.effectiveId
    // A catalog preset with a Lua dispatcher is written as that action (like
    // stock bindings); otherwise the command string is exec'd.
    var action = (root.actionType === "preset" && root.actionDispatcher) ? root.actionDispatcher : ""
    var cmd = action ? "" : root.actionCommand
    root.opened = false
    root.saved(key, root.actionTitle.trim(), cmd, action, root.oldKey, id)
  }

  function requestDisable() {
    var id = root.effectiveId
    var key = (root.itemData && root.itemData.default_key) ? String(root.itemData.default_key) : root.rehomeLostKey
    root.opened = false
    root.disableRequested(id, key)
  }

  function acceptUnbound() {
    var id = root.effectiveId
    root.opened = false
    root.unboundAccepted(id)
  }

  onOpenedChanged: {
    if (!root.opened) {
      keyRecorder.stopRecording()
      checkDebounce.stop()
      root.checkPending = false
      root.closed()
    }
  }

  onActionTitleChanged: root.scheduleCheck()

  // ---- Live backend conflict check (debounced, never restarted mid-flight) ----

  function scheduleCheck() {
    if (!root.opened) return
    checkDebounce.restart()
  }

  function runCheck() {
    if (!root.opened) return
    var key = keyRecorder.value
    if (!key || !keyRecorder.complete) {
      root.checkResult = null
      return
    }
    if (checkProc.running) {
      root.checkPending = true
      return
    }
    root.checkPending = false
    var args = [root.backendPath, "check", key, root.actionTitle.trim(), "--id", root.effectiveId]
    if (root.oldKey) args.push("--old-key", root.oldKey)
    checkProc.command = args
    checkProc.running = true
  }

  Timer {
    id: checkDebounce
    interval: 150
    repeat: false
    onTriggered: root.runCheck()
  }

  BoundedProcess {
    id: checkProc
    maxBytes: 262144
    timeoutMs: 8000
    onFinished: {
      if (success) {
        try {
          var r = JSON.parse(stdout || "")
          if (r && typeof r === "object") root.checkResult = r
        } catch (e) {
          console.warn("EditKeybindDialog: check returned invalid JSON:", e)
        }
      }
      if (root.checkPending && root.opened) Qt.callLater(root.runCheck)
    }
  }

  visible: opened

  // Scrim backdrop
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.88)

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    // Modal Card
    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(64), Style.space(640))
      height: Math.min(parent.height - Style.space(40), card.contentTopInset + card.contentBottomInset + cardLayout.implicitHeight)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.isRehome ? root.urgent : Util.alpha(root.foreground, 0.25), 1)
      radius: Style.cornerRadius
      padding: Style.space(28)

      MouseArea {
        anchors.fill: parent
        onClicked: {} // Swallow clicks inside modal
      }

      ScrollView {
        id: cardScroll
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: cardLayout.implicitHeight > cardScroll.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        ColumnLayout {
          id: cardLayout
          width: cardScroll.availableWidth
          spacing: Style.space(16)

          // 1. Header
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(14)

            Text {
              text: root.isRehome ? "" : ""
              color: root.isRehome ? root.urgent : root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title + 8
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                text: root.isRehome
                  ? ("Pick a new key for " + root.actionTitle)
                  : (root.isEditing ? "Edit Keybinding" : "Create New Keybinding")
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: root.isRehome
                  ? "This binding needs a home before it works again."
                  : (root.isEditing
                    ? "Update the shortcut combination or action details below."
                    : "Assign a shortcut to a system action or define a custom terminal command.")
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Util.alpha(root.foreground, 0.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Rehome banner
          BorderSurface {
            id: rehomeBanner
            visible: root.isRehome && root.rehomeBannerText.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: rehomeBanner.contentTopInset + rehomeBanner.contentBottomInset + rehomeBannerText.implicitHeight
            radius: Style.cornerRadius
            color: Util.alpha(root.urgent, 0.12)
            borderSpec: Border.flat(root.urgent, 1)
            padding: Style.space(12)

            Text {
              id: rehomeBannerText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: rehomeBanner.contentLeftInset
              anchors.rightMargin: rehomeBanner.contentRightInset
              anchors.topMargin: rehomeBanner.contentTopInset
              text: root.rehomeBannerText
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // 2. Action Type Selector (Only when creating new)
          RowLayout {
            visible: !root.isEditing
            Layout.fillWidth: true
            spacing: Style.space(12)

            Text {
              text: "Action Source:"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            ButtonGroup {
              id: typeGroup

              Button {
                text: "Preset Catalog Action"
                selected: root.actionType === "preset"
                horizontalPadding: Style.space(16)
                verticalPadding: Style.space(4)
                onClicked: root.actionType = "preset"
              }
              Button {
                text: "Custom Command / Script"
                selected: root.actionType === "custom"
                horizontalPadding: Style.space(16)
                verticalPadding: Style.space(4)
                onClicked: root.actionType = "custom"
              }
            }
          }

          // Preset Selector Row (when creating from catalog)
          ColumnLayout {
            visible: !root.isEditing && root.actionType === "preset"
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
              text: "Popular Catalog Presets:"
              color: Util.alpha(root.foreground, 0.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Flow {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Repeater {
                model: (root.catalog && root.catalog.slice(0, 10)) || []

                BorderSurface {
                  id: presetChip
                  required property var modelData
                  readonly property bool isPicked: root.actionTitle === modelData.name
                  height: Style.space(28)
                  width: chipText.implicitWidth + Style.space(18)
                  radius: Style.cornerRadius
                  color: isPicked
                    ? Util.alpha(root.accent, 0.22)
                    : (chipMouse.containsMouse ? Util.alpha(root.foreground, 0.08) : Util.alpha(root.foreground, 0.04))
                  borderSpec: Border.flat(isPicked ? root.accent : Util.alpha(root.foreground, 0.15), 1)

                  MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.actionTitle = presetChip.modelData.name
                      root.actionCommand = presetChip.modelData.command
                      root.actionCategory = presetChip.modelData.category
                      root.bindingId = presetChip.modelData.row_id || ""
                      root.actionDispatcher = (presetChip.modelData.dispatcher && presetChip.modelData.dispatcher !== "exec")
                        ? presetChip.modelData.dispatcher : ""
                      if (!keyRecorder.value && presetChip.modelData.default_key) {
                        keyRecorder.load(presetChip.modelData.default_key)
                      }
                    }
                  }

                  Text {
                    id: chipText
                    anchors.centerIn: parent
                    text: presetChip.modelData.name
                    color: presetChip.isPicked ? root.accent : root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: presetChip.isPicked
                  }
                }
              }
            }
          }

          // 3. Name / Description Field (read-only summary in rehome mode)
          ColumnLayout {
            visible: !root.isRehome
            Layout.fillWidth: true
            spacing: Style.space(4)

            Text {
              text: "Action Name / Description:"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            TextField {
              id: descInput
              Layout.fillWidth: true
              maximumLength: 200
              text: root.actionTitle
              placeholderText: "e.g. Launch Terminal, Toggle Fullscreen, My Script"
              onTextChanged: if (root.actionTitle !== text) root.actionTitle = text
            }
          }

          // 4. Command Field (custom actions, or editing)
          ColumnLayout {
            visible: !root.isRehome && (root.actionType === "custom" || root.isEditing)
            Layout.fillWidth: true
            spacing: Style.space(4)

            Text {
              text: "Command / Dispatcher:"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            TextField {
              id: cmdInput
              Layout.fillWidth: true
              maximumLength: 2000
              text: root.actionCommand
              placeholderText: "e.g. alacritty -e btop, omarchy-capture-screenshot"
              onTextChanged: if (root.actionCommand !== text) root.actionCommand = text
            }
          }

          // Rehome: compact summary of what is being re-homed
          RowLayout {
            visible: root.isRehome
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: "Command:"
              color: Util.alpha(root.foreground, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              text: root.actionCommand
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Util.alpha(root.foreground, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // 5. Suggestions (shown first in rehome mode) + Shortcut recorder
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            // Suggestions block (rehome: before the recorder)
            ColumnLayout {
              id: suggestionsTop
              visible: root.isRehome && root.suggestedKeys.length > 0
              Layout.fillWidth: true
              spacing: Style.space(6)

              RowLayout {
                spacing: Style.space(6)

                Text {
                  text: "💡"
                  font.pixelSize: Style.font.caption
                }

                Text {
                  text: "Free shortcuts (click to pick):"
                  color: Util.alpha(root.foreground, 0.75)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Flow {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Repeater {
                  model: root.suggestedKeys

                  BorderSurface {
                    id: suggestChipTop
                    required property string modelData
                    height: Style.space(28)
                    width: suggestChipTopRow.implicitWidth + Style.space(18)
                    radius: Style.cornerRadius
                    color: suggestTopMouse.containsMouse ? Util.alpha(root.accent, 0.24) : Util.alpha(root.accent, 0.10)
                    borderSpec: Border.flat(suggestTopMouse.containsMouse ? root.accent : Util.alpha(root.accent, 0.4), 1)

                    MouseArea {
                      id: suggestTopMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.pickSuggestion(suggestChipTop.modelData)
                    }

                    RowLayout {
                      id: suggestChipTopRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)

                      Text {
                        text: "✨"
                        font.pixelSize: Style.font.caption - 2
                      }

                      Text {
                        text: suggestChipTop.modelData
                        color: root.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text {
                text: "Keyboard Shortcut:"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                visible: root.wasKeyHint.length > 0
                text: root.wasKeyHint
                textFormat: Text.PlainText
                color: Util.alpha(root.foreground, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.italic: true
              }

              Item { Layout.fillWidth: true }
            }

            KeyRecorder {
              id: keyRecorder
              Layout.fillWidth: true
              allBindings: root.allBindings
              ownId: root.bindingId
              ownDescription: root.ownDescription
              ownKey: root.oldKey
              conflictMessage: root.conflictBannerText
              localConflictEnabled: !root.checkFresh
              onKeyChanged: function(newK) {
                root.actionKey = newK
              }
              onValueChanged: root.scheduleCheck()
            }

            // Suggestions block (normal mode: after the recorder)
            ColumnLayout {
              visible: !root.isRehome && root.suggestedKeys.length > 0
              Layout.fillWidth: true
              spacing: Style.space(6)

              RowLayout {
                spacing: Style.space(6)

                Text {
                  text: "💡"
                  font.pixelSize: Style.font.caption
                }

                Text {
                  text: "Suggested Free Shortcuts (Click to pick):"
                  color: Util.alpha(root.foreground, 0.75)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Flow {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Repeater {
                  model: root.suggestedKeys

                  BorderSurface {
                    id: suggestChip
                    required property string modelData
                    height: Style.space(28)
                    width: suggestChipRow.implicitWidth + Style.space(18)
                    radius: Style.cornerRadius
                    color: suggestMouse.containsMouse ? Util.alpha(root.accent, 0.24) : Util.alpha(root.accent, 0.10)
                    borderSpec: Border.flat(suggestMouse.containsMouse ? root.accent : Util.alpha(root.accent, 0.4), 1)

                    MouseArea {
                      id: suggestMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.pickSuggestion(suggestChip.modelData)
                    }

                    RowLayout {
                      id: suggestChipRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)

                      Text {
                        text: "✨"
                        font.pixelSize: Style.font.caption - 2
                      }

                      Text {
                        text: suggestChip.modelData
                        color: root.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // 6. Footer
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(12)

            Text {
              visible: root.saveHint.length > 0
              text: root.saveHint
              textFormat: Text.PlainText
              color: Util.alpha(root.foreground, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.italic: true
              Layout.fillWidth: true
              elide: Text.ElideRight
            }

            Item { visible: root.saveHint.length === 0; Layout.fillWidth: true }

            Button {
              text: root.isRehome ? "Later" : "Cancel"
              tooltipText: root.isRehome ? "Close for now — the binding stays flagged as needing a key" : ""
              horizontalPadding: Style.space(20)
              verticalPadding: Style.space(6)
              onClicked: root.close()
            }

            Button {
              visible: root.isRehome && root.canDisable
              text: "Disable it"
              iconText: "⊘"
              accent: root.urgent
              enabled: !root.saving
              opacity: enabled ? 1.0 : 0.45
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(6)
              onClicked: root.requestDisable()
            }

            Button {
              visible: root.isRehome && !root.canDisable
              text: "Leave it unbound"
              enabled: !root.saving
              opacity: enabled ? 1.0 : 0.45
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(6)
              onClicked: root.acceptUnbound()
            }

            Button {
              id: saveButton
              text: root.saveLabel
              accent: (root.liveConflict && root.conflictMode === "override") ? root.urgent : root.accent
              selected: true
              enabled: root.canSave
              opacity: root.canSave ? 1.0 : 0.45
              horizontalPadding: Style.space(24)
              verticalPadding: Style.space(6)
              onClicked: root.commitSave()
            }
          }
        }
      }
    }
  }

  function pickSuggestion(chord) {
    keyRecorder.load(chord)
    keyRecorder.recording = false
    root.actionKey = chord
    root.scheduleCheck()
  }
}
