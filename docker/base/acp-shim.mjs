#!/usr/bin/env node
// Relays ACP stdio between the client and the agent, changing only two things:
//  1. cwd: a session request whose `cwd` does not exist in this container (the client sends its open VS Code folder,
//     whatever that is) is pointed at $WORKSPACE instead, so any folder can be open on the host.
//  2. mode: with $ACP_INITIAL_MODE set, after each session/new|load|resume succeeds it sends session/set_mode to the
//     agent *before* the client sees the reply, so the first prompt already runs in that mode (agy has no other way).
// Usage: acp-shim <agent command> [args...]
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

const mode = process.env.ACP_INITIAL_MODE;
const workspace = process.env.WORKSPACE;
const [cmd, ...args] = process.argv.slice(2);
const agent = spawn(cmd, args, { stdio: ["pipe", "pipe", "inherit"] });
const SESSION_METHODS = new Set(["session/new", "session/load", "session/resume"]);
const CWD_METHODS = new Set([...SESSION_METHODS, "session/list"]);
const pending = new Map();   // client request id -> { sessionId? }
let shimId = 0;

function lines(stream, onLine) {
  let buf = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      onLine(buf.slice(0, nl + 1));
      buf = buf.slice(nl + 1);
    }
  });
  stream.on("end", () => { if (buf) onLine(buf); });
}

function parse(line) {
  try { return JSON.parse(line); } catch { return null; }
}

lines(process.stdin, (line) => {
  const msg = parse(line);
  if (msg && CWD_METHODS.has(msg.method) && typeof msg.params?.cwd === "string" && workspace && !existsSync(msg.params.cwd)) {
    process.stderr.write(`acp-shim: cwd ${msg.params.cwd} is not in this container; using ${workspace}\n`);
    msg.params.cwd = workspace;
    line = JSON.stringify(msg) + "\n";
  }
  if (mode && msg && SESSION_METHODS.has(msg.method) && msg.id !== undefined) {
    pending.set(JSON.stringify(msg.id), { sessionId: msg.params?.sessionId });
  }
  agent.stdin.write(line);
});
process.stdin.on("end", () => agent.stdin.end());

lines(agent.stdout, (line) => {
  const msg = parse(line);
  if (msg && msg.method === undefined && typeof msg.id === "string" && msg.id.startsWith("acp-shim-")) {
    if (msg.error) process.stderr.write(`acp-shim: set_mode ${mode} failed: ${JSON.stringify(msg.error)}\n`);
    return;
  }
  const key = msg && msg.method === undefined && msg.id !== undefined ? JSON.stringify(msg.id) : null;
  if (key && pending.has(key)) {
    const { sessionId } = pending.get(key);
    pending.delete(key);
    const id = msg.result?.sessionId ?? sessionId;
    const modes = msg.result?.modes;
    const offered = !modes || (modes.availableModes ?? []).some((m) => m.id === mode);
    if (id && !msg.error && offered && modes?.currentModeId !== mode) {
      agent.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: `acp-shim-${++shimId}`, method: "session/set_mode",
        params: { sessionId: id, modeId: mode } }) + "\n");
      if (modes) msg.result.modes = { ...modes, currentModeId: mode };
      line = JSON.stringify(msg) + "\n";
    }
  }
  process.stdout.write(line);
});

agent.on("exit", (code, signal) => process.exit(signal ? 128 : (code ?? 0)));
for (const s of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(s, () => agent.kill(s));
