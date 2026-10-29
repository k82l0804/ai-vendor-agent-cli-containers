#!/usr/bin/env node
// Minimal ACP agent on stdio for Muse Code, which speaks only its own protocol (MSP, `muse serve`).
// Built on Meta's MIT-licensed @muse-code/sdk; the ACP side is plain newline-delimited JSON-RPC.
// One `muse serve` host per connection; sessions run in approval mode allowAll.
// Handles initialize, session/new, session/prompt (streams text, reasoning and tool calls) and session/cancel.
import { MuseClient, readSessionDurability, spawnMspConnection } from "@muse-code/sdk";
import { createInterface } from "node:readline";

const MUSE_BIN = process.env.MUSE_BIN || "muse";
const SERVE_ARGS = ["serve", "--provider", "meta", "--disable-sandbox", "--trust-workspace", "--no-session-log",
  "--contributor-mode", "off", ...(process.env.MUSE_MODEL ? ["--model", process.env.MUSE_MODEL] : [])];
const VERSION = "0.1.0";

const log = (text) => process.stderr.write(`muse-acp: ${text}\n`);
const send = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n");
const update = (sessionId, u) => send({ method: "session/update", params: { sessionId, update: u } });

let host;     // the spawned `muse serve` connection, kept for turn/cancel
let client;
const sessions = new Map();   // sessionId -> { session, turn?, cancelled }

async function museClient(cwd) {
  if (client) return client;
  const handshake = spawnMspConnection({ command: MUSE_BIN, args: SERVE_ARGS, cwd, env: process.env,
    onStderr: (chunk) => process.stderr.write(chunk) });
  host = await handshake.initialize({ clientInfo: { name: "muse_acp", version: VERSION } });
  client = new MuseClient(host.connection, { durability: readSessionDurability(host.initializeResult), host });
  return client;
}

// allowAll should never ask; if Muse does anyway, take its first allowing choice rather than hang the turn.
function autoApprove(request) {
  const choices = request.availableChoices ?? [];
  const allow = choices.find((c) => /allow|approve|accept/i.test(JSON.stringify(c.decision ?? c.label ?? "")));
  return { choiceId: (allow ?? choices[0]).choiceId };
}

const TOOL_KINDS = [[/read|view|cat/i, "read"], [/edit|write|patch|apply/i, "edit"], [/shell|bash|exec|command/i, "execute"],
  [/search|grep|find|glob/i, "search"], [/fetch|web|url/i, "fetch"]];
const toolKind = (name = "") => TOOL_KINDS.find(([re]) => re.test(name))?.[1] ?? "other";
const parseArgs = (args) => { try { return JSON.parse(args); } catch { return args; } };
const TERMINAL = new Set(["completed", "failed", "cancelled", "rejected", "timedOut"]);

async function prompt({ sessionId, prompt: blocks }) {
  const s = sessions.get(sessionId);
  if (!s) throw rpcError(-32602, `unknown session ${sessionId}`);
  const text = blocks.map((b) => b.type === "text" ? b.text
    : b.type === "resource_link" ? `@${b.uri}`
    : b.type === "resource" && b.resource?.text !== undefined ? `<file uri="${b.resource.uri}">\n${b.resource.text}\n</file>`
    : "").filter(Boolean).join("\n");
  s.cancelled = false;
  const turn = await s.session.sendUserTurn({ input: [{ type: "text", text }] });
  s.turn = turn;

  const kinds = new Map();      // itemId -> item kind
  const streamed = new Set();   // itemIds whose text arrived as deltas
  const toolsOpen = new Set();
  const deltas = turn.deltas();
  const items = turn.items();
  const deltaLoop = (async () => {
    for await (const d of deltas) {
      const field = d.field ?? "text";
      const kind = kinds.get(d.itemId);
      if (field === "text" && kind !== "reasoning" && kind !== "toolCall") {
        streamed.add(d.itemId);
        update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: d.delta } });
      } else if (kind === "reasoning" || field.startsWith("summary")) {
        streamed.add(d.itemId);
        update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: d.delta } });
      }
    }
  })();
  const itemLoop = (async () => {
    for await (const item of items) {
      kinds.set(item.itemId, item.kind);
      const done = TERMINAL.has(item.status);
      if (item.kind === "toolCall") {
        const title = item.displayText || item.tool || "tool";
        if (!toolsOpen.has(item.itemId)) {
          toolsOpen.add(item.itemId);
          update(sessionId, { sessionUpdate: "tool_call", toolCallId: item.itemId, title, kind: toolKind(item.tool),
            status: "in_progress", rawInput: item.args ? parseArgs(item.args) : undefined });
        }
        if (done) {
          const output = item.visibleOutput ?? item.fallbackText;
          update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: item.itemId,
            status: item.status === "completed" ? "completed" : "failed",
            ...(output ? { content: [{ type: "content", content: { type: "text", text: output } }] } : {}) });
        }
      } else if (done && !streamed.has(item.itemId)) {
        // Text that never streamed (a replayed or very short item) still reaches the client once.
        if (item.kind === "agentMessage" && item.text) {
          streamed.add(item.itemId);
          update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: item.text } });
        } else if (item.kind === "reasoning" && item.summary?.length) {
          streamed.add(item.itemId);
          update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: item.summary.join("\n") } });
        }
      }
    }
  })();

  const outcome = await turn.completed;
  // Let the item stream deliver the final revisions, then stop both iterators.
  await Promise.race([Promise.all([deltaLoop, itemLoop]), new Promise((r) => setTimeout(r, 300))]);
  await Promise.allSettled([deltas.return?.(), items.return?.()]);
  s.turn = undefined;

  if (outcome.kind === "unqueued" || s.cancelled) return { stopReason: "cancelled" };
  if (outcome.kind === "completed") {
    const p = outcome.params;
    if (p.terminal === "cancelled") return { stopReason: "cancelled" };
    if (p.terminal === "failed") throw rpcError(-32603, p.error?.message || p.reason || "Muse turn failed", p.error);
  }
  return { stopReason: "end_turn" };
}

function rpcError(code, message, data) {
  return Object.assign(new Error(message), { rpc: { code, message, ...(data ? { data } : {}) } });
}

const handlers = {
  initialize: async () => ({
    protocolVersion: 1,
    agentCapabilities: { loadSession: false, promptCapabilities: { image: false, audio: false, embeddedContext: true } },
    agentInfo: { name: "muse-acp", title: "Muse Code", version: VERSION },
    authMethods: [],
  }),
  "session/new": async ({ cwd }) => {
    const c = await museClient(cwd);
    const session = await c.startSession({ workspaceRoot: cwd, approvalMode: "allowAll" });
    session.onApproval(async (request) => autoApprove(request));
    session.onApprovalError((failure) => log(`approval failed: ${failure.kind}`));
    sessions.set(session.sessionId, { session, cancelled: false });
    return { sessionId: session.sessionId };
  },
  "session/prompt": prompt,
};

async function cancel({ sessionId }) {
  const s = sessions.get(sessionId);
  if (!s?.turn) return;
  s.cancelled = true;
  await host.connection.command("turn/cancel", { sessionId, turnId: s.turn.turnId })
    .catch((e) => log(`turn/cancel failed: ${e.message}`));
}

const rl = createInterface({ input: process.stdin });
rl.on("line", async (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return log(`ignoring non-JSON input`); }
  if (msg.method === "session/cancel") return void cancel(msg.params ?? {});
  if (msg.id === undefined || msg.method === undefined) return;   // other notifications, or replies we never asked for
  const handler = handlers[msg.method];
  if (!handler) return send({ id: msg.id, error: { code: -32601, message: `method not found: ${msg.method}` } });
  try {
    send({ id: msg.id, result: await handler(msg.params ?? {}) });
  } catch (e) {
    log(`${msg.method} failed: ${e.stack || e.message}`);
    send({ id: msg.id, error: e.rpc ?? { code: -32603, message: e.message } });
  }
});
rl.on("close", async () => {
  await client?.close().catch(() => {});
  process.exit(0);
});
