#!/usr/bin/env python3
"""
Omarchy Mouse Settings Backend Controller (mouse_ctl.py)
Hardened security implementation:
- Atomic file writes via temp-files + fsync + os.replace
- Symlink clobbering protection (refuses to follow symlinks)
- File locking via fcntl.flock to prevent race conditions
- Strict input validation & range clamping (finite numbers, allowlisted enums)
- Selective persistence & conditional hyprctl reload
"""

import argparse
import errno
import fcntl
import json
import math
import os
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

MAX_SUBPROCESS_TIMEOUT = 15
MAX_SUBPROCESS_OUTPUT = 1_048_576  # hard aggregate ceiling across stdout+stderr, enforced while streaming
MAX_JSON_INPUT_BYTES = 1_048_576
MAX_CONFIG_READ_BYTES = 1_048_576

INPUT_LUA_PATH = Path.home() / ".config" / "hypr" / "input.lua"
BINDINGS_LUA_PATH = Path.home() / ".config" / "hypr" / "bindings.lua"
LOCK_PATH = Path.home() / ".config" / "hypr" / ".mouse_ctl.lock"
PLUGIN_SETTINGS_PATH = Path.home() / ".local" / "state" / "omarchy" / "settings" / "davedes.mouse-keybind-settings.json"

START_MARKER = "-- [[ OMARCHY_MOUSE_SETTINGS_START ]]"
END_MARKER = "-- [[ OMARCHY_MOUSE_SETTINGS_END ]]"

BINDINGS_START_MARKER = "-- [[ OMARCHY_MOUSE_BINDINGS_START ]]"
BINDINGS_END_MARKER = "-- [[ OMARCHY_MOUSE_BINDINGS_END ]]"

DEFAULT_BUTTON_MAPPINGS = {
    "side_back": "default",
    "side_forward": "default",
    "middle_click": "default",
    "super_left": "move_window",
    "super_right": "resize_window",
    "super_wheel": "workspace_scroll"
}

ALLOWED_BUTTON_ACTIONS = {
    "side_back": {"default", "prev_workspace", "menu", "prev_window"},
    "side_forward": {"default", "next_workspace", "terminal", "next_window"},
    "middle_click": {"default", "close_window", "toggle_floating", "toggle_fullscreen"},
    "super_left": {"move_window", "disabled"},
    "super_right": {"resize_window", "disabled"},
    "super_wheel": {"workspace_scroll", "disabled"}
}

SIMULATE_BUTTON_CODES = {
    "left": "0xC0",
    "right": "0xC1",
    "middle": "0xC2",
    "side_back": "0xC3",
    "side_forward": "0xC4"
}

def _walk_parent_fd(path: Path) -> int:
    """Return a dirfd to path.parent using component-wise descriptor-relative
    traversal: every component is opened with openat(..., O_DIRECTORY|O_NOFOLLOW)
    relative to the previously retained dirfd, walking from '/'. No pathname is
    ever followed, so a symlink substitution at any ancestor is rejected."""
    if not path.is_absolute():
        raise ValueError(f"expected absolute path: {path}")
    parent = path.parent
    parent_parts = parent.parts[1:]  # drop the leading root component
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for comp in parent_parts:
            try:
                nfd = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError as e:
                raise ValueError(f"cannot traverse config component: {comp} ({e})") from e
            os.close(fd)
            fd = nfd
            st = os.fstat(fd)
            if not stat.S_ISDIR(st.st_mode):
                raise ValueError(f"refusing non-directory config component: {comp}")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _open_leaf(path: Path, flags: int, mode=None, *, owner_check=True):
    """Open path's leaf relative to its verified parent dirfd, no-follow, and
    enforce regular-file + (optionally) user-ownership on the result.
    Returns (fd, stat). Raises on any unsafe condition; FileNotFoundError is
    propagated unchanged when the leaf is genuinely absent."""
    parent_fd = _walk_parent_fd(path)
    try:
        try:
            if mode is not None:
                fd = os.open(path.name, flags, mode, dir_fd=parent_fd)
            else:
                fd = os.open(path.name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            raise
        except IsADirectoryError:
            raise ValueError(f"refusing directory where file expected: {path}")
        except OSError as e:
            raise ValueError(f"refusing unsafe path: {path} ({e})") from e
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                raise ValueError(f"refusing non-regular file: {path}")
            if owner_check and st.st_uid != os.geteuid():
                raise ValueError(f"refusing file not owned by user: {path}")
            return fd, st
        except BaseException:
            os.close(fd)
            raise
    finally:
        os.close(parent_fd)


def safe_read_file(path: Path, max_bytes: int = MAX_CONFIG_READ_BYTES) -> str:
    """Read a config file with size, regular-file, owner, no-follow and
    descriptor-relative-parent checks. Raises FileNotFoundError when genuinely
    absent and ValueError/UnicodeDecodeError on unsafe/oversized/undecodable
    content (fail closed, never returning a mangled or empty result)."""
    fd, st = _open_leaf(path, os.O_RDONLY | os.O_NOFOLLOW, owner_check=True)
    try:
        if st.st_size > max_bytes:
            raise ValueError(f"refusing oversized config file: {path} ({st.st_size} bytes)")
        raw = os.read(fd, max_bytes + 1)
        if len(raw) > max_bytes:
            raise ValueError(f"refusing oversized config file: {path}")
        return raw.decode("utf-8")
    finally:
        os.close(fd)


def _snapshot_file(path: Path):
    """Return (raw_bytes, mode) of the file via descriptor-relative no-follow
    read, or None if the file is genuinely absent. Raises (fails closed) on any
    unsafe/read/overflow condition."""
    try:
        fd, st = _open_leaf(path, os.O_RDONLY | os.O_NOFOLLOW, owner_check=False)
    except FileNotFoundError:
        return None
    try:
        if st.st_size > MAX_CONFIG_READ_BYTES:
            raise ValueError(f"refusing oversized config file for rollback: {path}")
        raw = os.read(fd, max(st.st_size, 0))
        return raw, stat.S_IMODE(st.st_mode)
    finally:
        os.close(fd)


def _restore_file(path: Path, prior) -> None:
    """Atomically restore a file previously captured by _snapshot_file. A prior
    value of None means the file did not previously exist and is removed.
    Restores exact bytes and mode via descriptor-relative rename."""
    parent_fd = _walk_parent_fd(path)
    try:
        if prior is None:
            try:
                os.unlink(path.name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
            return
        raw, mode = prior
        tmp_name = f".{path.name}.{os.getpid()}.{os.urandom(4).hex}.tmp"
        tmp_fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode, dir_fd=parent_fd)
        try:
            wrote = 0
            while wrote < len(raw):
                wrote += os.write(tmp_fd, raw[wrote:])
            os.fsync(tmp_fd)
            os.close(tmp_fd)
            tmp_fd = -1
            os.replace(tmp_name, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        except BaseException:
            try:
                if tmp_fd != -1:
                    os.close(tmp_fd)
            except OSError:
                pass
            try:
                os.unlink(tmp_name, dir_fd=parent_fd)
            except OSError:
                pass
            raise
    finally:
        os.close(parent_fd)


def _lock_fd(fd: int):
    """Acquire an exclusive advisory lock on the given file descriptor."""
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError as e:
        raise RuntimeError(f"failed to acquire config lock: {e}") from e


def _unlock_fd(fd: int):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError as e:
        raise RuntimeError(f"failed to release config lock: {e}") from e


@contextmanager
def file_lock():
    """Acquires an exclusive lock across read-modify-write operations to prevent
    races. Fail-closed: any lock or path error aborts the operation."""
    lock_dir_fd = _walk_parent_fd(LOCK_PATH)
    try:
        lock_fd = os.open(LOCK_PATH.name, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=lock_dir_fd)
    except OSError as e:
        os.close(lock_dir_fd)
        raise RuntimeError(f"cannot open lock file safely: {LOCK_PATH} ({e})") from e
    try:
        lock_stat = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != os.geteuid():
            raise RuntimeError(f"lock file is not a user-regular file: {LOCK_PATH}")
        _lock_fd(lock_fd)
    except Exception:
        os.close(lock_fd)
        os.close(lock_dir_fd)
        raise
    try:
        yield
    finally:
        try:
            _unlock_fd(lock_fd)
        finally:
            os.close(lock_fd)
            os.close(lock_dir_fd)


def safe_atomic_write(target_path: Path, content: str, mode: int = None) -> bool:
    """Atomically replace target_path with content via descriptor-relative
    temp-file + fsync + rename-by-dirfd, preserving the existing file mode (or
    using `mode` / a safe default when the file is absent). No check-then-unlink
    window exists for the final component. Raises (fails closed) on failure and
    returns True on success."""
    data = content.encode("utf-8")
    parent_fd = _walk_parent_fd(target_path)
    try:
        target_mode = mode
        try:
            efd = os.open(target_path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
            try:
                target_mode = stat.S_IMODE(os.fstat(efd).st_mode)
            finally:
                os.close(efd)
        except FileNotFoundError:
            pass
        if target_mode is None:
            target_mode = 0o600
        tmp_name = f".{target_path.name}.{os.getpid()}.{os.urandom(4).hex}.tmp"
        tmp_fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, target_mode, dir_fd=parent_fd)
        try:
            wrote = 0
            while wrote < len(data):
                wrote += os.write(tmp_fd, data[wrote:])
            os.fsync(tmp_fd)
            os.close(tmp_fd)
            tmp_fd = -1
            os.replace(tmp_name, target_path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            return True
        except BaseException:
            try:
                if tmp_fd != -1:
                    os.close(tmp_fd)
            except OSError:
                pass
            try:
                os.unlink(tmp_name, dir_fd=parent_fd)
            except OSError:
                pass
            raise
    finally:
        os.close(parent_fd)


def run_cmd(cmd) -> tuple:
    """Run a command with:
      - a hard wall-clock timeout,
      - a hard aggregate stdout+stderr byte ceiling that is enforced *while
        streaming* (not after the process exits), and
      - whole-process-group cleanup (SIGTERM -> SIGKILL + reap) on both
        overflow and timeout, so no child survives.
    Returns (returncode, bounded_stdout, bounded_stderr)."""
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    out = bytearray()
    err = bytearray()
    total = 0
    overflow = False
    timed_out = False
    deadline = time.monotonic() + MAX_SUBPROCESS_TIMEOUT
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            fds = [fd for fd in (proc.stdout, proc.stderr) if fd is not None and not fd.closed]
            if not fds:
                break
            rlist, _, _ = select.select(fds, [], [], min(remaining, 0.2))
            for fd in rlist:
                data = os.read(fd.fileno(), 8192)
                if not data:
                    fd.close()
                    continue
                if total + len(data) > MAX_SUBPROCESS_OUTPUT:
                    overflow = True
                    continue
                total += len(data)
                if fd is proc.stdout:
                    out += data
                else:
                    err += data
            if overflow:
                break
        if timed_out or overflow:
            _kill_and_reap(proc)
            if timed_out:
                return 1, _decode(out), "command timed out"
            return 1, _decode(out), "command output limit exceeded"
        code = proc.wait()
        return code, _decode(out), _decode(err)
    except Exception as exc:
        _kill_and_reap(proc)
        return 1, _decode(out), str(exc)


def _kill_and_reap(proc):
    """Terminate the whole process group (not just the leader), escalate to
    SIGKILL, and reap so no child process survives."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        proc.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            proc.wait()
        except Exception:
            pass


def _decode(data: bytearray) -> str:
    return bytes(data).decode("utf-8", errors="replace").strip()

def validate_float(val, default: float, min_val: float, max_val: float) -> float:
    try:
        v = float(val)
        if not math.isfinite(v):
            return default
        return max(min_val, min(max_val, round(v, 2)))
    except (TypeError, ValueError, OverflowError):
        return default

def validate_int(val, default: int, min_val: int, max_val: int) -> int:
    try:
        v = int(val)
        return max(min_val, min(max_val, v))
    except (TypeError, ValueError, OverflowError):
        return default

def validate_bool(val, default: bool) -> bool:
    if isinstance(val, bool):
        return val
    if isinstance(val, str):
        return val.lower() in ("true", "1", "yes")
    if isinstance(val, (int, float)):
        return bool(val)
    return default

def validate_accel_profile(val: str, default: str = "adaptive") -> str:
    if str(val) in ("flat", "adaptive", "custom"):
        return str(val)
    return default

def validate_button_mapping(button: str, action: str) -> str:
    default = DEFAULT_BUTTON_MAPPINGS.get(button, "default")
    allowed = ALLOWED_BUTTON_ACTIONS.get(button, set())
    if str(action) in allowed:
        return str(action)
    return default

def read_plugin_settings() -> dict:
    """Read the plugin's shared settings JSON (state dir). Fail-closed to an
    empty dict on any read/parse problem; never raises."""
    try:
        content = safe_read_file(PLUGIN_SETTINGS_PATH)
    except (FileNotFoundError, ValueError, UnicodeDecodeError, OSError):
        return {}
    try:
        data = json.loads(content)
    except (ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}

def apply_to_trackpad_enabled() -> bool:
    """Whether mouse changes should also be applied to the touchpad.
    Defaults to True; falls back to the plugin settings JSON's
    `apply_to_trackpad` key when present."""
    return validate_bool(read_plugin_settings().get("apply_to_trackpad"), True)

def set_plugin_setting(key: str, value) -> bool:
    """Merge key/value into the plugin settings JSON (read-modify-write),
    preserving unowned keys. Returns True on success; never raises."""
    settings = read_plugin_settings()
    settings[key] = value
    try:
        PLUGIN_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    try:
        content = json.dumps(settings, indent=2) + "\n"
        safe_atomic_write(PLUGIN_SETTINGS_PATH, content, 0o600)
    except (ValueError, OSError):
        return False
    return True

def get_hypr_option(opt_name):
    code, out, _ = run_cmd(["hyprctl", "getoption", opt_name, "-j"])
    if code != 0 or not out:
        return None
    try:
        data = json.loads(out)
        if "float" in data:
            return data["float"]
        if "int" in data:
            return data["int"]
        if "bool" in data:
            return data["bool"]
        if "str" in data:
            val = data["str"]
            if val == "[[EMPTY]]":
                return ""
            return val
        return None
    except Exception:
        return None

def get_devices():
    code, out, _ = run_cmd(["hyprctl", "devices", "-j"])
    if code != 0 or not out:
        return []
    try:
        data = json.loads(out)
        mice = data.get("mice", [])
        clean_mice = []
        for m in mice:
            name = str(m.get("name", "Unknown Mouse"))
            clean_mice.append({
                "name": name,
                "address": str(m.get("address", "")),
                "defaultSpeed": validate_float(m.get("defaultSpeed"), 0.0, -1.0, 1.0),
                "scrollFactor": validate_float(m.get("scrollFactor"), 1.0, 0.1, 10.0)
            })
        def _mouse_rank(name_l):
            if "mouse" in name_l:
                return 0
            if "keyboard" in name_l or "consumer" in name_l or "virtual" in name_l:
                return 2
            return 1
        clean_mice.sort(key=lambda d: _mouse_rank(d["name"].lower()))
        return clean_mice
    except Exception:
        return []

def get_battery(primary_name=""):
    code, out, _ = run_cmd(["upower", "-e"])
    if code != 0 or not out:
        return None
    dev_tokens = set(re.findall(r"[a-z0-9]+", primary_name.lower()))
    dev_tokens.discard("mouse")
    for hid_path in [ln.strip() for ln in out.splitlines() if "battery_hid" in ln]:
        code, info, _ = run_cmd(["upower", "-i", hid_path])
        if code != 0 or not info:
            continue
        pct_match = re.search(r"percentage:\s*([0-9]*\.?[0-9]+)%", info)
        if not pct_match:
            continue
        state_match = re.search(r"state:\s*(\S+)", info)
        model_match = re.search(r"model:\s*(.+)", info)
        model = model_match.group(1).strip() if model_match else ""
        model_tokens = set(re.findall(r"[a-z0-9]+", model.lower()))
        if dev_tokens and (dev_tokens & model_tokens):
            return {
                "percent": validate_float(pct_match.group(1), 0.0, 0.0, 100.0),
                "state": state_match.group(1) if state_match else "unknown",
                "model": model
            }
    return None


def read_saved_input_settings():
    settings = {}
    try:
        content = safe_read_file(INPUT_LUA_PATH)
    except FileNotFoundError:
        return settings
    if START_MARKER in content and END_MARKER in content:
        block = content.split(START_MARKER)[1].split(END_MARKER)[0]
        sens_match = re.search(r"sensitivity\s*=\s*([-+]?[0-9]*\.?[0-9]+)", block)
        if sens_match:
            settings["sensitivity"] = validate_float(sens_match.group(1), 0.0, -1.0, 1.0)
        accel_match = re.search(r'accel_profile\s*=\s*"([^"]+)"', block)
        if accel_match:
            settings["accel_profile"] = validate_accel_profile(accel_match.group(1))
        follow_match = re.search(r"follow_mouse\s*=\s*([0-9]+)", block)
        if follow_match:
            settings["follow_mouse"] = validate_int(follow_match.group(1), 1, 0, 3)
        natural_match = re.search(r"natural_scroll\s*=\s*(true|false)", block)
        if natural_match:
            settings["natural_scroll"] = (natural_match.group(1) == "true")
        left_match = re.search(r"left_handed\s*=\s*(true|false)", block)
        if left_match:
            settings["left_handed"] = (left_match.group(1) == "true")
        scroll_match = re.search(r"scroll_factor\s*=\s*([-+]?[0-9]*\.?[0-9]+)", block)
        if scroll_match:
            settings["scroll_factor"] = validate_float(scroll_match.group(1), 1.0, 0.1, 8.0)
        refocus_match = re.search(r"mouse_refocus\s*=\s*(true|false)", block)
        if refocus_match:
            settings["mouse_refocus"] = (refocus_match.group(1) == "true")
    return settings

def read_saved_button_mappings():
    mappings = dict(DEFAULT_BUTTON_MAPPINGS)
    try:
        content = safe_read_file(BINDINGS_LUA_PATH)
    except FileNotFoundError:
        return mappings
    if BINDINGS_START_MARKER in content and BINDINGS_END_MARKER in content:
        block = content.split(BINDINGS_START_MARKER)[1].split(BINDINGS_END_MARKER)[0]
        if 'o.bind("mouse:275", "Previous workspace"' in block:
            mappings["side_back"] = "prev_workspace"
        elif 'o.bind("mouse:275", "Omarchy menu"' in block:
            mappings["side_back"] = "menu"
        elif 'o.bind("mouse:275", "Previous window"' in block:
            mappings["side_back"] = "prev_window"

        if 'o.bind("mouse:276", "Next workspace"' in block:
            mappings["side_forward"] = "next_workspace"
        elif 'o.bind("mouse:276", "Terminal"' in block:
            mappings["side_forward"] = "terminal"
        elif 'o.bind("mouse:276", "Next window"' in block:
            mappings["side_forward"] = "next_window"

        if 'o.bind("mouse:274", "Close active window"' in block:
            mappings["middle_click"] = "close_window"
        elif 'o.bind("mouse:274", "Toggle floating"' in block:
            mappings["middle_click"] = "toggle_floating"
        elif 'o.bind("mouse:274", "Toggle fullscreen"' in block:
            mappings["middle_click"] = "toggle_fullscreen"

        if 'hl.unbind("SUPER + mouse:272")' in block:
            mappings["super_left"] = "disabled"
        if 'hl.unbind("SUPER + mouse:273")' in block:
            mappings["super_right"] = "disabled"
        if 'hl.unbind("SUPER + mouse_down")' in block:
            mappings["super_wheel"] = "disabled"
    return mappings

def get_current_status():
    saved_input = read_saved_input_settings()
    sensitivity = saved_input.get("sensitivity", get_hypr_option("input:sensitivity"))
    sensitivity = validate_float(sensitivity, 0.0, -1.0, 1.0)
    accel_profile = saved_input.get("accel_profile", get_hypr_option("input:accel_profile"))
    accel_profile = validate_accel_profile(accel_profile, "adaptive")
    follow_mouse = saved_input.get("follow_mouse", get_hypr_option("input:follow_mouse"))
    follow_mouse = validate_int(follow_mouse, 1, 0, 3)
    natural_scroll = saved_input.get("natural_scroll", get_hypr_option("input:natural_scroll"))
    natural_scroll = validate_bool(natural_scroll, False)
    left_handed = saved_input.get("left_handed", get_hypr_option("input:left_handed"))
    left_handed = validate_bool(left_handed, False)
    scroll_factor = saved_input.get("scroll_factor", get_hypr_option("input:scroll_factor"))
    scroll_factor = validate_float(scroll_factor, 1.0, 0.1, 8.0)
    mouse_refocus = saved_input.get("mouse_refocus", get_hypr_option("input:mouse_refocus"))
    mouse_refocus = validate_bool(mouse_refocus, True)
    devices = get_devices()
    button_mappings = read_saved_button_mappings()
    return {
        "devices": devices,
        "primaryDevice": devices[0]["name"] if devices else "Standard Mouse",
        "battery": get_battery(devices[0]["name"] if devices else ""),
        "apply_to_trackpad": apply_to_trackpad_enabled(),
        "sensitivity": sensitivity,
        "accel_profile": accel_profile,
        "is_flat": (accel_profile == "flat"),
        "follow_mouse": follow_mouse,
        "natural_scroll": natural_scroll,
        "left_handed": left_handed,
        "scroll_factor": scroll_factor,
        "mouse_refocus": mouse_refocus,
        "button_mappings": button_mappings
    }

def apply_hypr_eval(settings) -> bool:
    sensitivity = validate_float(settings.get("sensitivity"), 0.0, -1.0, 1.0)
    accel = validate_accel_profile(settings.get("accel_profile", "adaptive"))
    accel_lua = f'"{accel}"' if accel in ("flat", "adaptive", "custom") else '""'
    follow_mouse = validate_int(settings.get("follow_mouse"), 1, 0, 3)
    natural_scroll = "true" if validate_bool(settings.get("natural_scroll"), False) else "false"
    left_handed = "true" if validate_bool(settings.get("left_handed"), False) else "false"
    scroll_factor = validate_float(settings.get("scroll_factor"), 1.0, 0.1, 8.0)
    mouse_refocus = "true" if validate_bool(settings.get("mouse_refocus"), True) else "false"
    apply_to_trackpad = validate_bool(settings.get("apply_to_trackpad"), apply_to_trackpad_enabled())
    pieces = [
        f"sensitivity = {sensitivity:.2f}",
        f"accel_profile = {accel_lua}",
        f"follow_mouse = {follow_mouse}",
        f"natural_scroll = {natural_scroll}",
        f"left_handed = {left_handed}",
        f"scroll_factor = {scroll_factor:.2f}",
        f"mouse_refocus = {mouse_refocus}",
    ]
    if apply_to_trackpad:
        pieces.append(f"touchpad = {{ natural_scroll = {natural_scroll}, scroll_factor = {scroll_factor:.2f} }}")
    lua_cmd = f"hl.config({{ input = {{ " + ", ".join(pieces) + " } })"
    code, out, err = run_cmd(["hyprctl", "eval", lua_cmd])
    return code == 0

def persist_to_input_lua(settings) -> bool:
    try:
        original_content = safe_read_file(INPUT_LUA_PATH)
    except FileNotFoundError:
        original_content = "-- User input overrides\n"
    sensitivity = validate_float(settings.get("sensitivity"), 0.0, -1.0, 1.0)
    accel = validate_accel_profile(settings.get("accel_profile", "adaptive"))
    accel_lua = f'"{accel}"' if accel in ("flat", "adaptive", "custom") else '""'
    follow_mouse = validate_int(settings.get("follow_mouse"), 1, 0, 3)
    natural_scroll = "true" if validate_bool(settings.get("natural_scroll"), False) else "false"
    left_handed = "true" if validate_bool(settings.get("left_handed"), False) else "false"
    scroll_factor = validate_float(settings.get("scroll_factor"), 1.0, 0.1, 8.0)
    mouse_refocus = "true" if validate_bool(settings.get("mouse_refocus"), True) else "false"
    apply_to_trackpad = validate_bool(settings.get("apply_to_trackpad"), apply_to_trackpad_enabled())
    touchpad_lines = ""
    if apply_to_trackpad:
        touchpad_lines = (
            f"    touchpad = {{\n"
            f"      natural_scroll = {natural_scroll},\n"
            f"      scroll_factor = {scroll_factor:.2f},\n"
            f"    }},\n"
        )
    new_block = (
        f"{START_MARKER}\n"
        f"hl.config({{\n"
        f"  input = {{\n"
        f"    sensitivity = {sensitivity:.2f},\n"
        f"    accel_profile = {accel_lua},\n"
        f"    follow_mouse = {follow_mouse},\n"
        f"    natural_scroll = {natural_scroll},\n"
        f"    left_handed = {left_handed},\n"
        f"    scroll_factor = {scroll_factor:.2f},\n"
        f"    mouse_refocus = {mouse_refocus},\n"
        f"{touchpad_lines}"
        f"  }},\n"
        f"}})\n"
        f"{END_MARKER}"
    )
    if START_MARKER in original_content and END_MARKER in original_content:
        pattern = re.compile(re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL)
        updated_content = pattern.sub(new_block, original_content)
    else:
        updated_content = original_content.rstrip() + "\n\n" + new_block + "\n"
    if updated_content == original_content:
        return False
    safe_atomic_write(INPUT_LUA_PATH, updated_content)
    return True

def persist_to_bindings_lua(mappings) -> bool:
    try:
        original_content = safe_read_file(BINDINGS_LUA_PATH)
    except FileNotFoundError:
        original_content = "-- User keybinding overrides\n"
    lines = []
    lines.append(BINDINGS_START_MARKER)
    sb = validate_button_mapping("side_back", mappings.get("side_back", "default"))
    if sb == "prev_workspace":
        lines.append('hl.unbind("mouse:275")')
        lines.append('o.bind("mouse:275", "Previous workspace", hl.dsp.focus({ workspace = "e-1" }), { mouse = true })')
    elif sb == "menu":
        lines.append('hl.unbind("mouse:275")')
        lines.append('o.bind("mouse:275", "Omarchy menu", "omarchy-menu toggle root", { mouse = true })')
    elif sb == "prev_window":
        lines.append('hl.unbind("mouse:275")')
        lines.append('o.bind("mouse:275", "Previous window", hl.dsp.focus({ direction = "l" }), { mouse = true })')
    sf = validate_button_mapping("side_forward", mappings.get("side_forward", "default"))
    if sf == "next_workspace":
        lines.append('hl.unbind("mouse:276")')
        lines.append('o.bind("mouse:276", "Next workspace", hl.dsp.focus({ workspace = "e+1" }), { mouse = true })')
    elif sf == "terminal":
        lines.append('hl.unbind("mouse:276")')
        lines.append('o.bind("mouse:276", "Terminal", { launch = "ghostty" }, { mouse = true })')
    elif sf == "next_window":
        lines.append('hl.unbind("mouse:276")')
        lines.append('o.bind("mouse:276", "Next window", hl.dsp.focus({ direction = "r" }), { mouse = true })')
    mc = validate_button_mapping("middle_click", mappings.get("middle_click", "default"))
    if mc == "close_window":
        lines.append('hl.unbind("mouse:274")')
        lines.append('o.bind("mouse:274", "Close active window", hl.dsp.window.kill(), { mouse = true })')
    elif mc == "toggle_floating":
        lines.append('hl.unbind("mouse:274")')
        lines.append('o.bind("mouse:274", "Toggle floating", hl.dsp.window.toggle_floating(), { mouse = true })')
    elif mc == "toggle_fullscreen":
        lines.append('hl.unbind("mouse:274")')
        lines.append('o.bind("mouse:274", "Toggle fullscreen", hl.dsp.window.fullscreen(), { mouse = true })')
    sl = validate_button_mapping("super_left", mappings.get("super_left", "move_window"))
    if sl == "disabled":
        lines.append('hl.unbind("SUPER + mouse:272")')
    sr = validate_button_mapping("super_right", mappings.get("super_right", "resize_window"))
    if sr == "disabled":
        lines.append('hl.unbind("SUPER + mouse:273")')
    sw = validate_button_mapping("super_wheel", mappings.get("super_wheel", "workspace_scroll"))
    if sw == "disabled":
        lines.append('hl.unbind("SUPER + mouse_down")')
        lines.append('hl.unbind("SUPER + mouse_up")')
    lines.append(BINDINGS_END_MARKER)
    new_block = "\n".join(lines)
    if BINDINGS_START_MARKER in original_content and BINDINGS_END_MARKER in original_content:
        pattern = re.compile(re.escape(BINDINGS_START_MARKER) + r".*?" + re.escape(BINDINGS_END_MARKER), re.DOTALL)
        updated_content = pattern.sub(new_block, original_content)
    else:
        updated_content = original_content.rstrip() + "\n\n" + new_block + "\n"
    if updated_content == original_content:
        return False
    safe_atomic_write(BINDINGS_LUA_PATH, updated_content)
    return True

def notify_user(title, message, icon="input-mouse"):
    run_cmd(["notify-send", "-a", "Omarchy", "-i", icon, str(title), str(message)])

def _reload_and_verify():
    """Reload Hyprland and report (ok, error). ok is False if reload failed or
    Hyprland reports config errors (a proxy for config-validation failure)."""
    run_cmd(["hyprctl", "reload"])
    code, err_out, _ = run_cmd(["hyprctl", "configerrors"])
    err = (err_out or "").strip()
    return (code == 0 and not err), err


def _commit_changes(paths, write_fn):
    """Snapshot the given config files, run write_fn(), reload + verify, and on
    failure atomically roll back every snapshot (restoring exact bytes + mode)
    and reload again. Returns (ok, error). The error is truthful about
    rollback: if any snapshot fails to restore, that is reported as a rollback
    FAILURE, never as a success."""
    prior = {p: _snapshot_file(p) for p in paths}
    write_fn()
    ok, err = _reload_and_verify()
    if ok:
        return True, err
    rollback_errors = []
    for p, snap in prior.items():
        try:
            _restore_file(p, snap)
        except Exception as exc:  # noqa: BLE001 - surfaced, never swallowed
            rollback_errors.append(f"{p}: {exc}")
    _reload_and_verify()
    base = err or "config validation failed"
    if rollback_errors:
        return False, base + "; rollback FAILED: " + "; ".join(rollback_errors)
    return False, base + "; changes rolled back"

def main():
    parser = argparse.ArgumentParser(description="Omarchy Mouse Control Helper")
    subparsers = parser.add_subparsers(dest="command")
    subparsers.add_parser("status", help="Get JSON status of mouse settings")
    apply_parser = subparsers.add_parser("apply", help="Apply and persist settings")
    apply_parser.add_argument("--json-data", type=str, help="JSON string with settings")
    subparsers.add_parser("toggle-accel", help="Toggle precision (flat) vs desktop (adaptive) acceleration")
    subparsers.add_parser("toggle-natural-scroll", help="Toggle natural scroll direction")
    subparsers.add_parser("reset-defaults", help="Reset mouse settings to default")
    simulate_parser = subparsers.add_parser("simulate-button", help="Emit a synthetic mouse button press via ydotool")
    simulate_parser.add_argument("--button", type=str, required=True, choices=sorted(SIMULATE_BUTTON_CODES.keys()))
    args = parser.parse_args()

    if args.command == "status" or not args.command:
        state = get_current_status()
        print(json.dumps(state, indent=2))
        return

    if args.command == "simulate-button":
        code = SIMULATE_BUTTON_CODES[args.button]
        if shutil.which("ydotool") is None:
            print(json.dumps({"success": False, "error": "ydotool not installed"}))
            return
        ret, out, err_out = run_cmd(["ydotool", "click", "-D", "50", code])
        if ret == 0:
            print(json.dumps({"success": True, "button": args.button}))
        else:
            err_l = (err_out + "\n" + out).lower()
            if "socket" in err_l or "connect" in err_l or "ydotoold" in err_l or "failed to open" in err_l:
                print(json.dumps({"success": False, "error": "ydotoold unavailable"}))
            else:
                print(json.dumps({"success": False, "error": err_out.strip() or f"ydotool exited {ret}"}))
        return

    with file_lock():
        if args.command == "toggle-accel":
            current = get_current_status()
            new_profile = "adaptive" if current["accel_profile"] == "flat" else "flat"
            current["accel_profile"] = new_profile
            current["is_flat"] = (new_profile == "flat")
            apply_hypr_eval(current)
            ok, err = _commit_changes([INPUT_LUA_PATH], lambda: persist_to_input_lua(current))
            label = "Precision (Raw 1:1)" if new_profile == "flat" else "Desktop (Dynamic)"
            if not ok:
                print(json.dumps({"success": False, "error": err}))
                return
            notify_user("Mouse Acceleration", f"Switched to {label}")
            print(json.dumps({"success": True, "accel_profile": new_profile, "label": label}))
            return

        if args.command == "toggle-natural-scroll":
            current = get_current_status()
            new_val = not current["natural_scroll"]
            current["natural_scroll"] = new_val
            apply_hypr_eval(current)
            ok, err = _commit_changes([INPUT_LUA_PATH], lambda: persist_to_input_lua(current))
            label = "Natural (Mobile)" if new_val else "Traditional (Classic PC)"
            if not ok:
                print(json.dumps({"success": False, "error": err}))
                return
            notify_user("Mouse Scrolling", f"Scroll direction set to {label}")
            print(json.dumps({"success": True, "natural_scroll": new_val, "label": label}))
            return

        if args.command == "reset-defaults":
            defaults = {
                "sensitivity": 0.0,
                "accel_profile": "adaptive",
                "follow_mouse": 1,
                "natural_scroll": False,
                "left_handed": False,
                "scroll_factor": 1.0,
                "mouse_refocus": True,
            }
            apply_hypr_eval(defaults)
            ok, err = _commit_changes(
                [INPUT_LUA_PATH, BINDINGS_LUA_PATH],
                lambda: (persist_to_input_lua(defaults), persist_to_bindings_lua(DEFAULT_BUTTON_MAPPINGS)),
            )
            if not ok:
                print(json.dumps({"success": False, "error": err}))
                return
            notify_user("Mouse Settings", "Reset to Omarchy defaults")
            print(json.dumps({"success": True, "status": get_current_status()}))
            return

        if args.command == "apply":
            current = get_current_status()
            has_input_change = False
            has_bindings_change = False
            if args.json_data:
                if len(args.json_data.encode("utf-8")) > MAX_JSON_INPUT_BYTES:
                    print(json.dumps({"success": False, "error": "JSON payload too large"}))
                    return
                try:
                    payload = json.loads(args.json_data)
                    if not isinstance(payload, dict):
                        print(json.dumps({"success": False, "error": "Payload must be a JSON object"}))
                        return
                    if "sensitivity" in payload:
                        current["sensitivity"] = validate_float(payload["sensitivity"], current["sensitivity"], -1.0, 1.0)
                        has_input_change = True
                    if "accel_profile" in payload:
                        current["accel_profile"] = validate_accel_profile(payload["accel_profile"], current["accel_profile"])
                        current["is_flat"] = (current["accel_profile"] == "flat")
                        has_input_change = True
                    if "follow_mouse" in payload:
                        current["follow_mouse"] = validate_int(payload["follow_mouse"], current["follow_mouse"], 0, 3)
                        has_input_change = True
                    if "natural_scroll" in payload:
                        current["natural_scroll"] = validate_bool(payload["natural_scroll"], current["natural_scroll"])
                        has_input_change = True
                    if "left_handed" in payload:
                        current["left_handed"] = validate_bool(payload["left_handed"], current["left_handed"])
                        has_input_change = True
                    if "scroll_factor" in payload:
                        current["scroll_factor"] = validate_float(payload["scroll_factor"], current["scroll_factor"], 0.1, 8.0)
                        has_input_change = True
                    if "mouse_refocus" in payload:
                        current["mouse_refocus"] = validate_bool(payload["mouse_refocus"], current["mouse_refocus"])
                        has_input_change = True
                    if "apply_to_trackpad" in payload:
                        val = validate_bool(payload["apply_to_trackpad"], current["apply_to_trackpad"])
                        current["apply_to_trackpad"] = val
                        set_plugin_setting("apply_to_trackpad", val)
                        has_input_change = True
                    if "button_mappings" in payload and isinstance(payload["button_mappings"], dict):
                        bm = payload["button_mappings"]
                        if len(bm) > 64:
                            print(json.dumps({"success": False, "error": "button_mappings collection too large"}))
                            return
                        for btn, act in bm.items():
                            if btn in ALLOWED_BUTTON_ACTIONS and isinstance(act, str) and len(act) <= 64:
                                current["button_mappings"][btn] = validate_button_mapping(btn, act)
                        has_bindings_change = True
                except Exception as e:
                    print(json.dumps({"success": False, "error": f"Invalid JSON: {e}"}))
                    return
            eval_ok = True
            change_paths = []
            write_ops = []
            if has_input_change:
                change_paths.append(INPUT_LUA_PATH)
                write_ops.append(lambda: persist_to_input_lua(current))
                eval_ok = apply_hypr_eval(current)
            if has_bindings_change:
                change_paths.append(BINDINGS_LUA_PATH)
                write_ops.append(lambda: persist_to_bindings_lua(current.get("button_mappings", {})))
            if change_paths:
                def _write_all():
                    for op in write_ops:
                        op()
                ok, err = _commit_changes(change_paths, _write_all)
            else:
                ok, err = True, None
            if not ok:
                print(json.dumps({"success": False, "error": err}))
                return
            print(json.dumps({
                "success": eval_ok and ok,
                "error": err if err else None,
                "status": get_current_status()
            }))
            return

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as e:
        print(json.dumps({"success": False, "error": str(e)}))
        sys.exit(1)