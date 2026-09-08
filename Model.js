// Helper functions for formatting labels, tooltip texts, and settings conversions.

function formatSpeed(sensitivity) {
  var s = Number(sensitivity) || 0
  if (Math.abs(s) < 0.05) return "Standard (1.0x)"
  if (s > 0) return "Fast (" + (1.0 + s).toFixed(2) + "x)"
  return "Slow (" + (1.0 + s).toFixed(2) + "x)"
}

function formatScrollSpeed(factor) {
  var f = Number(factor) || 1.0
  if (Math.abs(f - 1.0) < 0.05) return "Normal (1.0x)"
  return f.toFixed(2) + "x"
}

function formatDeviceName(rawName) {
  if (!rawName) return "Standard Mouse"
  var name = String(rawName).replace(/-/g, " ").replace(/_/g, " ")
  return name.replace(/\b\w/g, function(l) { return l.toUpperCase() })
}

function sideBackOptions() {
  return [
    { value: "default", label: "Browser Bck (Default)" },
    { value: "prev_workspace", label: "Prev Workspace" },
    { value: "menu", label: "Omarchy Menu" },
    { value: "prev_window", label: "Focus Prev Window" }
  ]
}

function sideForwardOptions() {
  return [
    { value: "default", label: "Browser Fwd (Default)" },
    { value: "next_workspace", label: "Next Workspace" },
    { value: "terminal", label: "Launch Terminal" },
    { value: "next_window", label: "Focus Next Window" }
  ]
}

function middleClickOptions() {
  return [
    { value: "default", label: "Standard (Paste / Tab)" },
    { value: "close_window", label: "Close Active Window" },
    { value: "toggle_floating", label: "Toggle Floating" },
    { value: "toggle_fullscreen", label: "Toggle Fullscreen" }
  ]
}

function simulateButtons() {
  return [
    { value: "left", label: "L" },
    { value: "right", label: "R" },
    { value: "middle", label: "M" },
    { value: "side_back", label: "S1" },
    { value: "side_forward", label: "S2" }
  ]
}

function formatBattery(battery, withModel) {
  if (!battery || battery.percent === undefined || battery.percent === null) return ""
  var s = " · 🔋 " + Math.round(Number(battery.percent)) + "%"
  if (withModel && battery.model) s += " (" + battery.model + ")"
  return s
}

function getOptionLabel(options, val) {
  for (var i = 0; i < options.length; i++) {
    if (options[i].value === val) return options[i].label
  }
  return options[0] ? options[0].label : ""
}

function getTooltipText(status) {
  if (!status) return "Mouse & Keybind Settings"
  var dev = formatDeviceName(status.primaryDevice || "Mouse")
  var mode = status.accel_profile === "flat" ? "Precision (1:1)" : "Dynamic"
  var spd = formatSpeed(status.sensitivity)
  return dev + " · " + mode + " · " + spd + formatBattery(status.battery, true)
}

function getKeybindSummary(activeCount, modifiedCount, conflictCount) {
  var parts = []
  if (activeCount > 0) parts.push(activeCount + " active")
  if (modifiedCount > 0) parts.push(modifiedCount + " modified")
  if (conflictCount > 0) parts.push(conflictCount + " conflicts!")
  return parts.length > 0 ? parts.join(" · ") : "No keybinds loaded"
}

// ---------------------------------------------------------------------------
// Key chord helpers shared by KeybindsPanel, KeyRecorder and EditKeybindDialog.
// The alias table mirrors backend/keybinds_manager.py normalize_key_chord():
//   modifiers  -> SUPER / SHIFT / CTRL / ALT (canonical uppercase, fixed order)
//   named keys -> RETURN, SPACE, ESCAPE, TAB, ... uppercase
//   Fn keys    -> F<n> uppercase
//   keysyms    -> comma, period, slash, semicolon, apostrophe, backslash,
//                 grave, ... kept in their lowercase xkb spelling
//   single chars -> uppercase
// ---------------------------------------------------------------------------

var MODIFIER_ORDER = { "SUPER": 1, "SHIFT": 2, "CTRL": 3, "ALT": 4 }

var NAMED_KEYS = ["RETURN", "ENTER", "SPACE", "ESCAPE", "TAB", "BACKSPACE", "DELETE", "PRINT",
                  "LEFT", "RIGHT", "UP", "DOWN"]

var LOWER_KEYSYMS = ["comma", "period", "slash", "minus", "equal", "bracketleft", "bracketright",
                     "semicolon", "apostrophe", "backslash", "grave"]

function modifierFor(part) {
  var u = String(part || "").trim().toUpperCase()
  if (u === "SUPER" || u === "WIN" || u === "LOGO" || u === "SUPER_L" || u === "SUPER_R" || u === "META" || u === "MOD4") return "SUPER"
  if (u === "SHIFT" || u === "SHIFT_L" || u === "SHIFT_R") return "SHIFT"
  if (u === "CTRL" || u === "CONTROL" || u === "CONTROL_L" || u === "CONTROL_R") return "CTRL"
  if (u === "ALT" || u === "ALT_L" || u === "ALT_R" || u === "MOD1") return "ALT"
  return ""
}

function canonicalMainKey(key) {
  var k = String(key || "").trim()
  if (!k) return ""
  var u = k.toUpperCase()
  if (NAMED_KEYS.indexOf(u) !== -1) return u
  if (u.charAt(0) === "F" && u.length > 1 && /^\d+$/.test(u.substring(1))) return u
  var lower = k.toLowerCase()
  if (LOWER_KEYSYMS.indexOf(lower) !== -1) return lower
  if (k.length === 1) return u
  return k
}

// Split a chord ("SUPER + SHIFT + F", "SUPER, F", "super+f") into its parts.
function parseChord(chord) {
  var res = { modSuper: false, modCtrl: false, modAlt: false, modShift: false, mainKey: "" }
  if (!chord) return res
  var raw = String(chord).replace(/,/g, "+").split("+")
  for (var i = 0; i < raw.length; i++) {
    var p = raw[i].trim()
    if (!p) continue
    var m = modifierFor(p)
    if (m === "SUPER") res.modSuper = true
    else if (m === "CTRL") res.modCtrl = true
    else if (m === "ALT") res.modAlt = true
    else if (m === "SHIFT") res.modShift = true
    else res.mainKey = p
  }
  return res
}

// Compose a chord from flags + main key in canonical order/spelling.
function composeChord(modSuper, modShift, modCtrl, modAlt, mainKey) {
  var mods = []
  if (modSuper) mods.push("SUPER")
  if (modShift) mods.push("SHIFT")
  if (modCtrl) mods.push("CTRL")
  if (modAlt) mods.push("ALT")
  var key = canonicalMainKey(mainKey)
  if (mods.length > 0 && key) return mods.join(" + ") + " + " + key
  if (mods.length > 0) return mods.join(" + ")
  return key
}

function normalizeKey(keyChord) {
  if (!keyChord) return ""
  var p = parseChord(keyChord)
  return composeChord(p.modSuper, p.modShift, p.modCtrl, p.modAlt, p.mainKey)
}

// Map a Qt key event to the Hyprland key name used in bindings ("" if unknown).
function translateQtKey(event) {
  var key = event.key
  var text = event.text

  if (key === Qt.Key_Return || key === Qt.Key_Enter) return "RETURN"
  if (key === Qt.Key_Space) return "SPACE"
  if (key === Qt.Key_Escape) return "ESCAPE"
  if (key === Qt.Key_Tab || key === Qt.Key_Backtab) return "TAB"
  if (key === Qt.Key_Backspace) return "BACKSPACE"
  if (key === Qt.Key_Delete) return "DELETE"
  if (key === Qt.Key_Print) return "PRINT"
  if (key === Qt.Key_Left) return "LEFT"
  if (key === Qt.Key_Right) return "RIGHT"
  if (key === Qt.Key_Up) return "UP"
  if (key === Qt.Key_Down) return "DOWN"
  if (key === Qt.Key_Comma) return "comma"
  if (key === Qt.Key_Period) return "period"
  if (key === Qt.Key_Slash) return "slash"
  if (key === Qt.Key_Minus) return "minus"
  if (key === Qt.Key_Equal) return "equal"
  if (key === Qt.Key_BracketLeft) return "bracketleft"
  if (key === Qt.Key_BracketRight) return "bracketright"
  if (key === Qt.Key_Semicolon) return "semicolon"
  if (key === Qt.Key_Apostrophe) return "apostrophe"
  if (key === Qt.Key_Backslash) return "backslash"
  if (key === Qt.Key_QuoteLeft) return "grave"
  if (key === Qt.Key_PageUp) return "Page_Up"
  if (key === Qt.Key_PageDown) return "Page_Down"
  if (key === Qt.Key_Home) return "Home"
  if (key === Qt.Key_End) return "End"
  if (key === Qt.Key_Insert) return "Insert"

  // Media / hardware keys map to their XF86 keysyms.
  if (key === Qt.Key_VolumeUp) return "XF86AudioRaiseVolume"
  if (key === Qt.Key_VolumeDown) return "XF86AudioLowerVolume"
  if (key === Qt.Key_VolumeMute) return "XF86AudioMute"
  if (key === Qt.Key_MicMute) return "XF86AudioMicMute"
  if (key === Qt.Key_MediaPlay || key === Qt.Key_MediaTogglePlayPause) return "XF86AudioPlay"
  if (key === Qt.Key_MediaPause) return "XF86AudioPause"
  if (key === Qt.Key_MediaStop) return "XF86AudioStop"
  if (key === Qt.Key_MediaNext) return "XF86AudioNext"
  if (key === Qt.Key_MediaPrevious) return "XF86AudioPrev"
  if (key === Qt.Key_MonBrightnessUp) return "XF86MonBrightnessUp"
  if (key === Qt.Key_MonBrightnessDown) return "XF86MonBrightnessDown"

  if (key >= Qt.Key_F1 && key <= Qt.Key_F24) {
    return "F" + (key - Qt.Key_F1 + 1)
  }

  if (key >= Qt.Key_0 && key <= Qt.Key_9) {
    return String.fromCharCode(key)
  }

  if (key >= Qt.Key_A && key <= Qt.Key_Z) {
    return String.fromCharCode(key)
  }

  if (text && text.length === 1 && text.charCodeAt(0) >= 33 && text.charCodeAt(0) <= 126) {
    return text.toUpperCase()
  }

  return ""
}

// True when a key name alone (no modifier) is an acceptable binding.
function isStandaloneKey(mainKey) {
  var k = canonicalMainKey(mainKey)
  return /^(F\d+|XF86|PRINT)/.test(k)
}

// Stable identity for a model row: backend `id`, else lower-cased description.
function rowId(row) {
  if (!row) return ""
  if (row.id !== undefined && row.id !== null && String(row.id).length > 0) return String(row.id)
  return String(row.description || "").toLowerCase()
}

// Active (non-disabled, non-mouse) rows holding `key`, excluding `excludeId`.
// `model` may be the full list JSON ({active: [...]}) or a plain row array.
function holdersOf(model, key, excludeId) {
  var target = normalizeKey(key)
  if (!target) return []
  var list = Array.isArray(model) ? model : ((model && model.active) || [])
  var out = []
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (!b || !b.key || b.status === "disabled" || b.is_mouse) continue
    if (excludeId && rowId(b) === excludeId) continue
    if (normalizeKey(b.key) === target) out.push(b)
  }
  return out
}

function findRowById(model, id) {
  if (!id) return null
  var list = Array.isArray(model) ? model : ((model && model.active) || [])
  for (var i = 0; i < list.length; i++) {
    if (list[i] && rowId(list[i]) === id) return list[i]
  }
  return null
}

function findRow(model, description, key) {
  var list = Array.isArray(model) ? model : ((model && model.active) || [])
  var target = normalizeKey(key)
  var desc = String(description || "").toLowerCase()
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (!b) continue
    if (String(b.description || "").toLowerCase() === desc && (!target || normalizeKey(b.key) === target)) return b
  }
  return null
}

function conflictModeLabel(mode) {
  if (mode === "override") return "Just override"
  if (mode === "ask") return "Ask every time"
  return "Rehome the other binding"
}
