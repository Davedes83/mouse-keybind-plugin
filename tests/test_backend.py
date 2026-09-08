#!/usr/bin/env python3
"""Backend tests. Everything runs against a temp HOME with a fixture stock
directory and a fake hyprctl; the real ~/.config/hypr/bindings.lua is only
ever COPIED (never written) and `hyprctl reload` never runs for real."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

BACKEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "backend"))
sys.path.insert(0, BACKEND_DIR)
import keybinds_manager as km  # noqa: E402

REAL_USER_FILE = os.path.join(os.path.expanduser("~"), ".config", "hypr", "bindings.lua")

STOCK = {
    "tiling.lua": '''o.bind("SUPER + W", "Close window", hl.dsp.window.close())
o.bind("SUPER + J", "Toggle window split", hl.dsp.layout("togglesplit"))
o.bind("SUPER + T", "Toggle window floating/tiling", hl.dsp.window.float({ action = "toggle" }))
o.bind("SUPER + F", "Full screen", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
o.bind("SUPER + ALT + F", "Full width", hl.dsp.window.fullscreen({ mode = "maximized" }))
o.bind("SUPER + O", "Pop window out (float & pin)", "omarchy-hyprland-window-pop")
o.bind("SUPER + LEFT", "Focus on left window", hl.dsp.focus({ direction = "l" }))

for workspace = 1, 10 do
  local key = "code:" .. tostring(workspace + 9)
  o.bind("SUPER + " .. key, "Switch to workspace " .. workspace, hl.dsp.focus({ workspace = tostring(workspace) }))
end

o.bind("SUPER + S", "Toggle scratchpad", hl.dsp.workspace.toggle_special("scratchpad"))
o.bind("SUPER + ALT + S", "Move window to scratchpad", hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }))
o.bind("SUPER + TAB", "Next workspace", hl.dsp.focus({ workspace = "e+1" }))
o.bind("SUPER + SHIFT + TAB", "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))
o.bind("ALT + TAB", "Focus on next window", hl.dsp.window.cycle_next())
o.bind("ALT + TAB", "Reveal active window on top", hl.dsp.window.bring_to_top())
o.bind("SUPER + SLASH", "Monitor scaling up", "omarchy-hyprland-monitor-scaling up")
''',
    "applications.lua": '''o.bind("SUPER + RETURN", "Terminal", { omarchy = "terminal" })
o.bind("SUPER + SHIFT + RETURN", "Browser", { omarchy = "browser" })
o.bind("SUPER + SHIFT + F", "File manager", { omarchy = "nautilus" })
o.bind("SUPER + SHIFT + M", "Music", o.launch_sole("spotify", "spotify"))
o.bind("SUPER + SHIFT + SLASH", "Passwords", "omarchy-install-service-1password")
o.bind("SUPER + SHIFT + W", "Omawrite", "omawrite")
''',
    "utilities.lua": '''o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle")
o.bind("SUPER + K", "Keybindings", "omarchy-menu-keybindings")
o.bind("SUPER + comma", "Dismiss last notification", "omarchy-shell notifications dismissOne")
o.bind("SUPER + CTRL + L", "Lock system", "omarchy-system-lock")
o.bind("SUPER + CTRL + Z", "Zoom in", function()
  local zoom = hl.get_config("cursor.zoom_factor") or 1
  hl.config({ cursor = { zoom_factor = zoom + 1 } })
end)
''',
    "media.lua": '''o.bind("XF86AudioRaiseVolume", "Volume up", "omarchy-audio-output-volume raise", { locked = true, repeating = true })
o.bind("XF86AudioNext", "Next track", "omarchy-shell media next", { locked = true })
o.bind("ALT + XF86AudioPlay", "Next track", "omarchy-shell media next", { locked = true })
o.bind("XF86AudioPrev", "Previous track", "omarchy-shell media previous", { locked = true })
''',
    "voxtype.lua": '''if o.cmd_present("voxtype") then
  o.bind("SUPER + CTRL + X", "Toggle dictation", "voxtype record toggle")
  o.bind("F9", "Start dictation (push-to-talk)", "voxtype record start")
  o.bind("F9", "Stop dictation (push-to-talk)", "voxtype record stop", { release = true })
end
''',
}

FAKE_HYPRCTL = '''#!/bin/sh
echo "hyprctl $*" >> "$FAKE_HYPRCTL_LOG"
case "$1" in
  configerrors) [ -n "$FAKE_CONFIGERRORS" ] && echo "$FAKE_CONFIGERRORS"; exit 0 ;;
  reload) echo ok; exit 0 ;;
  *) echo '{}'; exit 0 ;;
esac
'''

HAND_WRITTEN = '''-- header comment
-- hl.unbind("SUPER + SHIFT + B")
local sws = { { "H", "hey" } }
for _, s in ipairs(sws) do
  hl.unbind("SUPER + " .. s[1])
  o.bind("SUPER + " .. s[1], "Special: " .. s[2], toggle_and_present(s[2]))
end
o.bind("SUPER + grave", "Toggle scratchpad", hl.dsp.workspace.toggle_special("scratchpad"))
o.bind("SUPER + SHIFT + grave", "Move window to scratchpad",
  hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }))
hl.unbind("SUPER + SHIFT + RETURN")
o.bind("SUPER + SHIFT + RETURN", "Terminal", "omarchy-launch-terminal")
o.bind("SUPER + Q", "Close window", hl.dsp.window.close())
hl.unbind("SUPER + S") -- stock scratchpad, rehomed to SUPER+grave
o.bind("SUPER + S", "Spotify (full player)",
  "omarchy shell -q quickshell.spotify.player toggleFullPlayer")
hl.unbind("SUPER + SHIFT + SLASH") -- 1Password
local zen_tab_binds = {
  hl.bind("CTRL + 1", hl.dsp.send_shortcut({ mods = "CTRL", key = "Prior", window = "activewindow" }),
    { description = "Zen: previous tab" }),
}
hl.on("window.active", function(win)
  zen_tabs(true)
end)
'''


def _block_of(content):
    m = km.BLOCK_RE.search(content)
    return m.group(0) if m else None


def _outside_of(content):
    m = km.BLOCK_RE.search(content)
    if not m:
        return content
    return content[:m.start()] + content[m.end():]


def _block_lines(block):
    skip = {km.BLOCK_START, km.BLOCK_END, km.BLOCK_HEADER}
    return [l for l in (block or "").split("\n") if l.strip() and l not in skip]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mkp-test-")
        self.home = os.path.join(self.tmp, "home")
        self.hypr_dir = os.path.join(self.home, ".config", "hypr")
        os.makedirs(self.hypr_dir)
        self.user_file = os.path.join(self.hypr_dir, "bindings.lua")
        self.stock_dir = os.path.join(self.tmp, "omarchy", "default", "hypr", "bindings")
        os.makedirs(self.stock_dir)
        for name, text in STOCK.items():
            with open(os.path.join(self.stock_dir, name), "w") as f:
                f.write(text)
        self.fake_hyprctl = os.path.join(self.tmp, "hyprctl")
        with open(self.fake_hyprctl, "w") as f:
            f.write(FAKE_HYPRCTL)
        os.chmod(self.fake_hyprctl, 0o755)
        self.log = os.path.join(self.tmp, "hyprctl.log")
        self.env_backup = {k: os.environ.get(k) for k in
                           ("HOME", "OMARCHY_PATH", "OMARCHY_KEYBINDS_HYPRCTL", "FAKE_HYPRCTL_LOG", "FAKE_CONFIGERRORS")}
        os.environ["HOME"] = self.home
        os.environ["OMARCHY_PATH"] = os.path.join(self.tmp, "omarchy")
        os.environ["OMARCHY_KEYBINDS_HYPRCTL"] = self.fake_hyprctl
        os.environ["FAKE_HYPRCTL_LOG"] = self.log
        os.environ.pop("FAKE_CONFIGERRORS", None)
        self.saved = (km.USER_BINDINGS_PATH, km.DEFAULT_BINDINGS_DIR, km.HYPRCTL, km.reload_hyprland)
        km.USER_BINDINGS_PATH = self.user_file
        km.DEFAULT_BINDINGS_DIR = self.stock_dir
        km.HYPRCTL = self.fake_hyprctl
        self.reloads = []
        km.reload_hyprland = lambda: (self.reloads.append(1) or {"success": True, "reload_output": "ok", "config_errors": ""})

    def tearDown(self):
        km.USER_BINDINGS_PATH, km.DEFAULT_BINDINGS_DIR, km.HYPRCTL, km.reload_hyprland = self.saved
        for k, v in self.env_backup.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    # helpers
    def write_user(self, text):
        with open(self.user_file, "w") as f:
            f.write(text)

    def read_user(self):
        with open(self.user_file) as f:
            return f.read()

    def read_bytes(self):
        with open(self.user_file, "rb") as f:
            return f.read()

    def rows(self):
        m = km.build_complete_model()
        return m, {r["id"]: r for r in m["active"]}

    def row(self, rid):
        return self.rows()[1][rid]


class TestParsing(Base):
    def test_normalize_key_chord(self):
        self.assertEqual(km.normalize_key_chord("SUPER + A"), "SUPER + A")
        self.assertEqual(km.normalize_key_chord("CTRL + ALT + DELETE"), "CTRL + ALT + DELETE")
        self.assertEqual(km.normalize_key_chord("ctrl+a"), "CTRL + A")
        self.assertEqual(km.normalize_key_chord("SUPER+SHIFT+RETURN"), "SUPER + SHIFT + RETURN")
        self.assertEqual(km.normalize_key_chord("SHIFT+SUPER+ctrl+w"), "SUPER + SHIFT + CTRL + W")
        self.assertEqual(km.normalize_key_chord("XF86AudioMute"), "XF86AudioMute")

    def test_parse_default_bindings(self):
        binds = km.parse_default_bindings()
        self.assertGreater(len(binds), 20)
        keys = [b["key"] for b in binds]
        self.assertIn("SUPER + RETURN", keys)
        self.assertIn("SUPER + SPACE", keys)
        by_id = {b["id"]: b for b in binds}
        self.assertEqual(by_id["close window"]["category"], "Window Management")
        self.assertEqual(by_id["terminal"]["category"], "Applications")
        # duplicated stock descriptions get a chord suffix on the 2nd occurrence
        self.assertEqual(by_id["next track"]["key"], "XF86AudioNext")
        self.assertIn("next track@ALT + XF86AudioPlay", by_id)
        self.assertTrue(by_id["stop dictation (push-to-talk)"]["is_release"])
        self.assertFalse(by_id["start dictation (push-to-talk)"]["is_release"])
        # multi-line function dispatcher is joined, not truncated
        self.assertIn("zoom_factor = zoom + 1", by_id["zoom in"]["action"])
        # loop forms are skipped, not crashed on
        self.assertFalse(any("Switch to workspace" in b["description"] for b in binds))

    def test_skip_comments_in_user_bindings(self):
        self.write_user('-- hl.unbind("SUPER + SHIFT + B")\n-- o.bind("SUPER + X", "Test", "test-cmd")\n')
        parsed = km.parse_user_bindings()
        self.assertNotIn("SUPER + SHIFT + B", parsed["unbinds"])
        self.assertEqual(len(parsed["binds"]), 0)

    def test_parse_bind_line_roundtrip(self):
        cases = [
            ('o.bind("SUPER + LEFT", "Focus Left", hl.dsp.focus.left())',
             "SUPER + LEFT", "Focus Left", "hl.dsp.focus.left()"),
            ('o.bind("SUPER + SHIFT + LEFT", "Move Left", hl.dsp.window.move({ direction = "left" }))',
             "SUPER + SHIFT + LEFT", "Move Left", 'hl.dsp.window.move({ direction = "left" })'),
            ('o.bind("SUPER + T", "Toggle Float", hl.dsp.window.float({ action = "toggle" }))',
             "SUPER + T", "Toggle Float", 'hl.dsp.window.float({ action = "toggle" })'),
            ('o.bind("SUPER + J", "Toggle Split", hl.dsp.layout("togglesplit"))',
             "SUPER + J", "Toggle Split", 'hl.dsp.layout("togglesplit")'),
            ('o.bind("SUPER + TAB", "Next WS", hl.dsp.focus({ workspace = "e+1" }))',
             "SUPER + TAB", "Next WS", 'hl.dsp.focus({ workspace = "e+1" })'),
            ('o.bind("SUPER + S", "Scratch", hl.dsp.special_workspace.focus({ name = "scratchpad" }))',
             "SUPER + S", "Scratch", 'hl.dsp.special_workspace.focus({ name = "scratchpad" })'),
            ('o.bind_toggle("SUPER + F5", "Toggle Bar", hl.dsp.bar.toggle())',
             "SUPER + F5", "Toggle Bar", "hl.dsp.bar.toggle()"),
            ('o.bind("SUPER + K", "Menu", "exec")',
             "SUPER + K", "Menu", '"exec"'),
        ]
        for line, exp_key, exp_desc, exp_action in cases:
            result = km._parse_bind_line(line)
            self.assertIsNotNone(result, f"Failed to parse: {line}")
            key, desc, action, opts = result
            self.assertEqual(key, exp_key, f"Key mismatch for: {line}")
            self.assertEqual(desc, exp_desc, f"Desc mismatch for: {line}")
            self.assertEqual(action, exp_action, f"Action mismatch for: {line}")
        key, desc, action, opts = km._parse_bind_line('o.bind("F9", "Stop", "voxtype record stop", { release = true })')
        self.assertEqual(opts, "{ release = true }")

    def test_multiline_bind_parsed_with_action(self):
        self.write_user(HAND_WRITTEN)
        r = self.row("move window to scratchpad")
        self.assertEqual(r["key"], "SUPER + SHIFT + grave")
        self.assertEqual(r["action"], 'hl.dsp.window.move({ workspace = "special:scratchpad", follow = false })')
        self.assertEqual(r["source"], "user-file")
        self.assertEqual(r["status"], "modified")
        self.assertEqual(r["default_key"], "SUPER + ALT + S")
        self.assertEqual(r["file_line"], 9)
        spot = self.row("spotify (full player)")
        self.assertEqual(spot["command"], "omarchy shell -q quickshell.spotify.player toggleFullPlayer")

    def test_loop_and_hl_bind_lines_ignored(self):
        self.write_user(HAND_WRITTEN)
        m, rows = self.rows()
        self.assertFalse(any(r["description"].startswith("Special:") for r in m["active"]))
        self.assertFalse(any("Zen" in r["description"] for r in m["active"]))
        self.assertFalse(any("SUPER + \" .." in (r["key"] or "") for r in m["active"]))
        # the line after the loop / table is still parsed
        self.assertEqual(rows["close window"]["key"], "SUPER + Q")
        self.assertEqual(rows["close window"]["source"], "user-file")
        # hand-written unbinds disable the stock rows they hit
        self.assertEqual(rows["browser"]["status"], "disabled")
        self.assertIsNone(rows["browser"]["key"])
        self.assertEqual(rows["passwords"]["status"], "disabled")
        # ... unless a hand-written bind takes the identity elsewhere
        self.assertEqual(rows["toggle scratchpad"]["key"], "SUPER + grave")
        self.assertEqual(rows["terminal"]["key"], "SUPER + SHIFT + RETURN")
        self.assertEqual(m["total_conflicts"], 0)

    def test_model_reports_collision_on_stock_chord(self):
        self.write_user('o.bind("SUPER + W", "Kill it", "xkill")\n')
        m, rows = self.rows()
        self.assertEqual(rows["close window"]["key"], "SUPER + W")
        self.assertEqual(rows["kill it"]["key"], "SUPER + W")
        self.assertTrue(rows["close window"]["is_conflict"])
        self.assertTrue(rows["kill it"]["is_conflict"])
        self.assertEqual(rows["close window"]["conflict_with"], ["Kill it"])
        self.assertEqual(m["total_conflicts"], 1)
        self.assertEqual(m["conflicts"][0]["key"], "SUPER + W")
        self.assertEqual({b["description"] for b in m["conflicts"][0]["bindings"]}, {"Close window", "Kill it"})
        # the release pair / stock composite are not conflicts
        self.assertFalse(rows["focus on next window"]["is_conflict"])
        self.assertFalse(rows["start dictation (push-to-talk)"]["is_conflict"])
        for r in m["active"]:
            self.assertIsInstance(r["is_conflict"], bool)
            self.assertIsInstance(r["conflict_with"], list)

    def test_no_action_text_matching(self):
        self.write_user('o.bind("SUPER + Q", "Close window please", hl.dsp.window.close())\n')
        m, rows = self.rows()
        self.assertEqual(rows["close window"]["status"], "default")
        self.assertEqual(rows["close window"]["key"], "SUPER + W")
        self.assertEqual(rows["close window please"]["status"], "custom")
        self.assertEqual(rows["close window please"]["default_key"], "")

    def test_model_shape(self):
        self.write_user("")
        m, rows = self.rows()
        for k in ("active", "catalog", "conflicts", "total_active", "total_modified", "total_conflicts",
                  "block_exists", "pending_migration", "user_bindings_file"):
            self.assertIn(k, m)
        r = rows["close window"]
        for k in ("id", "key", "description", "action", "command", "category", "status", "source", "managed",
                  "default_key", "default_action", "origin_key", "is_conflict", "conflict_with", "file_line",
                  "is_mouse", "is_release"):
            self.assertIn(k, r)
        self.assertEqual(m["total_active"], len([x for x in m["active"] if x["key"]]))
        preset = next(c for c in m["catalog"] if c["name"] == "Close Window")
        self.assertEqual(preset["current_key"], "SUPER + W")
        self.assertTrue(preset["is_bound"])


class TestWrites(Base):
    def test_set_custom_and_reset_keeps_mouse_block(self):
        self.write_user('-- Header\n-- [[ OMARCHY_MOUSE_BINDINGS_START ]]\no.bind("mouse:275", "Prev", "prev_ws", { mouse = true })\n-- [[ OMARCHY_MOUSE_BINDINGS_END ]]\n')
        original = self.read_user()
        res = km.set_keybinding("SUPER + SHIFT + Z", "Custom Tool", "my-tool")
        self.assertTrue(res["success"], res)
        self.assertEqual(len(self.reloads), 1)
        content = self.read_user()
        self.assertIn("OMARCHY_MOUSE_BINDINGS_START", content)
        self.assertIn("mouse:275", content)
        self.assertEqual(_outside_of(content).rstrip("\n"), original.rstrip("\n"))
        ctx = km.load_context()
        recs = km.load_records(ctx.block, ctx)
        self.assertEqual([(r["id"], r["key"], r["action"]) for r in recs],
                         [("custom tool", "SUPER + SHIFT + Z", '"my-tool"')])
        r = self.row("custom tool")
        self.assertEqual((r["status"], r["source"], r["managed"], r["command"]), ("custom", "managed", True, "my-tool"))
        res = km.reset_keybinding("SUPER + SHIFT + Z", "")
        self.assertTrue(res["success"], res)
        self.assertTrue(res["deleted"])
        self.assertEqual(self.read_user(), original)
        self.assertNotIn("custom tool", self.rows()[1])

    def test_write_and_reparse_preserves_parens(self):
        self.write_user("")
        dispatchers = [
            ("SUPER + W", "Close", "hl.dsp.window.close()"),
            ("SUPER + F", "Fullscreen", "hl.dsp.window.fullscreen()"),
            ("SUPER + ALT + F", "Full Width", "hl.dsp.window.fullwidth()"),
            ("SUPER + T", "Float", 'hl.dsp.window.float({ action = "toggle" })'),
            ("SUPER + J", "Split", 'hl.dsp.layout("togglesplit")'),
            ("SUPER + LEFT", "Focus L", "hl.dsp.focus.left()"),
            ("SUPER + SHIFT + LEFT", "Move L", 'hl.dsp.window.move({ direction = "left" })'),
            ("SUPER + TAB", "Next WS", 'hl.dsp.focus({ workspace = "e+1" })'),
            ("SUPER + S", "Scratch", 'hl.dsp.special_workspace.focus({ name = "scratchpad" })'),
            ("SUPER + ALT + S", "Move to Scratch", 'hl.dsp.special_workspace.move_window({ name = "scratchpad" })'),
        ]
        for k, d, a in dispatchers:
            res = km.set_keybinding(k, d, a, "", "", displace=True)
            self.assertTrue(res["success"], res)
        ctx = km.load_context()
        recs = {r["id"]: r for r in km.load_records(ctx.block, ctx)}
        for k, d, a in dispatchers:
            self.assertEqual(recs[d.lower()]["action"], a)
            self.assertEqual(recs[d.lower()]["key"], k)
        # the stock binds those chords held are now explicit disabled records
        self.assertEqual(self.row("close window")["status"], "disabled")
        # every block statement round-trips byte-identically through the parser
        block = _block_of(self.read_user())
        ctx2 = km.load_context()
        self.assertEqual(km.render_block(km.load_records(block, ctx2), ctx2), block)

    def _swap(self, first_key, first_desc, first_action, second_key, second_desc, second_action):
        res = km.set_keybinding(first_key, first_desc, first_action, displace=True)
        self.assertTrue(res["success"], res)
        res = km.set_keybinding(second_key, second_desc, second_action)
        self.assertTrue(res["success"], res)
        return _block_of(self.read_user())

    def test_swap_two_stock_bindings_either_order(self):
        fs = 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'
        fw = 'hl.dsp.window.fullscreen({ mode = "maximized" })'
        self.write_user("")
        block_a = self._swap("SUPER + ALT + F", "Full screen", fs, "SUPER + F", "Full width", fw)
        self.write_user("")
        block_b = self._swap("SUPER + F", "Full width", fw, "SUPER + ALT + F", "Full screen", fs)
        self.assertEqual(block_a, block_b)
        lines = _block_lines(block_a)
        self.assertEqual(lines[:2], ['hl.unbind("SUPER + F")', 'hl.unbind("SUPER + ALT + F")'])
        self.assertEqual(lines[2], f'o.bind("SUPER + ALT + F", "Full screen", {fs}) -- was SUPER + F')
        self.assertEqual(lines[3], f'o.bind("SUPER + F", "Full width", {fw}) -- was SUPER + ALT + F')
        self.assertEqual(len(lines), 4)
        m, rows = self.rows()
        self.assertEqual(rows["full screen"]["key"], "SUPER + ALT + F")
        self.assertEqual(rows["full width"]["key"], "SUPER + F")
        self.assertEqual(rows["full screen"]["status"], "modified")
        self.assertEqual(rows["full width"]["status"], "modified")
        self.assertEqual(len([r for r in m["active"] if r["description"] in ("Full screen", "Full width")]), 2)
        self.assertEqual(m["total_conflicts"], 0)
        self.assertEqual(m["total_modified"], 2)

    def test_move_onto_stock_chord_refuses_without_displace(self):
        self.write_user("")
        res = km.set_keybinding("SUPER + W", "My close", "mycmd")
        self.assertFalse(res["success"])
        self.assertEqual(res["conflict"]["description"], "Close window")
        self.assertEqual(res["error"], "SUPER + W is held by Close window")
        self.assertEqual(self.read_user(), "")
        self.assertEqual(self.reloads, [])
        res = km.set_keybinding("SUPER + W", "My close", "mycmd", displace=True)
        self.assertTrue(res["success"], res)
        d = res["displaced"]
        self.assertEqual((d["id"], d["status"], d["key"], d["default_key"]), ("close window", "disabled", None, "SUPER + W"))
        m, rows = self.rows()
        self.assertEqual(rows["close window"]["status"], "disabled")
        self.assertIsNone(rows["close window"]["key"])
        self.assertEqual(rows["my close"]["key"], "SUPER + W")
        self.assertEqual(m["total_conflicts"], 0)
        lines = _block_lines(_block_of(self.read_user()))
        self.assertEqual(lines, [
            'hl.unbind("SUPER + W")',
            'o.bind("SUPER + W", "My close", "mycmd")',
            '-- disabled: o.bind("SUPER + W", "Close window", hl.dsp.window.close())',
        ])

    def test_enable_refuses_when_default_chord_taken(self):
        self.write_user("")
        km.set_keybinding("SUPER + W", "My close", "mycmd", displace=True)
        res = km.enable_keybinding("Close window")
        self.assertFalse(res["success"])
        self.assertEqual(res["conflict"]["description"], "My close")
        self.assertEqual(self.row("close window")["status"], "disabled")
        res = km.enable_keybinding("x", rec_id="close window")
        self.assertFalse(res["success"])
        # by chord, SUPER + W now names the row actually holding it (My close)
        res = km.enable_keybinding("SUPER + W")
        self.assertEqual((res["success"], res["changed"], res["id"]), (True, False, "my close"))
        self.assertTrue(km.reset_keybinding("SUPER + W", "", rec_id="my close")["success"])
        res = km.enable_keybinding("Close window")
        self.assertTrue(res["success"], res)
        self.assertEqual(self.row("close window")["status"], "default")
        self.assertEqual(self.read_user(), "")  # no records left: block removed

    def test_reset_does_not_remove_shared_unbind(self):
        self.write_user("")
        fs = 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'
        self.assertTrue(km.set_keybinding("SUPER + B", "Full screen", fs)["success"])
        self.assertTrue(km.set_keybinding("SUPER + F", "Other thing", "cmd")["success"])
        self.assertIn('hl.unbind("SUPER + F")', _block_lines(_block_of(self.read_user())))
        res = km.reset_keybinding("SUPER + F")
        self.assertTrue(res["success"], res)
        lines = _block_lines(_block_of(self.read_user()))
        self.assertEqual(lines, ['hl.unbind("SUPER + F")', f'o.bind("SUPER + B", "Full screen", {fs}) -- was SUPER + F'])
        # resetting Full screen while Other thing still holds SUPER + F is refused
        self.assertTrue(km.set_keybinding("SUPER + F", "Other thing", "cmd")["success"])
        res = km.reset_keybinding("SUPER + B")
        self.assertFalse(res["success"])
        self.assertEqual(res["conflict"]["description"], "Other thing")

    def test_disable_custom_keeps_row_and_enable_restores(self):
        self.write_user("")
        self.assertTrue(km.set_keybinding("SUPER + SHIFT + Z", "Custom Tool", "my-tool")["success"])
        res = km.disable_keybinding("SUPER + SHIFT + Z")
        self.assertTrue(res["success"], res)
        r = self.row("custom tool")
        self.assertEqual((r["status"], r["key"], r["last_key"], r["command"]), ("disabled", None, "SUPER + SHIFT + Z", "my-tool"))
        self.assertEqual(_block_lines(_block_of(self.read_user())),
                         ['-- disabled: o.bind("SUPER + SHIFT + Z", "Custom Tool", "my-tool")'])
        # the chord is free now, so someone else may take it ...
        self.assertTrue(km.set_keybinding("SUPER + SHIFT + Z", "Other", "o")["success"])
        res = km.enable_keybinding("Custom Tool")
        self.assertFalse(res["success"])
        self.assertEqual(res["conflict"]["description"], "Other")
        self.assertTrue(km.reset_keybinding("Other")["success"])
        res = km.enable_keybinding("Custom Tool")
        self.assertTrue(res["success"], res)
        r = self.row("custom tool")
        self.assertEqual((r["status"], r["key"], r["command"]), ("custom", "SUPER + SHIFT + Z", "my-tool"))
        self.assertEqual(_block_lines(_block_of(self.read_user())),
                         ['o.bind("SUPER + SHIFT + Z", "Custom Tool", "my-tool")'])

    def test_disable_and_enable_stock(self):
        self.write_user("")
        self.assertTrue(km.disable_keybinding("SUPER + K")["success"])
        r = self.row("keybindings")
        self.assertEqual((r["status"], r["key"], r["default_key"]), ("disabled", None, "SUPER + K"))
        self.assertEqual(_block_lines(_block_of(self.read_user())), [
            'hl.unbind("SUPER + K")',
            '-- disabled: o.bind("SUPER + K", "Keybindings", "omarchy-menu-keybindings")',
        ])
        self.assertTrue(km.enable_keybinding("SUPER + K")["success"])
        self.assertEqual(self.row("keybindings")["status"], "default")
        self.assertEqual(self.read_user(), "")

    def test_unbind_pruned_when_unused(self):
        self.write_user("")
        self.assertTrue(km.set_keybinding("SUPER + SHIFT + Z", "Free chord", "x")["success"])
        self.assertNotIn("hl.unbind", self.read_user())
        self.assertTrue(km.set_keybinding("SUPER + W", "On stock", "y", displace=True)["success"])
        self.assertIn('hl.unbind("SUPER + W")', self.read_user())
        self.assertTrue(km.reset_keybinding("On stock")["success"])
        self.assertIn('hl.unbind("SUPER + W")', self.read_user())  # Close window is still disabled
        self.assertTrue(km.enable_keybinding("Close window")["success"])
        self.assertNotIn("hl.unbind", self.read_user())
        self.assertTrue(km.reset_keybinding("Free chord")["success"])
        self.assertEqual(self.read_user(), "")

    def test_status_modified_when_only_action_changed(self):
        self.write_user("")
        res = km.set_keybinding("SUPER + W", "Close window", "other-cmd")
        self.assertTrue(res["success"], res)
        r = self.row("close window")
        self.assertEqual(r["status"], "modified")
        self.assertEqual(r["key"], r["default_key"])
        self.assertEqual(r["action"], '"other-cmd"')
        self.assertEqual(r["default_action"], "hl.dsp.window.close()")
        self.assertEqual(_block_lines(_block_of(self.read_user())),
                         ['hl.unbind("SUPER + W")', 'o.bind("SUPER + W", "Close window", "other-cmd")'])
        # setting it back to exactly the stock state drops the record
        self.assertTrue(km.set_keybinding("SUPER + W", "Close window", "hl.dsp.window.close()")["success"])
        self.assertEqual(self.read_user(), "")
        self.assertEqual(self.row("close window")["status"], "default")

    def test_rename_via_id_does_not_duplicate(self):
        self.write_user("")
        res = km.set_keybinding("SUPER + ALT + F", "Fullscreen!", 'hl.dsp.window.fullscreen({ mode = "fullscreen" })',
                                "", "SUPER + F", rec_id="full screen", displace=True)
        self.assertTrue(res["success"], res)
        m, rows = self.rows()
        self.assertEqual(rows["full screen"]["description"], "Fullscreen!")
        self.assertEqual(rows["full screen"]["key"], "SUPER + ALT + F")
        self.assertNotIn("fullscreen!", rows)
        self.assertIn("-- id: full screen; was SUPER + F", self.read_user())
        # old_key alone resolves the identity when the description was renamed
        self.write_user("")
        res = km.set_keybinding("SUPER + B", "Keybindings helper", "omarchy-menu-keybindings", "", "SUPER + K")
        self.assertTrue(res["success"], res)
        self.assertEqual(res["id"], "keybindings")
        self.assertEqual(self.row("keybindings")["key"], "SUPER + B")

    def test_check_is_pure_and_matches_set(self):
        self.write_user("")
        original = self.read_bytes()
        chk = km.check_keybinding("SUPER + W", "My close", command="mycmd", displace=True)
        self.assertEqual(self.read_bytes(), original)
        self.assertEqual(self.reloads, [])
        self.assertEqual(chk["conflict"]["description"], "Close window")
        self.assertEqual(chk["displaced"]["status"], "disabled")
        self.assertIsNone(chk["locked"])
        self.assertEqual(chk["would_unbind"], ["SUPER + W"])
        self.assertEqual(chk["would_remove"], [])
        res = km.set_keybinding("SUPER + W", "My close", "mycmd", displace=True)
        self.assertTrue(res["success"], res)
        lines = _block_lines(_block_of(self.read_user()))
        self.assertEqual(lines, [f'hl.unbind("{k}")' for k in chk["would_unbind"]] + chk["would_write"])
        # without --displace, check reports the conflict and an empty plan
        chk2 = km.check_keybinding("SUPER + F", "My close", command="mycmd")
        self.assertEqual(chk2["conflict"]["description"], "Full screen")
        self.assertEqual((chk2["would_unbind"], chk2["would_write"], chk2["would_remove"]), ([], [], []))
        self.assertFalse(chk2["changed"])
        # moving the record off SUPER + W would remove its lines
        chk3 = km.check_keybinding("SUPER + SHIFT + Z", "My close", command="mycmd")
        # the unbind stays: the displaced "Close window" record still needs it
        self.assertEqual(chk3["would_remove"], ['o.bind("SUPER + W", "My close", "mycmd")'])
        self.assertEqual(chk3["would_write"], ['o.bind("SUPER + SHIFT + Z", "My close", "mycmd")'])

    def test_hand_written_is_locked_and_shadowed(self):
        self.write_user(HAND_WRITTEN)
        chk = km.check_keybinding("SUPER + SHIFT + Q", "Close window", command="hl.dsp.window.close()")
        self.assertEqual(chk["locked"]["file_line"], 13)
        res = km.set_keybinding("SUPER + SHIFT + Q", "Close window", "hl.dsp.window.close()")
        self.assertTrue(res["success"], res)
        self.assertEqual(_block_lines(_block_of(self.read_user())), [
            'hl.unbind("SUPER + Q")',
            'o.bind("SUPER + SHIFT + Q", "Close window", hl.dsp.window.close()) -- was SUPER + Q',
        ])
        r = self.row("close window")
        self.assertEqual((r["key"], r["default_key"], r["source"], r["status"]), ("SUPER + SHIFT + Q", "SUPER + Q", "managed", "modified"))
        self.assertEqual(_outside_of(self.read_user()).rstrip("\n"), HAND_WRITTEN.rstrip("\n"))
        self.assertTrue(km.reset_keybinding("SUPER + SHIFT + Q")["success"])
        self.assertEqual(self.read_user(), HAND_WRITTEN)
        r = self.row("close window")
        self.assertEqual((r["key"], r["source"]), ("SUPER + Q", "user-file"))
        # a plain hand-written row cannot be reset or enabled from here
        res = km.reset_keybinding("SUPER + Q")
        self.assertFalse(res["success"])
        self.assertEqual(res["locked"]["file_line"], 13)
        res = km.enable_keybinding("Browser")
        self.assertFalse(res["success"])
        self.assertIn("hand-written", res["error"])

    def test_rollback_restores_bytes_on_configerrors(self):
        self.write_user(HAND_WRITTEN)
        original = self.read_bytes()
        km.reload_hyprland = self.saved[3]  # real function, fake hyprctl binary
        os.environ["FAKE_CONFIGERRORS"] = "config error at line 9"
        res = km.set_keybinding("SUPER + SHIFT + Z", "Custom Tool", "my-tool")
        self.assertFalse(res["success"])
        self.assertIn("rolled back", res["error"])
        self.assertTrue(res["rolled_back"])
        self.assertEqual(self.read_bytes(), original)
        with open(self.log) as f:
            log = f.read()
        self.assertEqual(log.count("hyprctl reload"), 2)


class TestMigrate(Base):
    TRAILING = ('hl.unbind("SUPER + F")\n'
                'hl.unbind("SUPER + ALT + F")\n'
                'o.bind("SUPER + ALT + F", "Full screen", hl.dsp.window.fullscreen({ mode = "fullscreen" }))\n'
                'o.bind("SUPER + F", "Full width", hl.dsp.window.fullscreen({ mode = "maximized" }))\n')

    def test_migrate_moves_trailing_lines_and_is_idempotent(self):
        self.write_user(HAND_WRITTEN + "\n" + self.TRAILING)
        self.assertEqual(km.build_complete_model()["pending_migration"], 4)
        res = km.migrate_trailing()
        self.assertTrue(res["success"], res)
        self.assertEqual(res["migrated"], 4)
        self.assertEqual(sorted(res["records"]), ["full screen", "full width"])
        content = self.read_user()
        self.assertEqual(_outside_of(content).rstrip("\n"), HAND_WRITTEN.rstrip("\n"))
        self.assertEqual(_block_lines(_block_of(content)), [
            'hl.unbind("SUPER + F")',
            'hl.unbind("SUPER + ALT + F")',
            'o.bind("SUPER + ALT + F", "Full screen", hl.dsp.window.fullscreen({ mode = "fullscreen" })) -- was SUPER + F',
            'o.bind("SUPER + F", "Full width", hl.dsp.window.fullscreen({ mode = "maximized" })) -- was SUPER + ALT + F',
        ])
        m, rows = self.rows()
        self.assertEqual(m["pending_migration"], 0)
        self.assertEqual(rows["full screen"]["key"], "SUPER + ALT + F")
        self.assertEqual(rows["full width"]["key"], "SUPER + F")
        res = km.migrate_trailing()
        self.assertTrue(res["success"])
        self.assertEqual((res["migrated"], res["changed"]), (0, False))
        self.assertEqual(self.read_user(), content)
        # a hand-written statement with a comment is not "trailing"
        self.write_user(HAND_WRITTEN + 'hl.unbind("SUPER + SHIFT + W") -- Omawrite\n')
        self.assertEqual(km.migrate_trailing()["migrated"], 0)


@unittest.skipUnless(os.path.isfile(REAL_USER_FILE), "no real ~/.config/hypr/bindings.lua to copy")
class TestRealFileCopy(Base):
    """Uses a COPY of the real user file; the original is never opened for
    writing."""

    def setUp(self):
        super().setUp()
        shutil.copyfile(REAL_USER_FILE, self.user_file)
        # the real file may already carry a managed block; "untouched" means everything outside it
        self.original = _outside_of(self.read_user())

    def _trailing_count(self, text):
        n = 0
        for line in reversed(_outside_of(text).rstrip("\n").split("\n")):
            if not line.strip():
                continue
            if re.match(r"^(hl\.unbind|o\.bind)\(.*\)\s*$", line) and "--" not in line:
                n += 1
                continue
            break
        return n

    def assert_outside_untouched(self, expected_prefix):
        content = self.read_user()
        self.assertEqual(_outside_of(content).rstrip("\n"), expected_prefix.rstrip("\n"))

    def test_hand_written_lines_never_rewritten(self):
        m = km.build_complete_model()
        self.assertGreater(m["total_active"], 20)
        self.assertGreater(len(km.parse_user_file()["binds"]), 5)
        # 1. shadow a hand-written bind
        res = km.set_keybinding("SUPER + SHIFT + Q", "Close window", "hl.dsp.window.close()")
        self.assertTrue(res["success"], res)
        self.assert_outside_untouched(self.original)
        # 2. modify + reset a stock bind, disable + enable another
        self.assertTrue(km.set_keybinding("SUPER + CTRL + ALT + L", "Lock system", "omarchy-system-lock")["success"])
        self.assert_outside_untouched(self.original)
        self.assertTrue(km.reset_keybinding("SUPER + CTRL + ALT + L")["success"])
        self.assertTrue(km.disable_keybinding("Keybindings")["success"])
        self.assertTrue(km.enable_keybinding("Keybindings")["success"])
        self.assert_outside_untouched(self.original)
        # 3. migrate the old plugin's trailing lines (if the copy has any)
        trailing = self._trailing_count(self.original)
        res = km.migrate_trailing()
        self.assertTrue(res["success"], res)
        self.assertEqual(res["migrated"], trailing)
        lines = self.original.rstrip("\n").split("\n")
        kept = lines[:len(lines) - trailing] if trailing else lines
        expected = "\n".join(kept)
        self.assert_outside_untouched(expected)
        self.assertEqual(km.migrate_trailing()["migrated"], 0)
        self.assert_outside_untouched(expected)
        # 4. removing the last record removes the block; the rest is untouched
        self.assertTrue(km.reset_keybinding("SUPER + SHIFT + Q")["success"])
        self.assert_outside_untouched(expected)
        m = km.build_complete_model()
        self.assertEqual(m["pending_migration"], 0)
        for r in m["active"]:
            self.assertIn(r["status"], ("default", "modified", "custom", "disabled"))
            self.assertIn(r["source"], ("default", "managed", "user-file"))
            if r["source"] == "user-file":
                self.assertIsInstance(r["file_line"], int)
                self.assertFalse(r["managed"])


class TestCLI(Base):
    def _run(self, *args):
        env = dict(os.environ)
        p = subprocess.run([sys.executable, os.path.join(BACKEND_DIR, "keybinds_manager.py"), *args],
                           capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)

    def test_cli_contract(self):
        self.write_user("")
        m = self._run("list")
        self.assertIn("active", m)
        self.assertTrue(any(r["id"] == "close window" for r in m["active"]))
        chk = self._run("check", "SUPER + W", "My close", "--cmd", "mycmd")
        self.assertEqual(chk["conflict"]["id"], "close window")
        self.assertEqual(self.read_user(), "")
        res = self._run("set", "SUPER + W", "My close", "mycmd")
        self.assertFalse(res["success"])
        self.assertEqual(res["conflict"]["id"], "close window")
        res = self._run("set", "SUPER + W", "My close", "mycmd", "", "", "--displace")
        self.assertTrue(res["success"], res)
        self.assertEqual(res["displaced"]["id"], "close window")
        self.assertTrue(self._run("disable", "SUPER + W")["success"])
        self.assertTrue(self._run("enable", "x", "--id", "my close")["success"])
        self.assertTrue(self._run("reset", "SUPER + W", "")["success"])
        self.assertTrue(self._run("enable", "Close window")["success"])
        self.assertEqual(self.read_user(), "")
        self.assertEqual(self._run("migrate")["migrated"], 0)
        with open(self.log) as f:
            log = f.read()
        self.assertIn("hyprctl reload", log)


if __name__ == "__main__":
    unittest.main()
