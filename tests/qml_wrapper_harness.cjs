'use strict';
// Executes shipped QML JavaScript and signal bodies with deterministic doubles.
// This is a source contract harness, NOT a native Qt/Quickshell integration test.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const scenario = process.argv[3];

function block(text, offset) {
  const begin = text.indexOf('{', offset);
  assert(begin >= 0);
  let end = begin + 1, depth = 1;
  while (depth && end < text.length) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0, 'unbalanced source block');
  return text.slice(begin + 1, end - 1);
}
function handler(text, name) {
  const match = new RegExp('\\b' + name + ':\\s*\\{').exec(text);
  return match ? block(text, match.index) : '';
}
const processBody = block(source, source.indexOf('  Process {'));
const timerBody = block(source, source.indexOf('  Timer {'));
const functions = Array.from(source.matchAll(/^  function \w+\([^)]*\)\s*\{/gm), m =>
  source.slice(m.index, source.indexOf('{', m.index) + 1) + block(source, m.index) + '}').join('\n');

function make(options = {}) {
  const queue = [];
  let requested = false, nativeExists = false, nativeStarted = false;
  const c = {command:['harmless-child'],maxBytes:16,timeoutMs:5000,
    stdoutData:'',stderrData:'',capturedBytes:0,timedOutData:false,
    overflowedData:false,startFailedData:false,exitCodeData:-1,exitStatusData:-1,
    finishedData:false,finishCount:0,launchCount:0,
    Qt:{resolvedUrl(){return 'file:///tmp/plugin%20folder/session_supervisor.py';},
      callLater(fn){if (!queue.includes(fn)) queue.push(fn);}},
    deadline:{active:false,start(){this.active=true;},stop(){this.active=false;}},
    finished(){c.finishCount++;if(options.finished)options.finished(c);}
  };
  // Initialize lifecycle flags from shipped QML, not from an assumed patch.
  for (const m of source.matchAll(/^  property bool (\w+): (true|false)$/gm))
    if (!(m[1] in c)) c[m[1]] = m[2] === 'true';
  c.root = c;
  vm.createContext(c);
  vm.runInContext(functions, c);
  const emit = code => {if(code)vm.runInContext(code, c);};
  const processRunningChanged = () => emit(handler(processBody,'onRunningChanged'));
  c.proc = {signals:[],signal(n){
    assert(nativeExists && nativeStarted, 'must not signal PID 0 during startup');
    this.signals.push(n);
  }};
  Object.defineProperty(c.proc,'running',{get(){return nativeExists;},set(v){
    if(v){assert(!nativeExists,'cannot reuse an active process');nativeExists=true;
      nativeStarted=false;c.launchCount++;}
  }});
  Object.defineProperty(c,'running',{get(){return requested;},set(v){
    if(requested === v)return;requested=v;emit(handler(source,'onRunningChanged'));
  }});
  const stdoutBody = block(processBody, processBody.indexOf('stdout: SplitParser'));
  const stderrBody = block(processBody, processBody.indexOf('stderr: SplitParser'));
  const buffers = {stdout:'',stderr:''};
  function feed(stream, data) {
    // Model the upstream parser's empty-marker and newline-marker branches.
    const body = stream === 'stdout' ? stdoutBody : stderrBody;
    const deliver = s => stream === 'stdout' ? c.appendStdout(s) : c.appendStderr(s);
    if (/splitMarker:\s*""/.test(body))deliver(data);
    else {
      buffers[stream]+=data;
      let split;
      while((split=buffers[stream].indexOf('\n'))>=0){
        deliver(buffers[stream].slice(0,split));
        buffers[stream]=buffers[stream].slice(split+1);
      }
    }
  }
  return {c,buffers,
    request(){c.running=true;this.flush();},
    flush(){let n=0;while(queue.length){assert(++n<20,'deferred-loop runaway');queue.shift()();}},
    started(){assert(nativeExists);nativeStarted=true;processRunningChanged();emit(handler(processBody,'onStarted'));},
    failed(){assert(nativeExists);nativeExists=false;nativeStarted=false;processRunningChanged();},
    exited(code=0,status=0){assert(nativeExists);nativeExists=false;nativeStarted=false;
      c.onExited(code,status);processRunningChanged();},
    idle(){processRunningChanged();},
    timeout(){if(c.deadline.active){c.deadline.active=false;emit(handler(timerBody,'onTriggered'));}},
    feed
  };
}

const scenarios = {
  failed_start(){
    const h=make();h.request();h.failed();
    assert.equal(h.c.finishCount,1);assert.equal(h.c.running,false);
    assert.equal(h.c.startFailedData,true);assert.equal(h.c.timedOutData,false);
    assert.equal(h.c.exitCodeData,-1);assert.equal(h.c.exitStatusData,-1);
    assert.equal(h.c.deadline.active,false);assert.deepEqual(h.c.proc.signals,[]);
    h.idle();h.timeout();assert.equal(h.c.finishCount,1);
  },
  fast_exit(){
    const h=make();h.request();h.started();h.exited();
    assert.equal(h.c.finishCount,1);assert.equal(h.c.startFailedData,false);
    assert.equal(h.c.exitCodeData,0);assert.equal(h.c.exitStatusData,0);
    assert.equal(h.c.running,false);assert.equal(h.c.deadline.active,false);
  },
  idle_notifications(){
    const h=make();h.idle();assert.equal(h.c.finishCount,0);
    h.request();h.started();h.exited();h.idle();assert.equal(h.c.finishCount,1);
  },
  retry_after_failure(){
    const h=make();h.request();h.failed();
    assert.equal(h.c.finishCount,1);
    h.request();assert.equal(h.c.startFailedData,false);h.started();h.exited(7);
    assert.equal(h.c.finishCount,2);assert.equal(h.c.exitCodeData,7);
    assert.equal(h.c.startFailedData,false);assert.equal(h.c.launchCount,2);
  },
  completion_triggered_retry(){
    const h=make({finished(c){if(c.finishCount===1)c.running=true;}});
    h.request();h.failed();assert.equal(h.c.finishCount,1);
    h.idle();assert.equal(h.c.finishCount,1);h.flush();h.started();h.exited();
    assert.equal(h.c.finishCount,2);assert.equal(h.c.startFailedData,false);
    assert.equal(h.c.launchCount,2);
  },
  normal_completion_triggered_retry(){
    const h=make({finished(c){if(c.finishCount===1)c.running=true;}});
    h.request();h.started();h.exited();h.flush();h.started();h.exited();
    assert.equal(h.c.finishCount,2);assert.equal(h.c.launchCount,2);
    assert.equal(h.c.startFailedData,false);
  },
  cancel_then_failed_start(){
    const h=make();h.request();h.c.running=false;
    assert.equal(h.c.finishCount,0);assert.deepEqual(h.c.proc.signals,[]);
    h.failed();assert.equal(h.c.finishCount,1);assert.equal(h.c.startFailedData,true);
    h.idle();assert.equal(h.c.finishCount,1);
  },
  cancel_then_started(){
    const h=make();h.request();h.c.running=false;
    assert.deepEqual(h.c.proc.signals,[]);h.started();
    assert.deepEqual(h.c.proc.signals,[15]);assert.equal(h.c.finishCount,0);
    h.exited(143);assert.equal(h.c.finishCount,1);
    assert.equal(h.c.startFailedData,false);
  },
  timeout_during_start(){
    const h=make();h.request();h.timeout();
    assert.equal(h.c.timedOutData,true);assert.deepEqual(h.c.proc.signals,[]);
    h.started();assert.deepEqual(h.c.proc.signals,[15]);h.exited(124);
    assert.equal(h.c.finishCount,1);assert.equal(h.c.timedOutData,true);
  },
  failed_start_after_timeout(){
    const h=make();h.request();h.timeout();h.failed();
    assert.equal(h.c.finishCount,1);assert.equal(h.c.startFailedData,true);
    assert.equal(h.c.timedOutData,true);assert.equal(h.c.deadline.active,false);
  },
  stdout_without_newline(){
    const h=make();h.request();h.started();
    h.feed('stdout','a'.repeat(16));h.feed('stdout','b');
    assert.equal(h.c.overflowedData,true);assert.equal(h.c.stdoutData,'a'.repeat(16));
    assert.equal(h.buffers.stdout,'');assert.equal(h.c.capturedBytes,16);
    assert.deepEqual(h.c.proc.signals,[15]);assert.equal(h.c.finishCount,0);
    h.exited(143);assert.equal(h.c.finishCount,1);
  },
  stderr_without_newline(){
    const h=make();h.request();h.started();h.feed('stderr','x'.repeat(17));
    assert.equal(h.c.overflowedData,true);assert.equal(h.c.stderrData,'');
    assert.equal(h.buffers.stderr,'');assert.equal(h.c.capturedBytes,0);
    assert.deepEqual(h.c.proc.signals,[15]);
  },
  aggregate_budget(){
    const h=make();h.request();h.started();h.feed('stdout','a'.repeat(9));
    h.feed('stderr','b'.repeat(7));assert.equal(h.c.capturedBytes,16);
    h.feed('stderr','c');h.feed('stdout','ignored');
    assert.equal(h.c.overflowedData,true);assert.equal(h.c.capturedBytes,16);
    assert.equal(h.c.stderrData,'b'.repeat(7));assert.deepEqual(h.c.proc.signals,[15]);
    h.exited(143);h.feed('stdout','late');assert.equal(h.c.capturedBytes,16);
  },
  preserve_newlines_and_chunks(){
    const h=make();h.c.maxBytes=64;h.request();h.started();
    h.feed('stdout','{"line":"one"}\n');h.feed('stdout','tail');
    h.feed('stderr','warn\n');h.exited();
    assert.equal(h.c.stdoutData,'{"line":"one"}\ntail');
    assert.equal(h.c.stderrData,'warn\n');
    assert.equal(h.c.capturedBytes,Buffer.byteLength('{"line":"one"}\ntailwarn\n'));
  },
  utf8_aggregate_budget(){
    const h=make();h.c.maxBytes=10;h.request();h.started();
    h.feed('stdout','Aé€😀');assert.equal(h.c.capturedBytes,10);
    h.feed('stderr','é');assert.equal(h.c.overflowedData,true);
    assert.equal(h.c.stdoutData,'Aé€😀');assert.equal(h.c.stderrData,'');
  },
  retry_resets_output_and_flags(){
    const h=make();h.request();h.started();h.feed('stderr','a'.repeat(17));h.exited(143);
    h.request();assert.equal(h.c.overflowedData,false);assert.equal(h.c.capturedBytes,0);
    assert.equal(h.c.stdoutData,'');assert.equal(h.c.stderrData,'');
    h.started();h.feed('stdout','ok');h.exited();
    assert.equal(h.c.finishCount,2);assert.equal(h.c.stdoutData,'ok');
    assert.equal(h.c.startFailedData,false);assert.equal(h.c.timedOutData,false);
  }
};
assert(scenario in scenarios, 'unknown scenario: '+scenario);
scenarios[scenario]();
console.log('PASS '+scenario);
