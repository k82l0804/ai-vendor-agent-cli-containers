#!/usr/bin/env node
// Relays ACP stdio between the client and the agent, changing only four things:
//  1. cwd: a session request whose `cwd` does not exist in this container (the client sends its open VS Code folder,
//     whatever that is) is pointed at $WORKSPACE instead, so any folder can be open on the host.
//  2. mode: with $ACP_INITIAL_MODE set, after each session/new|load|resume succeeds it sends session/set_mode to the
//     agent *before* the client sees the reply, so the first prompt already runs in that mode (agy has no other way).
//  3. _meta: with $ACP_SESSION_META set (a JSON object), it is merged into each session/new|load|resume request's
//     params._meta, for agent options only a client can send (agy's built-in tool denylist).
//  4. noise: with $ACP_DROP_MESSAGE set (a regular expression), the first agent_message_chunk of each turn is dropped
//     when it is entirely a match, or trimmed when it begins with one (codex's per-turn "model metadata not found"
//     warning for proxy models). Later chunks are never touched, and a warning split across chunks is forwarded
//     rather than guessed at.
// Usage: acp-shim <agent command> [args...]
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

const mode = process.env.ACP_INITIAL_MODE;
const workspace = process.env.WORKSPACE;
// A bad value must fail loudly, not open: a typo in ACP_SESSION_META would otherwise drop agy's tool denylist.
function fromEnv(name, build) {
  const raw = process.env[name];
  if (!raw) return null;
  try { return build(raw); } catch (e) {
    process.stderr.write(`acp-shim: invalid ${name} (${e.message}): ${raw}\n`);
    process.exit(1);
  }
}
const sessionMeta = fromEnv("ACP_SESSION_META", (raw) => JSON.parse(raw));
const dropMessage = fromEnv("ACP_DROP_MESSAGE", (raw) => new RegExp(`^(?:${raw})`, "s"));
const turnStart = new Set();   // sessionIds whose next agent_message_chunk opens a turn
let dropped = 0;
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

// Objects merge key by key; anything else from `extra` replaces what the client sent.
function merge(base, extra) {
  if (!base || typeof base !== "object" || Array.isArray(base) || typeof extra !== "object" || Array.isArray(extra)) return extra;
  const out = { ...base };
  for (const [k, v] of Object.entries(extra)) out[k] = merge(base[k], v);
  return out;
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
  if (sessionMeta && msg && SESSION_METHODS.has(msg.method) && msg.params) {
    msg.params._meta = merge(msg.params._meta ?? {}, sessionMeta);
    line = JSON.stringify(msg) + "\n";
  }
  if (mode && msg && SESSION_METHODS.has(msg.method) && msg.id !== undefined) {
    pending.set(JSON.stringify(msg.id), { sessionId: msg.params?.sessionId });
  }
  if (dropMessage && msg?.method === "session/prompt" && msg.params?.sessionId) turnStart.add(msg.params.sessionId);
  agent.stdin.write(line);
});
process.stdin.on("end", () => agent.stdin.end());

lines(agent.stdout, (line) => {
  const msg = parse(line);
  const update = msg?.method === "session/update" ? msg.params?.update : undefined;
  if (dropMessage && update?.sessionUpdate === "agent_message_chunk" && turnStart.has(msg.params?.sessionId)) {
    turnStart.delete(msg.params.sessionId);
    const text = update.content?.text ?? "";
    const m = dropMessage.exec(text);
    if (m && m[0].length > 0) {
      if (dropped++ === 0) process.stderr.write(`acp-shim: ACP_DROP_MESSAGE matched at turn start: ${m[0].trim()}\n`);
      if (m[0].length === text.length) return;        // the whole chunk is the warning
      update.content.text = text.slice(m[0].length);  // the warning glued to the reply's first words
      line = JSON.stringify(msg) + "\n";
    }
  }
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
