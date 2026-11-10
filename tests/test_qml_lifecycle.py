"""Deterministic contracts for shipped QML functions and signal bodies.

Uses Node.js test doubles with the signal ordering in Quickshell commit
9b0f339b19057f4731bf3b48293307d7ef241671 src/io/process.cpp.
The parser model follows its src/io/datastream.cpp empty/newline branches.
This does not replace native Quickshell lifecycle/smoke testing.
"""
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / 'tests' / 'qml_wrapper_harness.cjs'
SCENARIOS = (
    'failed_start', 'fast_exit', 'idle_notifications', 'retry_after_failure',
    'completion_triggered_retry', 'normal_completion_triggered_retry',
    'cancel_then_failed_start', 'cancel_then_started', 'timeout_during_start',
    'failed_start_after_timeout', 'stdout_without_newline',
    'stderr_without_newline', 'aggregate_budget', 'preserve_newlines_and_chunks',
    'utf8_aggregate_budget', 'retry_resets_output_and_flags',
)


@unittest.skipUnless(shutil.which('node'), 'Node.js is required for QML contracts')
class QmlLifecycleTests(unittest.TestCase):
    pass


def scenario_test(name):
    def run(self):
        result = subprocess.run(
            ['node', str(HARNESS), str(ROOT / 'BoundedProcess.qml'), name],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    run.__name__ = 'test_' + name
    return run


for name in SCENARIOS:
    setattr(QmlLifecycleTests, 'test_' + name, scenario_test(name))


if __name__ == '__main__':
    unittest.main()
