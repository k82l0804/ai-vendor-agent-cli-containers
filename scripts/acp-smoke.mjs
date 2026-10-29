#!/usr/bin/env node
// ACP smoke test through the same commands the VS Code client runs.
// Per agent: initialize -> session/new -> a text prompt -> a shell prompt (checks auto-approve, user and folder) ->
// close stdin, then check nothing is left behind.
// Usage: node scripts/acp-smoke.mjs claude codex ...
//   ACP_SMOKE_VIA=connect  start each agent with bin/acp-connect (a new container mounting ACP_SMOKE_CWD);
//                          default: docker exec into the long-running container (fixed workspace)
//   ACP_SMOKE_CWD          folder the client "has open" (default: this process's cwd)
import { spawn, execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { realpathSync } from "node:fs";

const VIA = process.env.ACP_SMOKE_VIA === "connect" ? "connect" : "exec";
const CLIENT_CWD = process.env.ACP_SMOKE_CWD || process.cwd();
const CONNECT = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "acp-connect");
const TURN_TIMEOUT_MS = 180_000;

function connect(agent) {
  // Like the VS Code client: started in the open folder, which it also sends as the session cwd.
  const child = VIA === "connect"
    ? spawn(CONNECT, [agent], { cwd: CLIENT_CWD, stdio: ["pipe", "pipe", "pipe"] })
    : spawn("docker", ["exec", "-i", `acp-${agent}`, "acp-run"], { cwd: CLIENT_CWD, stdio: ["pipe", "pipe", "pipe"] });
  let nextId = 1, buf = "", stderr = "";
  const pending = new Map();
  const stats = { permissionRequests: 0, text: "", toolCalls: 0, otherClientCalls: [] };

  const send = (msg) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n");
  child.stderr.on("data", (d) => { stderr += d; });
  child.stdout.on("data", (d) => {
    buf += d;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { stats.otherClientCalls.push(`non-JSON stdout: ${line.slice(0, 120)}`); continue; }
      if (msg.id !== undefined && msg.method === undefined) {
        const p = pending.get(msg.id);
        if (p) { pending.delete(msg.id); msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result); }
      } else if (msg.method === "session/update") {
        const u = msg.params?.update;
        if (u?.sessionUpdate === "agent_message_chunk" && u.content?.type === "text") stats.text += u.content.text;
        if (u?.sessionUpdate === "tool_call") stats.toolCalls++;
      } else if (msg.method === "session/request_permission") {
        stats.permissionRequests++;
        const opt = msg.params.options.find((o) => o.kind === "allow_once") ?? msg.params.options[0];
        send({ id: msg.id, result: { outcome: { outcome: "selected", optionId: opt.optionId } } });
      } else if (msg.id !== undefined) {
        stats.otherClientCalls.push(msg.method);
        send({ id: msg.id, error: { code: -32601, message: `client does not implement ${msg.method}` } });
      }
    }
  });

  const exited = new Promise((res) => child.on("exit", (code, signal) => res({ code, signal })));
  const request = (method, params, timeoutMs = 60_000) => new Promise((resolve, reject) => {
    const id = nextId++;
    const t = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out after ${timeoutMs} ms`)); }, timeoutMs);
    pending.set(id, { resolve: (r) => { clearTimeout(t); resolve(r); }, reject: (e) => { clearTimeout(t); reject(e); } });
    send({ id, method, params });
  });
  return { child, request, stats, exited, stderr: () => stderr };
}

// The folder the agent should be working in.
const EXPECTED_DIR = VIA === "connect" && ![homedir(), "/", "/home", "/root"].includes(realpathSync(CLIENT_CWD))
  ? realpathSync(CLIENT_CWD)
  : (process.env.WORKSPACE || `${homedir()}/workarea/tmp`);

function oneOffContainers() {
  return execFileSync("docker", ["ps", "-aq", "--filter", "label=com.docker.compose.project=acp",
    "--filter", "label=com.docker.compose.oneoff=True"]).toString().trim().split("\n").filter(Boolean).length;
}

function homesLeft(agent) {
  if (VIA === "connect") return "n/a (container removed)";
  try { return execFileSync("docker", ["exec", `acp-${agent}`, "sh", "-c", "ls -d /tmp/acp-home.* 2>/dev/null | wc -l"]).toString().trim(); }
  catch { return "?"; }
}

async function smoke(agent) {
  const t0 = Date.now();
  const r = { agent, steps: [] };
  const before = homesLeft(agent);
  const c = connect(agent);
  try {
    const init = await c.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: "acp-smoke", version: "0.1.0" },
    }, 90_000);
    r.steps.push(`initialize ok: ${init.agentInfo?.name ?? "?"} ${init.agentInfo?.version ?? ""} (protocol ${init.protocolVersion})`);
    const ses = await c.request("session/new", { cwd: CLIENT_CWD, mcpServers: [] });
    r.steps.push(`session/new ok: ${ses.sessionId}; modes: ${(ses.modes?.availableModes ?? []).map((m) => m.id).join(",") || "-"} current=${ses.modes?.currentModeId ?? "-"}`);

    c.stats.text = "";
    const p1 = await c.request("session/prompt", { sessionId: ses.sessionId, prompt: [{ type: "text", text: "Reply with exactly the word OK and nothing else." }] }, TURN_TIMEOUT_MS);
    r.steps.push(`prompt 1 (${p1.stopReason}): ${JSON.stringify(c.stats.text.trim().slice(0, 80))}`);

    c.stats.text = "";
    const p2 = await c.request("session/prompt", { sessionId: ses.sessionId, prompt: [{ type: "text", text: "Run the shell command `id -un && pwd` and reply with its output only." }] }, TURN_TIMEOUT_MS);
    r.steps.push(`prompt 2 (${p2.stopReason}): ${JSON.stringify(c.stats.text.trim().slice(0, 120))}; tool calls ${c.stats.toolCalls}; permission requests ${c.stats.permissionRequests}`);
    if (c.stats.otherClientCalls.length) r.steps.push(`client calls refused / noise: ${[...new Set(c.stats.otherClientCalls)].join(", ")}`);
    const out = c.stats.text;
    r.ok = out.includes("agent") && out.includes(EXPECTED_DIR) && c.stats.permissionRequests === 0;
    if (!r.ok) r.steps.push(`FAILED: expected user agent in ${EXPECTED_DIR} with no permission requests`);
  } catch (e) {
    r.ok = false;
    r.steps.push(`FAILED: ${e.message}`);
  }
  c.child.stdin.end();
  const exit = await Promise.race([c.exited, new Promise((res) => setTimeout(() => res("still running 15 s after stdin closed"), 15_000))]);
  if (typeof exit === "string") { r.steps.push(exit); c.child.kill("SIGKILL"); }
  else r.steps.push(`exit: code ${exit.code} signal ${exit.signal}`);
  await new Promise((res) => setTimeout(res, 1000));
  r.steps.push(`throwaway homes in /tmp: before ${before}, after ${homesLeft(agent)}`);
  r.seconds = Math.round((Date.now() - t0) / 1000);
  r.stderrTail = c.stderr().trim().split("\n").slice(-8).join("\n");
  return r;
}

const agents = process.argv.slice(2);
if (!agents.length) { console.error("usage: acp-smoke.mjs <agent>..."); process.exit(2); }
console.log(`via ${VIA}; client folder ${CLIENT_CWD}; expected agent folder ${EXPECTED_DIR}`);
const results = await Promise.all(agents.map(smoke));
let failed = 0;
if (VIA === "connect") {
  const left = oneOffContainers();
  console.log(`per-connection containers left: ${left}`);
  if (left) failed++;
}
for (const r of results) {
  if (!r.ok) failed++;
  console.log(`\n=== ${r.agent}: ${r.ok ? "PASS" : "FAIL"} (${r.seconds}s)`);
  for (const s of r.steps) console.log(`  ${s}`);
  if (!r.ok && r.stderrTail) console.log(`  stderr tail:\n    ${r.stderrTail.replace(/\n/g, "\n    ")}`);
}
process.exit(failed ? 1 : 0);
