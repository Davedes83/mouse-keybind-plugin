import ctypes
import errno
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import mouse_ctl


PYTHON = sys.executable
ROOT = Path(__file__).resolve().parents[1]
SUPERVISOR = ROOT / "session_supervisor.py"


class RunCmdTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Make this test process reap orphaned grandchildren, so a successful
        # cleanup can be asserted without relying on the container's init.
        try:
            ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
        except (AttributeError, OSError):
            pass

    def setUp(self):
        self.old_timeout = mouse_ctl.MAX_SUBPROCESS_TIMEOUT
        self.old_cap = mouse_ctl.MAX_SUBPROCESS_OUTPUT

    def tearDown(self):
        mouse_ctl.MAX_SUBPROCESS_TIMEOUT = self.old_timeout
        mouse_ctl.MAX_SUBPROCESS_OUTPUT = self.old_cap
        self._reap_available()

    def run_python(self, source):
        return mouse_ctl.run_cmd([PYTHON, "-c", source])

    @staticmethod
    def _reap_available():
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid == 0:
                return

    def assert_reaped(self, pid):
        end = time.monotonic() + 2
        while time.monotonic() < end:
            self._reap_available()
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.02)
        self.fail("descendant %s survived cleanup" % pid)

    @staticmethod
    def wait_for(path, timeout=3):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if path.exists():
                return
            time.sleep(.02)
        raise AssertionError(f"marker not created: {path}")

    def test_success_output_stderr_and_private_group_same_session(self):
        code, out, err = self.run_python(
            "import os,sys; print(f'{os.getsid(0)}:{os.getpgrp()}'); "
            "print('warning', file=sys.stderr)"
        )
        self.assertEqual(code, 0)
        session, group = map(int, out.split(':'))
        self.assertEqual(session, os.getsid(0))
        self.assertNotEqual(group, os.getpgrp())
        self.assertEqual(err, 'warning')

    def test_nonzero_exit_is_preserved(self):
        code, out, err = self.run_python("import sys; print('out'); print('bad', file=sys.stderr); sys.exit(7)")
        self.assertEqual((code, out, err), (7, 'out', 'bad'))

    def test_timeout_kills_leader_and_term_ignoring_descendant(self):
        mouse_ctl.MAX_SUBPROCESS_TIMEOUT = .12
        with tempfile.TemporaryDirectory() as td:
            pidfile = Path(td) / 'child.pid'
            source = (
                "import subprocess,sys,time; "
                "p=subprocess.Popen([sys.executable,'-c',"
                "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)']); "
                f"open({str(pidfile)!r},'w').write(str(p.pid)); time.sleep(30)"
            )
            started = time.monotonic()
            code, _, err = self.run_python(source)
            elapsed = time.monotonic() - started
            self.assertEqual(code, 1)
            self.assertEqual(err, 'command timed out')
            self.assertLess(elapsed, 1.2)
            self.assert_reaped(int(pidfile.read_text()))

    def test_closed_streams_do_not_disable_deadline(self):
        mouse_ctl.MAX_SUBPROCESS_TIMEOUT = .12
        started = time.monotonic()
        code, _, err = self.run_python("import os,time; os.close(1); os.close(2); time.sleep(30)")
        elapsed = time.monotonic() - started
        self.assertEqual((code, err), (1, 'command timed out'))
        self.assertLess(elapsed, 1.2)

    def test_aggregate_output_cap_across_stdout_and_stderr(self):
        mouse_ctl.MAX_SUBPROCESS_OUTPUT = 1000
        code, out, err = self.run_python("import sys; sys.stdout.write('a'*600); sys.stdout.flush(); sys.stderr.write('b'*600); sys.stderr.flush()")
        self.assertEqual(code, 1)
        self.assertEqual(err, 'command output limit exceeded')
        self.assertLessEqual(len(out), 1000)

    def test_repeat_timeouts_leave_no_descendants(self):
        mouse_ctl.MAX_SUBPROCESS_TIMEOUT = .08
        for _ in range(4):
            code, _, err = self.run_python("import time; time.sleep(30)")
            self.assertEqual((code, err), (1, 'command timed out'))
        self._reap_available()

    def test_cleanup_always_escalates_and_uses_bounded_reap(self):
        proc = mock.Mock(pid=43210)
        proc.wait.return_value = 0
        with mock.patch.object(mouse_ctl.os, 'killpg') as killpg, mock.patch.object(mouse_ctl.time, 'sleep') as sleep:
            mouse_ctl._kill_and_reap(proc)
        self.assertEqual(killpg.call_args_list, [
            mock.call(43210, signal.SIGTERM),
            mock.call(43210, signal.SIGKILL),
        ])
        sleep.assert_called_once_with(.3)
        proc.wait.assert_called_once_with(timeout=.5)

    def test_cleanup_surfaces_permission_error(self):
        proc = mock.Mock(pid=43210)
        with mock.patch.object(mouse_ctl.os, 'killpg', side_effect=PermissionError(errno.EPERM, 'denied')):
            with self.assertRaises(PermissionError):
                mouse_ctl._kill_and_reap(proc)

    def test_outer_supervisor_cancellation_cleans_run_cmd_group(self):
        """Exercise the real backend path while its outer supervisor cancels."""
        td = Path(tempfile.mkdtemp(prefix="run-cmd-outer-cancel-"))
        try:
            pidfile = td / "nested.pid"
            helper = (
                "import os,signal,time; "
                f"open({str(pidfile)!r}, 'w').write(str(os.getpid())); "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"
            )
            backend = (
                "import sys; "
                f"sys.path.insert(0, {str(ROOT)!r}); "
                "import mouse_ctl; "
                f"mouse_ctl.run_cmd([sys.executable, '-c', {helper!r}])"
            )
            supervisor = subprocess.Popen([
                PYTHON, str(SUPERVISOR), "--timeout-ms", "5000", "--",
                PYTHON, "-c", backend,
            ])
            self.wait_for(pidfile)
            nested_pid = int(pidfile.read_text())
            supervisor.send_signal(signal.SIGTERM)
            self.assertEqual(supervisor.wait(timeout=6), 143)
            self.assert_reaped(nested_pid)
        finally:
            shutil.rmtree(td, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
