"""Integration tests for session_supervisor using disposable Python helpers."""
import ctypes
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import session_supervisor as supervisor_module

ROOT = Path(__file__).resolve().parents[1]
SUPERVISOR = ROOT / "session_supervisor.py"


def become_subreaper():
    """Let this test runner reap helpers after deliberately killing a parent."""
    ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER


def wait_for(path, timeout=3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if path.exists():
            return
        time.sleep(.02)
    raise AssertionError(f"marker not created: {path}")


def wait_gone(pid, timeout=4):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        try:
            if Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1][0] == "Z":
                return
        except FileNotFoundError:
            return
        time.sleep(.03)
    raise AssertionError(f"owned helper still alive: {pid}")


class SessionSupervisorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        become_subreaper()

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="session-supervisor-test-"))
        self.pids = []

    def tearDown(self):
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_supervisor(self, command, timeout=1000, process_group=False, session_leader=False):
        kwargs = {"cwd": self.tmp}
        if process_group:
            kwargs["process_group"] = 0
        if session_leader:
            kwargs["start_new_session"] = True
        return subprocess.run(
            [sys.executable, str(SUPERVISOR), "--timeout-ms", str(timeout), "--", *command],
            timeout=8, **kwargs
        )

    def helper(self, marker, ignore_term=True):
        return (
            "import os,signal,time;"
            f"open({str(marker)!r},'w').write(str(os.getpid()));"
            + ("signal.signal(signal.SIGTERM, signal.SIG_IGN);" if ignore_term else "")
            + "time.sleep(30)"
        )

    def read_pid(self, marker):
        wait_for(marker)
        pid = int(marker.read_text())
        self.pids.append(pid)
        return pid

    def test_timeout_kills_multiple_helper_groups(self):
        one, two = self.tmp / "one", self.tmp / "two"
        backend = (
            "import subprocess,sys,time;"
            f"c={self.helper(one)!r}; d={self.helper(two)!r};"
            "subprocess.Popen([sys.executable,'-c',c],process_group=0);"
            "subprocess.Popen([sys.executable,'-c',d],process_group=0);time.sleep(30)"
        )
        result = self.run_supervisor([sys.executable, "-c", backend], timeout=180)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(one.exists() and two.exists())
        wait_gone(self.read_pid(one)); wait_gone(self.read_pid(two))

    def test_term_kills_child_after_backend_leader_exits(self):
        marker = self.tmp / "child"
        backend = (
            "import subprocess,sys,signal,time;"
            f"subprocess.Popen([sys.executable,'-c',{self.helper(marker)!r}],process_group=0);"
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0));time.sleep(30)"
        )
        proc = subprocess.Popen([sys.executable, str(SUPERVISOR), "--timeout-ms", "5000", "--", sys.executable, "-c", backend])
        pid = self.read_pid(marker)
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=6), 143)
        # Cooperative completion must mean cleanup has already finished, not
        # merely that the relay exited while an ignored-TERM helper is alive.
        wait_gone(pid, timeout=0.001)

    def test_normal_exit_cleans_leftover_child_and_pgl_launch(self):
        marker = self.tmp / "leftover"
        backend = (
            "import subprocess,sys,time;"
            f"subprocess.Popen([sys.executable,'-c',{self.helper(marker)!r}],process_group=0);time.sleep(.15)"
        )
        result = self.run_supervisor([sys.executable, "-c", backend], process_group=True)
        self.assertEqual(result.returncode, 0)
        wait_gone(self.read_pid(marker))

    def test_already_session_leader_launch_is_supported(self):
        result = self.run_supervisor([sys.executable, "-c", "import sys; sys.exit(7)"], session_leader=True)
        self.assertEqual(result.returncode, 7)

    def test_reap_preserves_nonzero_exit_status(self):
        result = self.run_supervisor([sys.executable, "-c", "import sys; sys.exit(7)"])
        self.assertEqual(result.returncode, 7)

    def test_reap_preserves_signal_exit_status(self):
        result = self.run_supervisor([sys.executable, "-c", "import os,signal; os.kill(os.getpid(), signal.SIGTERM)"])
        self.assertEqual(result.returncode, 143)

    def test_sigkill_of_directly_tracked_relay_cleans_backend_and_nested_helper(self):
        backend_marker, helper_marker = self.tmp / "backend", self.tmp / "nested"
        backend = (
            "import os,signal,subprocess,sys,time;"
            f"open({str(backend_marker)!r},'w').write(str(os.getpid()));"
            f"subprocess.Popen([sys.executable,'-c',{self.helper(helper_marker)!r}]);"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN);time.sleep(30)"
        )
        # No process-group/session flags: this is the process Quickshell tracks.
        relay = subprocess.Popen(
            [sys.executable, str(SUPERVISOR), "--timeout-ms", "5000", "--", sys.executable, "-c", backend],
            cwd=self.tmp,
        )
        backend_pid = self.read_pid(backend_marker)
        nested_pid = self.read_pid(helper_marker)
        relay.kill()
        self.assertEqual(relay.wait(timeout=3), -signal.SIGKILL)
        wait_gone(backend_pid)
        wait_gone(nested_pid)

    def test_parent_death_before_worker_arms_pdeathsig_is_detected_by_ppid_race_check(self):
        managed = supervisor_module.Supervisor(100, ["unused"])
        child = mock.Mock()
        child.poll.return_value = None
        with mock.patch.object(supervisor_module.os, "getppid", side_effect=[4242, 1]) as getppid, \
             mock.patch.object(supervisor_module, "_prctl"), \
             mock.patch.object(managed, "_become_session_leader"), \
             mock.patch.object(supervisor_module.subprocess, "Popen", return_value=child), \
             mock.patch.object(managed, "_cleanup", return_value=True), \
             mock.patch.object(managed, "_reap"):
            self.assertEqual(managed.run(), 143)
        self.assertEqual(getppid.call_count, 2)

    def test_parent_dies_before_worker_start_and_is_adopted_by_subreaper(self):
        managed = supervisor_module.Supervisor(100, ["unused"], expected_parent=4242)
        with mock.patch.object(supervisor_module.os, "getppid", return_value=9999),              mock.patch.object(supervisor_module, "_prctl"),              mock.patch.object(managed, "_become_session_leader"),              mock.patch.object(supervisor_module.subprocess, "Popen") as spawn:
            self.assertEqual(managed.run(), 143)
            spawn.assert_not_called()

    def test_parent_death_kills_worker_when_group_leader_relay_is_used(self):
        marker = self.tmp / "orphan"
        controller = (
            "import subprocess,sys,time;"
            f"subprocess.Popen([sys.executable,{str(SUPERVISOR)!r},'--timeout-ms','5000','--',sys.executable,'-c',{self.helper(marker)!r}],process_group=0);"
            "time.sleep(30)"
        )
        parent = subprocess.Popen([sys.executable, "-c", controller])
        pid = self.read_pid(marker)
        parent.kill(); parent.wait(timeout=3)
        wait_gone(pid)

    def test_snapshot_fails_closed_when_proc_cannot_be_listed(self):
        with mock.patch.object(supervisor_module.os, "listdir", side_effect=OSError("blocked")):
            with self.assertRaisesRegex(RuntimeError, "cannot inspect /proc"):
                supervisor_module._snapshot()

    def test_cleanup_reports_permission_failure_even_if_target_disappears(self):
        managed = supervisor_module.Supervisor(100, ["unused"])
        proc = supervisor_module.Proc(12345, 1, 12345, 1, "start")
        with mock.patch.object(managed, "_targets", side_effect=[{proc.pid: proc}, {}]), \
             mock.patch.object(managed, "_reap"), \
             mock.patch.object(supervisor_module, "_signal_checked", return_value=False):
            self.assertFalse(managed._cleanup())
        self.assertIn("permission denied", managed.cleanup_error)

    def test_missing_command_is_failure(self):
        result = subprocess.run([sys.executable, str(SUPERVISOR), "--timeout-ms", "10", "--"], timeout=4)
        self.assertEqual(result.returncode, 125)


if __name__ == "__main__":
    unittest.main()
