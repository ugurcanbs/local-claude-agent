// Post-install check for 0001-settle-advisor-tool-results.patch, run by the
// installers against the patched package directory (argv[2]). It feeds an advisor
// call and each kind of advisor result through the adapter's own notification code
// and fails unless the call is settled: a terminal update with the right status, no
// trace left in the tracking state the turn-end check reads, no ciphertext rendered.
// It imports package internals, so it belongs to this exact version's folder.
import path from "node:path";
import { pathToFileURL } from "node:url";

const pkg = path.resolve(process.argv[2] ?? "");
const load = (rel) => import(pathToFileURL(path.join(pkg, "dist", rel)).href);
const { toAcpNotifications } = await load("acp-agent.js");
const { hasHookCallback, unregisterHookCallback } = await load("tools.js");
const { ToolCallFieldTracker } = await load("tool-calls/field-tracker.js");

const cases = [
  { content: { type: "advisor_result", text: "Check the queue ordering." }, status: "completed", shows: "Check the queue ordering." },
  { content: { type: "advisor_redacted_result", encrypted_content: "OPAQUE-CIPHERTEXT" }, status: "completed", hides: "OPAQUE-CIPHERTEXT" },
  { content: { type: "advisor_tool_result_error", error_code: "overloaded" }, status: "failed", shows: "overloaded" },
];
const failures = [];
for (const c of cases) {
  const id = `srvtoolu_check_${c.content.type}`;
  const errors = [];
  const logger = { log() {}, warn() {}, error: (...a) => errors.push(a.map(String).join(" ")) };
  const client = { sessionUpdate: async () => {} };
  const toolUseCache = {};
  const emittedToolCalls = new Set();
  const toolCallFields = new ToolCallFieldTracker();
  const opts = { emittedToolCalls, toolCallFields, cwd: pkg, taskState: new Map() };
  const run = (blocks) => toAcpNotifications(blocks, "assistant", "check", toolUseCache, client, logger, opts);
  run([{ type: "server_tool_use", id, name: "advisor", input: {} }]);
  // The adapter marks a call as emitted when it sends it to the client; the
  // turn-end check fails the turn for any id still in this set.
  emittedToolCalls.add(id);
  const out = run([{ type: "advisor_tool_result", tool_use_id: id, content: c.content }]);
  const terminal = out.map((n) => n.update).find((u) => u.toolCallId === id && ["completed", "failed"].includes(u.status));
  const rendered = JSON.stringify(out);
  const problems = [];
  if (terminal?.status !== c.status) problems.push(`terminal status ${terminal?.status ?? "missing"}, expected ${c.status}`);
  if (emittedToolCalls.has(id)) problems.push("call still unfinished");
  if (id in toolUseCache) problems.push("call still cached");
  if (hasHookCallback(id)) problems.push("hook callback still registered");
  if (c.shows && !rendered.includes(c.shows)) problems.push(`result text "${c.shows}" not rendered`);
  if (c.hides && rendered.includes(c.hides)) problems.push("ciphertext rendered");
  if (errors.length) problems.push(`logged errors: ${errors.join("; ")}`);
  unregisterHookCallback(id);
  if (problems.length) failures.push(`${c.content.type}: ${problems.join(", ")}`);
}
if (failures.length) {
  console.error(`Advisor results are not settled in ${pkg}:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(`Advisor results settle in ${pkg} (${cases.length} result types)`);
