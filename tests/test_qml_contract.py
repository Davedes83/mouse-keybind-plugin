"""Execute the actual QML JavaScript functions, without claiming a Qt UI test.

Python >=3.11, Linux; these contract tests additionally require Node.js.
"""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

QML = Path(__file__).resolve().parents[1] / 'BoundedProcess.qml'


class QmlContractTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node.js is required for QML JS contract tests')
    def test_real_qml_functions(self):
        text = QML.read_text()
        functions = []
        for match in re.finditer(r'function\s+\w+\([^)]*\)\s*\{', text):
            end, depth = match.end(), 1
            while depth:
                if text[end] == '{': depth += 1
                elif text[end] == '}': depth -= 1
                end += 1
            functions.append(text[match.start():end])
        # Functions are extracted from the shipped QML, not copied into tests.
        script = r'''
const vm = require('node:vm'), assert = require('node:assert/strict');
const source = FUNCTIONS;
function make() {
  const c = { running:true, maxBytes:10, timeoutMs:5000, command:['python3','mouse_ctl.py','status'],
    stdoutData:'',stderrData:'', capturedBytes:0, finishedData:false,
    timedOutData:false,overflowedData:false,startFailedData:false,
    exitCodeData:-1,exitStatusData:-1,finishCount:0,
    proc:{running:false, signals:[], signal(n){this.signals.push(n)}},
    deadline:{start(){},stop(){}},
    Qt:{resolvedUrl(){return 'file:///tmp/plugin%20folder/session_supervisor.py'}},
    finished(){this.finishCount++} };
  c.root=c; vm.createContext(c); vm.runInContext(source,c); return c;
}
let c=make(); c.begin();
assert.deepEqual(Array.from(c.proc.command), ['python3','/tmp/plugin folder/session_supervisor.py','--timeout-ms','5000','--','python3','mouse_ctl.py','status']);
assert.equal(c.proc.running,true);
c=make(); c.proc.running=true; c.begin(); assert.equal(c.proc.command,undefined);
c=make(); c.command=[]; c.begin(); assert.equal(c.startFailedData,true);assert.equal(c.finishCount,1);
c=make(); assert.equal(c.utf8Length('Aé€😀'),10);
c.appendStdout('Aé€😀'); assert.equal(c.capturedBytes,10); assert.equal(c.overflowedData,false);
c.proc.running=true; c.appendStderr('x'); assert.equal(c.stderrData,'');assert.equal(c.overflowedData,true);assert.deepEqual(c.proc.signals,[15]);
c=make(); c.maxBytes=5; c.appendStdout('abc');c.proc.running=true;c.appendStderr('xyz');assert.equal(c.stdoutData,'abc');assert.equal(c.stderrData,'');assert.equal(c.overflowedData,true);
c=make(); c.proc.running=true; c.abort();assert.equal(c.finishedData,false);assert.deepEqual(c.proc.signals,[15]);
c.running=false;c.onExited(143,0);assert.equal(c.finishCount,1);assert.equal(c.exitCodeData,143);
c=make();c.onExited(124,0);assert.equal(c.timedOutData,true);assert.equal(c.finishCount,1);
c=make();c.onExited(125,0);assert.equal(c.startFailedData,true);c.onExited(0,0);assert.equal(c.finishCount,1);
c=make();c.overflowedData=true;c.onExited(143,0);assert.equal(c.overflowedData,true);
console.log('QML JavaScript contract assertions passed');
'''.replace('FUNCTIONS', json.dumps('\n'.join(functions)))
        result = subprocess.run(['node', '-e', script], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_timeout_teardown_and_no_competing_killer(self):
        text = QML.read_text()
        self.assertIn('Component.onDestruction: { if (proc.running) proc.signal(15) }', text)
        self.assertRegex(text, r'onTriggered:\s*\{[\s\S]*?root\.timedOutData = true[\s\S]*?root\.terminate\(\)')
        self.assertIn('session_supervisor.py', text)
        self.assertNotIn('signal(9)', text)
        self.assertNotIn('["setsid"]', text)
        self.assertNotIn('killProc', text)


if __name__ == '__main__':
    unittest.main()
