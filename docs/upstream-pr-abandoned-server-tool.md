# Record: abandoned server tool calls fail the turn (not submitted upstream)

Written as a PR for agentclientprotocol/claude-agent-acp against `main` (df21b3f), tested
there red then green; not submitted. Carried as `patches/claude-agent-acp/0.90.0/0002-close-unanswered-server-tool-calls.patch`.

---

**Title:** `fix: close a server tool call left without a result instead of failing the turn`

**Body:**

`recordDispatchedToolUses` records `server_tool_use` blocks as dispatched to the tool runner,
next to `tool_use` and `mcp_tool_use`. The tool runner never sees a server tool: the API runs it
(the advisor, web search) inside the response, and its result comes back in assistant content.
So a `server_tool_use` that still has no result at `end_turn` was abandoned by Claude, not lost
by the tool runner. Today it lands in the `stuck` branch of `settleActive` and fails the prompt
with `incomplete_tool_call`:

```
Claude ended the turn without returning results for tool calls: srvtoolu_...
```

This PR stops recording `server_tool_use` as dispatched, so such a call takes the existing
abandoned branch (#1249): its tool call is closed with "Claude stopped this tool call before it
ran." and the turn ends normally. A server tool whose result does arrive is unaffected: the
`web_search_tool_result`, `web_fetch_tool_result`, `code_execution_tool_result` and similar
cases already complete the call and remove it from `emittedToolCalls`.

**Seen in practice** (0.86.0 with #1247's change ported, JetBrains AI Chat, PyCharm 2026.2).
Across two sessions in one day, all 36 advisor calls were classified from the session
transcripts by where the call sat in its response:

| advisor call | result arrived | turn failed |
| --- | --- | --- |
| first block of its response, no message sent meanwhile | 31 / 31 | 0 |
| after a client `tool_use` (Edit) in the same response | 0 / 2 | 2 |
| a steering message arrived while it ran | 0 / 3 | 2 (the third turn was cancelled, which skips the check) |

JetBrains treats the `incomplete_tool_call` error as non-recoverable: it SIGTERMs the agent and
stops its reconnect loop. In an earlier occurrence (not re-checked for this PR), background
subagents still running in the killed process never delivered their results.

**Relation to #1247.** Independent and stackable in either order. #1247 settles an
`advisor_tool_result` that arrives; this PR handles the call whose result never arrives.
Without #1247, an advisor call whose result did arrive is also closed by this path, labelled
"before it ran" instead of completed, which is still better than failing the turn. Related:
#914.

**Not changed, for the maintainers to decide:**

- `mcp_tool_use` (the API's MCP connector) is the same class: run by the API, result in
  assistant content. Left as is to keep this change to the case observed.
- The close text says the call never ran; the API may have started the advisor before the
  steering message cut it off.

**Tests.** New case in `src/tests/incomplete-tools.test.ts`: a streamed and consolidated
`server_tool_use` with no result, then `end_turn`. It fails on `main` with the error above and
passes with the change; like its abandoned-tool siblings it also checks that no hook callback,
emitted tool call or cache entry is left behind. `npm run check` and `npm run build` pass.
`npm run test:run`: one failure, `acp-scenarios.test.ts` > "replaces only the version of this
adapter and the path of this Node binary", which also fails on `main` without this change on a
machine whose Node is `/usr/bin/node` (the path that test uses as "another Node").
