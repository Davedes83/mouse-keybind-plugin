import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Interactive Keybinding Recorder
//
// The modifier pills (modSuper/modCtrl/modAlt/modShift) and `mainKey` are the
// source of truth. `value` is always derived from them via composeKey();
// setting `value` from outside re-parses it into the pills exactly once.
//
// Recording never clears the current chord: modifier-only key presses toggle
// their pill, a main key ORs the held modifiers into the pills, sets the key
// and stops recording. Super chords are grabbed by Hyprland before this window
// sees them, so the SUPER pill can be toggled by hand and the key typed.
Item {
  id: root

  property string value: ""
  property bool recording: false
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property color urgent: Color.urgent

  // Modifier state flags + main key (source of truth)
  property bool modSuper: false
  property bool modCtrl: false
  property bool modAlt: false
  property bool modShift: false
  property string mainKey: ""

  readonly property bool complete: root.mainKey.length > 0
  readonly property bool hasModifier: root.modSuper || root.modCtrl || root.modAlt || root.modShift
  readonly property bool incomplete: !root.complete && root.hasModifier

  signal keyChanged(string newKey)

  // All active bindings for instant local collision feedback
  property var allBindings: []
  // Snapshot identity of the binding being edited (set once at open time) so
  // the binding never conflicts with itself even after its title is edited.
  property string ownId: ""
  property string ownDescription: ""
  property string ownKey: ""

  // Banner text supplied by the parent (backend `check` result); when empty
  // the local collision list is used.
  property string conflictMessage: ""
  // Parent turns this off once it has a fresh backend answer for the chord.
  property bool localConflictEnabled: true

  readonly property var activeConflict: checkConflict(root.value)
  readonly property bool hasLocalConflict: root.localConflictEnabled && activeConflict !== null
  readonly property bool hasConflict: root.hasLocalConflict || root.conflictMessage.length > 0

  // Internal guards
  property bool _composing: false
  property bool _syncingField: false
  property var _preRecord: null

  onValueChanged: {
    if (root._composing) return
    parseCurrentValue(root.value)
  }

  onMainKeyChanged: {
    if (root._syncingField) return
    root._syncingField = true
    if (manualKeyField.text.trim() !== root.mainKey) manualKeyField.text = root.mainKey
    root._syncingField = false
  }

  function parseCurrentValue(str) {
    var p = Model.parseChord(str)
    root.modSuper = p.modSuper
    root.modCtrl = p.modCtrl
    root.modAlt = p.modAlt
    root.modShift = p.modShift
    root.mainKey = p.mainKey
  }

  // Load a chord from outside (dialog open, suggestion chip): sets value and
  // re-parses it into the pills even when the string is unchanged.
  function load(chord) {
    var v = chord ? String(chord) : ""
    root._composing = true
    root.value = v
    root._composing = false
    parseCurrentValue(v)
  }

  function composeKey() {
    var result = Model.composeChord(root.modSuper, root.modShift, root.modCtrl, root.modAlt, root.mainKey)
    root._composing = true
    root.value = result
    root._composing = false
    root.keyChanged(result)
    return result
  }

  function checkConflict(key) {
    if (!key || !root.allBindings || root.allBindings.length === 0) return null
    var target = Model.normalizeKey(key)
    if (!target) return null
    var ownNorm = Model.normalizeKey(root.ownKey)
    var holders = Model.holdersOf(root.allBindings, target, root.ownId)
    var collisions = []
    for (var i = 0; i < holders.length; i++) {
      var b = holders[i]
      if (root.ownDescription && b.description === root.ownDescription && ownNorm && Model.normalizeKey(b.key) === ownNorm) continue
      collisions.push(b)
    }
    return collisions.length > 0 ? collisions : null
  }

  function startRecording() {
    root._preRecord = {
      modSuper: root.modSuper, modCtrl: root.modCtrl, modAlt: root.modAlt, modShift: root.modShift,
      mainKey: root.mainKey, value: root.value
    }
    root.recording = true
    keyCaptureFocus.forceActiveFocus()
  }

  function restorePreRecord() {
    var s = root._preRecord
    if (!s) return
    root.modSuper = s.modSuper
    root.modCtrl = s.modCtrl
    root.modAlt = s.modAlt
    root.modShift = s.modShift
    root.mainKey = s.mainKey
    root.composeKey()
  }

  // Done / click-away: keeps what was captured, unless no main key was picked.
  function stopRecording() {
    if (!root.recording) return
    root.recording = false
    if (!root.mainKey) restorePreRecord()
    root._preRecord = null
  }

  // Escape: discard everything captured during this recording session.
  function cancelRecording() {
    if (!root.recording) return
    root.recording = false
    restorePreRecord()
    root._preRecord = null
  }

  function clearAll() {
    root.recording = false
    root._preRecord = null
    root.modSuper = false
    root.modCtrl = false
    root.modAlt = false
    root.modShift = false
    root.mainKey = ""
    root.composeKey()
  }

  function pickMainKey(name) {
    root.mainKey = name
    root.recording = false
    root._preRecord = null
    root.composeKey()
  }

  implicitWidth: containerLayout.implicitWidth
  implicitHeight: containerLayout.implicitHeight

  ColumnLayout {
    id: containerLayout
    width: parent.width
    spacing: Style.space(12)

    // 1. Key Display & Recording Box
    BorderSurface {
      id: box
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(56)
      radius: Style.cornerRadius
      color: root.recording
        ? Util.alpha(root.accent, 0.12)
        : (boxMouse.containsMouse ? Util.alpha(root.foreground, 0.06) : Util.alpha(root.foreground, 0.03))
      borderSpec: Border.flat(
        (root.hasConflict || root.incomplete)
          ? root.urgent
          : (root.recording ? root.accent : (boxMouse.containsMouse ? Util.alpha(root.foreground, 0.3) : Util.alpha(root.foreground, 0.15))),
        (root.recording || root.incomplete) ? 1.5 : 1
      )

      MouseArea {
        id: boxMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          if (!root.recording) root.startRecording()
          else root.stopRecording()
        }
      }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(16)
        anchors.rightMargin: Style.space(16)
        spacing: Style.space(14)

        Text {
          text: ""
          color: root.recording ? root.accent : ((root.hasConflict || root.incomplete) ? root.urgent : root.foreground)
          font.family: Style.font.family
          font.pixelSize: Style.font.title + 2
        }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // Recording mode: live chord + listening indicator
          RowLayout {
            visible: root.recording
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Rectangle {
              implicitWidth: Style.space(10)
              implicitHeight: Style.space(10)
              radius: implicitWidth / 2
              color: root.accent

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: root.recording
                PropertyAnimation { to: 0.2; duration: 400 }
                PropertyAnimation { to: 1.0; duration: 400 }
              }
            }

            KeyBadge {
              visible: root.value.length > 0
              keyText: root.value
              fontSize: Style.font.body
              accent: root.accent
            }

            Text {
              text: root.value.length > 0 ? "Listening… press the key (modifiers toggle)" : "Listening… press a combination (e.g. CTRL + O)"
              color: root.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // Idle mode with value
          RowLayout {
            visible: !root.recording && root.value.length > 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            KeyBadge {
              keyText: root.value
              fontSize: Style.font.body
              highlighted: root.hasConflict
              accent: root.hasConflict ? root.urgent : root.accent
            }

            // "chord incomplete" badge
            Text {
              visible: root.incomplete
              text: "+"
              color: Util.alpha(root.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            BorderSurface {
              visible: root.incomplete
              implicitHeight: Style.space(24)
              implicitWidth: incompleteLabel.implicitWidth + Style.space(12)
              radius: Style.cornerRadius
              color: Util.alpha(root.urgent, 0.15)
              borderSpec: Border.flat(root.urgent, 1)

              Text {
                id: incompleteLabel
                anchors.centerIn: parent
                text: "?"
                color: root.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            Text {
              visible: root.incomplete
              text: "Pick a key to complete the chord"
              color: root.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Empty state
          Text {
            visible: !root.recording && root.value.length === 0
            anchors.verticalCenter: parent.verticalCenter
            text: "Click Record, toggle modifier pills, or type a key below…"
            color: Util.alpha(root.foreground, 0.45)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        RowLayout {
          spacing: Style.space(8)

          Button {
            text: root.recording ? "Done" : "Record"
            iconText: root.recording ? "✓" : "⏺"
            accent: root.recording ? root.accent : root.foreground
            selected: root.recording
            horizontalPadding: Style.space(14)
            verticalPadding: Style.space(6)
            onClicked: {
              if (root.recording) root.stopRecording()
              else root.startRecording()
            }
          }

          Button {
            visible: root.value.length > 0
            iconText: "✕"
            tooltipText: "Clear shortcut"
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(6)
            onClicked: root.clearAll()
          }
        }
      }
    }

    // Super hint
    Text {
      visible: root.modSuper
      Layout.fillWidth: true
      text: "Super chords are grabbed by Hyprland before this window sees them — toggle Super here and press or type the key."
      color: Util.alpha(root.foreground, 0.65)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // 2. Modifier Toggle Pills & Key Field
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        text: "Modifiers:"
        color: Util.alpha(root.foreground, 0.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Button {
        text: "SUPER"
        selected: root.modSuper
        accent: root.accent
        horizontalPadding: Style.space(12)
        verticalPadding: Style.space(4)
        onClicked: {
          root.modSuper = !root.modSuper
          root.composeKey()
        }
      }

      Button {
        text: "CTRL"
        selected: root.modCtrl
        accent: root.accent
        horizontalPadding: Style.space(12)
        verticalPadding: Style.space(4)
        onClicked: {
          root.modCtrl = !root.modCtrl
          root.composeKey()
        }
      }

      Button {
        text: "ALT"
        selected: root.modAlt
        accent: root.accent
        horizontalPadding: Style.space(12)
        verticalPadding: Style.space(4)
        onClicked: {
          root.modAlt = !root.modAlt
          root.composeKey()
        }
      }

      Button {
        text: "SHIFT"
        selected: root.modShift
        accent: root.accent
        horizontalPadding: Style.space(12)
        verticalPadding: Style.space(4)
        onClicked: {
          root.modShift = !root.modShift
          root.composeKey()
        }
      }

      Item { Layout.fillWidth: true }

      Text {
        text: "Key:"
        color: Util.alpha(root.foreground, 0.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      TextField {
        id: manualKeyField
        Layout.preferredWidth: Style.space(110)
        maximumLength: 64
        placeholderText: "e.g. A, TAB"
        // One-way sync from mainKey happens in root.onMainKeyChanged; typing
        // here pushes into mainKey (guarded so neither side loops).
        onTextChanged: {
          if (root._syncingField) return
          var t = text.trim()
          if (root.mainKey !== t) {
            root._syncingField = true
            root.mainKey = t
            root._syncingField = false
            root.composeKey()
          }
        }
        onActiveFocusChanged: {
          if (activeFocus && root.recording) {
            root.recording = false
            root._preRecord = null
          }
        }
      }
    }

    // 3. Quick Key Chips
    Flow {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Repeater {
        model: ["RETURN", "SPACE", "ESCAPE", "TAB", "BACKSPACE", "DELETE", "PRINT", "F1", "F2", "F5", "F10", "F12"]

        BorderSurface {
          id: quickKeyChip
          required property string modelData
          readonly property bool isPicked: root.mainKey.toUpperCase() === modelData
          height: Style.space(26)
          width: chipTxt.implicitWidth + Style.space(16)
          radius: Style.cornerRadius
          color: isPicked
            ? Util.alpha(root.accent, 0.22)
            : (chipMouse.containsMouse ? Util.alpha(root.foreground, 0.1) : Util.alpha(root.foreground, 0.04))
          borderSpec: Border.flat(isPicked ? root.accent : Util.alpha(root.foreground, 0.15), 1)

          MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pickMainKey(quickKeyChip.modelData)
          }

          Text {
            id: chipTxt
            anchors.centerIn: parent
            text: quickKeyChip.modelData
            color: quickKeyChip.isPicked ? root.accent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: quickKeyChip.isPicked
          }
        }
      }
    }

    // 4. Conflict Alert Banner
    BorderSurface {
      id: conflictCard
      visible: root.hasConflict
      Layout.fillWidth: true
      Layout.preferredHeight: conflictCard.contentTopInset + conflictCard.contentBottomInset + conflictRowLayout.implicitHeight
      radius: Style.cornerRadius
      color: Util.alpha(root.urgent, 0.12)
      borderSpec: Border.flat(root.urgent, 1)
      padding: Style.space(14)

      Item {
        anchors.fill: parent
        anchors.topMargin: conflictCard.contentTopInset
        anchors.rightMargin: conflictCard.contentRightInset
        anchors.bottomMargin: conflictCard.contentBottomInset
        anchors.leftMargin: conflictCard.contentLeftInset

        RowLayout {
          id: conflictRowLayout
          anchors.fill: parent
          spacing: Style.space(12)

          Text {
            text: "⚠️"
            font.pixelSize: Style.font.title
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              text: "Shortcut already in use"
              color: root.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: {
                if (root.conflictMessage.length > 0) return root.conflictMessage
                if (!root.hasLocalConflict || !root.activeConflict || root.activeConflict.length === 0) return ""
                var descList = []
                for (var i = 0; i < root.activeConflict.length; i++) {
                  descList.push(root.activeConflict[i].description)
                }
                return root.value + " is " + descList.join(", ") + "."
              }
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  // Keyboard Event Catcher Scope
  FocusScope {
    id: keyCaptureFocus
    anchors.fill: parent
    focus: root.recording

    Keys.enabled: root.recording
    Keys.priority: Keys.BeforeItem

    Keys.onPressed: function(event) {
      if (!root.recording) return
      if (event.isAutoRepeat) {
        event.accepted = true
        return
      }

      var k = event.key
      var heldSuper = (event.modifiers & Qt.MetaModifier) !== 0
      var heldCtrl = (event.modifiers & Qt.ControlModifier) !== 0
      var heldAlt = (event.modifiers & Qt.AltModifier) !== 0
      var heldShift = (event.modifiers & Qt.ShiftModifier) !== 0

      // Escape alone cancels recording and restores the pre-record chord
      if (k === Qt.Key_Escape && !heldSuper && !heldCtrl && !heldAlt && !heldShift) {
        root.cancelRecording()
        event.accepted = true
        return
      }

      // Modifier-only keypress: toggle exactly that pill, keep recording
      if (k === Qt.Key_Meta || k === Qt.Key_Super_L || k === Qt.Key_Super_R) {
        root.modSuper = !root.modSuper
        root.composeKey()
        event.accepted = true
        return
      }
      if (k === Qt.Key_Control) {
        root.modCtrl = !root.modCtrl
        root.composeKey()
        event.accepted = true
        return
      }
      if (k === Qt.Key_Alt || k === Qt.Key_AltGr) {
        root.modAlt = !root.modAlt
        root.composeKey()
        event.accepted = true
        return
      }
      if (k === Qt.Key_Shift) {
        root.modShift = !root.modShift
        root.composeKey()
        event.accepted = true
        return
      }

      // Main key: OR the held modifiers into the pills, set the key, stop
      var keyName = Model.translateQtKey(event)
      if (keyName.length > 0) {
        root.modSuper = root.modSuper || heldSuper
        root.modCtrl = root.modCtrl || heldCtrl
        root.modAlt = root.modAlt || heldAlt
        root.modShift = root.modShift || heldShift
        root.mainKey = keyName
        root.recording = false
        root._preRecord = null
        root.composeKey()
        event.accepted = true
      }
    }
  }
}
