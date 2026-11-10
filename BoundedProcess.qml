import QtQuick
import Quickshell.Io

// session_supervisor owns descendant cleanup, including after this component's
// Process is hard-killed on reload/destruction. Its small tracked relay can die
// without killing the cleanup worker. QML requests cancellation with SIGTERM;
// only the supervisor escalates, and completion follows its cleanup attempt.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  property var command: []
  property int maxBytes: 262144
  property int timeoutMs: 15000
  property bool running: false

  readonly property string stdout: stdoutData
  readonly property string stderr: stderrData
  readonly property int exitCode: exitCodeData
  readonly property int exitStatus: exitStatusData
  readonly property bool timedOut: timedOutData
  readonly property bool overflowed: overflowedData
  readonly property bool startFailed: startFailedData
  readonly property bool success: finishedData && !startFailedData && !timedOutData
      && !overflowedData && exitStatusData === 0 && exitCodeData === 0

  signal finished()

  property string stdoutData: ""
  property string stderrData: ""
  property int capturedBytes: 0
  property bool timedOutData: false
  property bool overflowedData: false
  property bool startFailedData: false
  property int exitCodeData: -1
  property int exitStatusData: -1
  property bool finishedData: false

  onRunningChanged: {
    if (root.running) {
      // Defer until Process/Timer children are constructed.
      Qt.callLater(root.begin)
    } else if (!root.finishedData) {
      root.abort()
    }
  }

  // Quickshell may immediately SIGKILL its tracked process during destruction.
  // The supervisor's relay/worker parent-death protocol covers that race too.
  Component.onDestruction: { if (proc.running) proc.signal(15) }

  Process {
    id: proc
    stdout: SplitParser {
      onRead: function(data) { root.appendStdout(data) }
    }
    stderr: SplitParser {
      onRead: function(data) { root.appendStderr(data) }
    }
    onExited: function(code, status) { root.onExited(code, status) }
  }

  Timer {
    id: deadline
    interval: Math.max(250, root.timeoutMs)
    repeat: false
    onTriggered: {
      if (root.running && !root.finishedData) {
        root.timedOutData = true
        root.terminate()
      }
    }
  }

  function begin() {
    // Never reuse the tracked Process while an earlier cleanup is running.
    if (!root.running || proc.running) return
    var cmd = root.command
    if (!cmd || cmd.length === 0) {
      root.reset()
      root.startFailedData = true
      root.finish()
      return
    }
    root.reset()
    var supervisor = decodeURIComponent(Qt.resolvedUrl("session_supervisor.py")
        .toString().replace(/^file:\/\//, ""))
    proc.command = ["python3", supervisor, "--timeout-ms",
        String(Math.max(250, root.timeoutMs)), "--"].concat(cmd)
    deadline.interval = Math.max(250, root.timeoutMs)
    deadline.start()
    proc.running = true
  }

  function reset() {
    stdoutData = ""
    stderrData = ""
    capturedBytes = 0
    timedOutData = false
    overflowedData = false
    startFailedData = false
    exitCodeData = -1
    exitStatusData = -1
    finishedData = false
  }

  function utf8Length(text) {
    var bytes = 0
    for (var i = 0; i < text.length; ++i) {
      var code = text.charCodeAt(i)
      if (code < 0x80) bytes += 1
      else if (code < 0x800) bytes += 2
      else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length
          && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
        bytes += 4
        ++i
      } else bytes += 3
    }
    return bytes
  }

  function appendOutput(data, isStderr) {
    if (!root.running || root.finishedData || root.overflowedData) return
    var bytes = root.utf8Length(data)
    // One aggregate UTF-8 budget. Never retain the overflowing chunk.
    if (root.capturedBytes + bytes > Math.max(0, root.maxBytes)) {
      root.overflowedData = true
      deadline.stop()
      root.terminate()
      return
    }
    root.capturedBytes += bytes
    if (isStderr) root.stderrData += data
    else root.stdoutData += data
  }

  function appendStdout(data) { root.appendOutput(data, false) }
  function appendStderr(data) { root.appendOutput(data, true) }

  function terminate() {
    if (proc.running) proc.signal(15)
    // Do not finish or cancel supervision while descendants are being cleaned.
  }

  function onExited(code, status) {
    if (root.finishedData) return
    deadline.stop()
    root.exitCodeData = code
    root.exitStatusData = status
    if (code === 124) root.timedOutData = true
    if (code === 125) root.startFailedData = true
    root.finish()
  }

  function abort() {
    deadline.stop()
    if (proc.running) root.terminate()
    else root.finish()
  }

  function finish() {
    if (root.finishedData) return
    root.finishedData = true
    root.running = false
    root.finished()
  }
}
