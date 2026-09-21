#!/usr/bin/env node
// qmp.mjs <socket> <command> — the minimum QMP client needed for B10.
//   wait-suspend   block until the guest actually enters S3 (the SUSPEND event), then exit 0
//   wakeup         send system_wakeup
//   suspend-cycle  wait-suspend, then wakeup — what run-boot.sh calls
//   quit           ask the VM to exit cleanly
//   screendump     qmp.mjs <socket> screendump <timeout_s> <file.png> [device] — a PNG of the display
//                  (console 0, or the QOM device id given). Evidence only; nothing gates on it.
// It waits on the EVENT, never on a clock: a guest that takes four minutes to suspend under TCG is
// slow, not broken, and scoring it as broken is the single easiest way to make this harness lie.
import net from 'node:net';

const [sock, cmd, timeoutArg, shotFile, shotDevice] = process.argv.slice(2);
const TIMEOUT = Number(timeoutArg || process.env.AUROS_QMP_TIMEOUT || 900) * 1000;
if (!sock || !cmd) { console.error('usage: qmp.mjs <socket> <wait-suspend|wakeup|suspend-cycle|quit|screendump> [timeout_s] [file.png] [device]'); process.exit(2); }

const c = net.createConnection(sock);
let buf = '';
let negotiated = false;
let sawSuspend = false;
const deadline = setTimeout(() => { console.error(`qmp: timed out after ${TIMEOUT / 1000}s waiting for ${cmd}`); process.exit(1); }, TIMEOUT);

function send(o) { c.write(JSON.stringify(o) + '\n'); }

c.on('error', (e) => { console.error(`qmp: ${e.message}`); process.exit(1); });
c.on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.QMP && !negotiated) { negotiated = true; send({ execute: 'qmp_capabilities' }); continue; }
    if (m.event) {
      console.log(`qmp event: ${m.event}`);
      if (m.event === 'SUSPEND') {
        sawSuspend = true;
        if (cmd === 'wait-suspend') { clearTimeout(deadline); c.end(); process.exit(0); }
        if (cmd === 'suspend-cycle') send({ execute: 'system_wakeup' });
      }
      if (m.event === 'WAKEUP' && cmd === 'suspend-cycle' && sawSuspend) { clearTimeout(deadline); c.end(); process.exit(0); }
      continue;
    }
    // A refused command answers {"error":…} and nothing else; waiting on a "return" that never comes
    // would turn "no such device" into a 30-second timeout that says nothing.
    if (m.error && cmd === 'screendump') { console.error(`qmp: ${cmd}: ${m.error.class}: ${m.error.desc}`); process.exit(1); }
    if (m.return !== undefined) {
      if (!negotiatedDone()) continue;
      if (cmd === 'wakeup') { clearTimeout(deadline); c.end(); process.exit(0); }
      if (cmd === 'quit') { clearTimeout(deadline); c.end(); process.exit(0); }
      if (cmd === 'screendump') { clearTimeout(deadline); c.end(); process.exit(0); }
    }
  }
});

let capsAcked = false;
function negotiatedDone() {
  if (!capsAcked) {
    capsAcked = true;
    if (cmd === 'wakeup') send({ execute: 'system_wakeup' });
    else if (cmd === 'quit') send({ execute: 'quit' });
    else if (cmd === 'screendump') {
      // format:"png" needs QEMU >= 7.1 (ubuntu-24.04 ships 8.2); older QEMU refuses it by name, and says so.
      const a = { filename: shotFile, format: 'png' };
      if (shotDevice) a.device = shotDevice;
      send({ execute: 'screendump', arguments: a });
    }
    return false;
  }
  return true;
}
