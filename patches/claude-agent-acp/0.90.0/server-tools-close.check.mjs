// Post-install check for 0002-close-unanswered-server-tool-calls.patch, run by the
// installers against the patched package directory (argv[2]). It drives one prompt
// through the agent with a scripted Claude Code stream: an advisor server_tool_use in
// a complete assistant message, no advisor result, then end_turn. It fails unless
// the prompt ends normally and the advisor's tool call is closed. Unpatched, the
// prompt fails with incomplete_tool_call. It imports package internals, so it
// belongs to this exact version's folder.
import { randomUUID } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";

const pkg = path.resolve(process.argv[2] ?? "");
const load = (rel) => import(pathToFileURL(path.join(pkg, "dist", rel)).href);
const { ClaudeAcpAgent } = await load("acp-agent.js");
const { Pushable } = await load("utils.js");
const { SessionTitles } = await load("session-titles.js");

const sessionId = "check-session";
const advisorId = "srvtoolu_check_advisor";
const usage = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
const advisor = { type: "server_tool_use", id: advisorId, name: "advisor", input: {} };

async function* claudeCode(input) {
  const { value } = await input[Symbol.asyncIterator]().next();
  yield { type: "user", message: value.message, parent_tool_use_id: null, uuid: value.uuid, session_id: sessionId, isReplay: true };
  yield {
    type: "stream_event", session_id: sessionId, uuid: "stream-message", parent_tool_use_id: null,
    event: { type: "content_block_start", index: 0, content_block: advisor },
  };
  yield { type: "assistant", session_id: sessionId, parent_tool_use_id: null, message: { role: "assistant", usage, content: [advisor] } };
  yield { type: "assistant", session_id: sessionId, parent_tool_use_id: null, message: { role: "assistant", usage, content: [{ type: "text", text: "Done." }] } };
  yield {
    type: "result", subtype: "success", stop_reason: "end_turn", is_error: false, result: "", errors: [],
    duration_ms: 0, duration_api_ms: 0, num_turns: 1, total_cost_usd: 0, usage, modelUsage: {},
    permission_denials: [], uuid: randomUUID(), session_id: sessionId,
  };
}

const updates = [];
const errors = [];
const agent = new ClaudeAcpAgent(
  {
    sessionUpdate: async (n) => updates.push(n.update),
    requestPermission: async () => ({ outcome: { outcome: "selected", optionId: "allow-once" } }),
    extNotification: async () => {},
  },
  { log() {}, error: (...a) => errors.push(a.map(String).join(" ")) },
);
const input = new Pushable();
const query = Object.assign(claudeCode(input), {
  interrupt: async () => {}, stopTask: async () => {}, close() {}, setModel: async () => {},
});
const inertAgent = { client: { sessionUpdate: async () => {} }, logger: { error() {} }, sessions: {} };
agent.sessions[sessionId] = {
  input, query, cancelled: false, cwd: pkg,
  sessionFingerprint: JSON.stringify({ cwd: pkg, mcpServers: [] }),
  titles: new SessionTitles(inertAgent, sessionId),
  modes: { currentModeId: "default", availableModes: [] },
  models: { currentModelId: "default", availableModels: [] },
  modelInfos: [],
  settingsManager: { dispose() {}, getSettings: () => ({}), getApiKeyHelper: () => undefined, getCwd: () => pkg },
  accumulatedUsage: { inputTokens: 0, outputTokens: 0, cachedReadTokens: 0, cachedWriteTokens: 0 },
  accumulatedModelUsage: {}, lastModelUsageReading: {}, configOptions: [], agents: [], currentAgent: "default",
  abortController: new AbortController(), emitRawSDKMessages: false, forwardSubagentText: false,
  contextWindowSize: 200000, contextWindowAuthoritative: false, providerCacheKey: "default",
  taskState: new Map(), toolUseCache: {}, emittedToolCalls: new Set(), liveBackgroundTasks: new Map(),
  emittedAssistantText: false, owedTrailingIdles: 0, messageIdToUuid: new Map(),
  sessionFailureState: { epoch: randomUUID(), revisions: new Map(), active: new Map() },
};

const problems = [];
let response;
try {
  response = await agent.prompt({ sessionId, prompt: [{ type: "text", text: "check" }] });
} catch (err) {
  problems.push(`prompt failed: ${err?.message ?? err}`);
}
if (response && response.stopReason !== "end_turn") problems.push(`stopReason ${response.stopReason}, expected end_turn`);
const closed = updates.find((u) => u.toolCallId === advisorId && ["completed", "failed"].includes(u.status));
if (!closed) problems.push("advisor tool call left open");
if (agent.sessions[sessionId].emittedToolCalls.has(advisorId)) problems.push("advisor call still tracked");
const turnErrors = errors.filter((e) => e.includes("ended the turn"));
if (turnErrors.length) problems.push(`logged: ${turnErrors.join("; ")}`);
if (problems.length) {
  console.error(`An unanswered server tool call still fails the turn in ${pkg}:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
console.log(`An unanswered server tool call is closed without failing the turn in ${pkg}`);
process.exit(0);
