#!/usr/bin/env python3
"""Linux-only, stdlib session supervisor for trusted helper commands."""
import argparse
import ctypes
import errno
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Dict, Iterable, Set

PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36
TERM_GRACE_SECONDS = 0.35
KILL_BUDGET_SECONDS = 2.0
POLL_SECONDS = 0.02


@dataclass(frozen=True)
class Proc:
    pid: int
    ppid: int
    pgrp: int
    sid: int
    starttime: str


def _prctl(option: int, value: int) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(option, value, 0, 0, 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def _read_proc(pid: int) -> Proc | None:
    """Read identity fields needed to avoid signalling a reused PID."""
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as stat_file:
            text = stat_file.read()
        # comm may contain spaces and parentheses; everything after final ')' is fixed.
        rest = text[text.rfind(")") + 2:].split()
        # rest starts at field 3 (state): ppid=field4, pgrp=5, sid=6, start=22.
        return Proc(pid, int(rest[1]), int(rest[2]), int(rest[3]), rest[19])
    except (OSError, ValueError, IndexError):
        return None


def _snapshot() -> Dict[int, Proc]:
    """Return a complete process snapshot, or fail closed if /proc is unreadable."""
    try:
        names = os.listdir("/proc")
    except OSError as exc:
        raise RuntimeError("cannot inspect /proc during helper cleanup") from exc
    result = {}
    for name in names:
        if name.isdigit():
            proc = _read_proc(int(name))
            if proc is not None:
                result[proc.pid] = proc
    return result


def _descendants(snapshot: Dict[int, Proc], roots: Iterable[int]) -> Set[int]:
    """Return roots plus their current descendants from one /proc snapshot."""
    found = set(roots)
    changed = True
    while changed:
        changed = False
        for proc in snapshot.values():
            if proc.ppid in found and proc.pid not in found:
                found.add(proc.pid)
                changed = True
    return found


def _signal_checked(proc: Proc, sig: int) -> bool:
    """Signal one unchanged process; return False for an actionable failure."""
    current = _read_proc(proc.pid)
    if current is None or current.starttime != proc.starttime:
        return True
    try:
        os.kill(proc.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        return False
    return True


class Supervisor:
    def __init__(self, timeout_ms: int, command: list[str], expected_parent: int | None = None):
        self.expected_parent = expected_parent
        self.timeout = timeout_ms / 1000.0
        self.command = command
        self.stop_signal: int | None = None
        self.child: subprocess.Popen | None = None
        self.session: int | None = None
        self.cleanup_error: str | None = None

    def _on_signal(self, signo, _frame) -> None:
        if self.stop_signal is None:
            self.stop_signal = signo

    def _install_handlers(self) -> None:
        for signo in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signo, self._on_signal)

    def _become_session_leader(self) -> None:
        # A supervisor launched with start_new_session=True already has the
        # required private session.  setsid(2) would reject that SID leader.
        if os.getsid(0) == os.getpid():
            self.session = os.getpid()
            return
        # setsid fails for a process-group leader.  Callers in that state use
        # the relay in main(), so never silently supervise an ambient session.
        if os.getpid() == os.getpgrp():
            raise RuntimeError("cannot safely create a private session")
        os.setsid()
        self.session = os.getsid(0)
        if self.session != os.getpid():
            raise RuntimeError("private session creation failed")

    def _targets(self) -> Dict[int, Proc]:
        """Find private-session helpers and subreaper-adopted escapees."""
        snap = _snapshot()
        ours: Set[int] = set()
        if self.session is not None:
            ours.update(p.pid for p in snap.values() if p.sid == self.session and p.pid != os.getpid())
        # A child which calls setsid leaves the session, but child-subreaper makes
        # it (or its orphaned descendants) ours after its parent exits.
        ours.update(_descendants(snap, [os.getpid()]))
        ours.discard(os.getpid())
        return {pid: snap[pid] for pid in ours if pid in snap}

    def _reap(self) -> None:
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            except InterruptedError:
                continue
            if pid == 0:
                return
            # waitpid(-1) can reap the Popen leader before Popen.poll(). Keep
            # its real wait status so poll() cannot later synthesize success.
            if self.child is not None and pid == self.child.pid:
                self.child.returncode = os.waitstatus_to_exitcode(status)

    def _cleanup(self) -> bool:
        """Terminate every owned helper within a fixed budget.

        A False result is deliberately surfaced by run(): reporting success or
        timeout while owned helpers remain (or cannot be signalled) is unsafe.
        """
        try:
            signal_failed = False
            for proc in self._targets().values():
                signal_failed |= not _signal_checked(proc, signal.SIGTERM)
            grace_end = time.monotonic() + TERM_GRACE_SECONDS
            while time.monotonic() < grace_end:
                self._reap()
                if not self._targets():
                    if signal_failed:
                        self.cleanup_error = "permission denied while signalling helper"
                        return False
                    return True
                time.sleep(POLL_SECONDS)
            end = time.monotonic() + KILL_BUDGET_SECONDS
            while True:
                targets = self._targets()
                if not targets:
                    self._reap()
                    if signal_failed:
                        self.cleanup_error = "permission denied while signalling helper"
                        return False
                    return True
                for proc in targets.values():
                    signal_failed |= not _signal_checked(proc, signal.SIGKILL)
                self._reap()
                if time.monotonic() >= end:
                    self.cleanup_error = "owned helpers survived cleanup deadline"
                    if signal_failed:
                        self.cleanup_error += " (including permission-denied signals)"
                    return False
                time.sleep(POLL_SECONDS)
        except (OSError, RuntimeError) as exc:
            self.cleanup_error = str(exc)
            return False

    def run(self) -> int:
        self._install_handlers()
        try:
            # Handlers are installed before PDEATHSIG and its race check.
            parent = self.expected_parent if self.expected_parent is not None else os.getppid()
            _prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
            if os.getppid() != parent or parent == 1:
                self.stop_signal = signal.SIGTERM
            _prctl(PR_SET_CHILD_SUBREAPER, 1)
            self._become_session_leader()
            if self.stop_signal is not None:
                return 128 + self.stop_signal
            self.child = subprocess.Popen(self.command, process_group=0)
        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
            print(f"session supervisor: {exc}", file=sys.stderr)
            if not self._cleanup():
                print(f"session supervisor: cleanup failed: {self.cleanup_error}", file=sys.stderr)
            return 125

        deadline = time.monotonic() + self.timeout
        timed_out = False
        status = None
        try:
            while True:
                self._reap()
                status = self.child.poll()
                if self.stop_signal is not None or status is not None:
                    break
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                time.sleep(POLL_SECONDS)
        finally:
            cleanup_ok = self._cleanup()
            self._reap()

        if not cleanup_ok:
            print(f"session supervisor: cleanup failed: {self.cleanup_error}", file=sys.stderr)
            return 125
        if timed_out:
            return 124
        if self.stop_signal is not None:
            return 128 + self.stop_signal
        if status is None:
            status = self.child.poll()
        if status is None:
            return 125
        return 128 + (-status) if status < 0 else status


def parse_args(argv: list[str]) -> tuple[int, list[str]]:
    parser = argparse.ArgumentParser(description="supervise one trusted helper session")
    parser.add_argument("--timeout-ms", required=True, type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    ns = parser.parse_args(argv)
    if ns.timeout_ms < 0:
        parser.error("--timeout-ms must be non-negative")
    command = ns.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("missing command after --")
    return ns.timeout_ms, command


def _relay(timeout_ms: int, worker: int, original_parent: int) -> int:
    """Tracked relay: forward shutdown and make worker cleanup survive our death."""
    stopped = None

    def forward(signo, _frame) -> None:
        nonlocal stopped
        if stopped is None:
            stopped = signo
            try:
                os.kill(worker, signo)
            except ProcessLookupError:
                pass

    for signo in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signo, forward)
    # Capture original_parent before fork; checking it after prctl closes the
    # race where that parent died before this relay armed PDEATHSIG.
    _prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    if original_parent == 1 or os.getppid() != original_parent:
        forward(signal.SIGTERM, None)
    end = time.monotonic() + timeout_ms / 1000.0 + KILL_BUDGET_SECONDS + 1.0
    sent_term = False
    while True:
        if stopped is not None:
            # On cooperative cancellation, remain tracked until worker cleanup
            # finishes. A hard-killed relay still triggers worker PDEATHSIG.
            end = min(end, time.monotonic() + TERM_GRACE_SECONDS + KILL_BUDGET_SECONDS + 0.5)
        try:
            pid, status = os.waitpid(worker, os.WNOHANG)
        except InterruptedError:
            continue
        except OSError:
            return 125
        if pid:
            code = os.waitstatus_to_exitcode(status)
            return 128 - code if code < 0 else code
        if time.monotonic() >= end:
            return 125
        if not sent_term and time.monotonic() + KILL_BUDGET_SECONDS >= end:
            forward(signal.SIGTERM, None)
            sent_term = True
        time.sleep(POLL_SECONDS)


def main(argv: list[str] | None = None) -> int:
    try:
        timeout, command = parse_args(sys.argv[1:] if argv is None else argv)
    except SystemExit as exc:
        return 125 if exc.code else 0
    # Quickshell kills the directly tracked process in its destructor, even
    # after sending it TERM. Always make that process a tiny relay: if it is
    # SIGKILLed, the worker receives PDEATHSIG and performs bounded cleanup.
    # Forking also leaves the worker eligible to create its private session.
    original_parent = os.getppid()
    relay_pid = os.getpid()
    worker = os.fork()
    if worker:
        return _relay(timeout, worker, original_parent)
    return Supervisor(timeout, command, expected_parent=relay_pid).run()


if __name__ == "__main__":
    raise SystemExit(main())
