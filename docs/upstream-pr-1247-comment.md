# Draft: comment for agentclientprotocol/claude-agent-acp PR #1247

Target: https://github.com/agentclientprotocol/claude-agent-acp/pull/1247
("fix: settle advisor tool results before completing turns"; addresses the result-lifecycle part
of #914). The bug already has an open PR, so this is a supporting comment, not a new issue.

---

Reproduced on 0.86.0 (and the fix is still missing from 0.86.1-preview.2) with the JetBrains AI
Chat ACP client (PyCharm 2026.2): at least seven failed turns in one day, and every `srvtoolu_`
id we traced back to its session transcript was an `advisor` call. With this client the failure costs more
than the turn: it treats the `Internal error: Claude ended the turn without returning results for
tool calls: srvtoolu_...` response as non-recoverable, SIGTERMs the agent process and stops its
reconnect loop. From the IDE log:

```
WARN  AcpServerProcessHandlerImpl - [Claude Agent (ACP)] stderr: Session <id>, turn <id>, stopReason=end_turn: Claude ended the turn without returning results for tool calls: srvtoolu_...
INFO  AcpSessionLifecycleManager - Error during prompt turn for chat <id>, error: Internal error: Claude ended the turn without returning results for tool calls: srvtoolu_...
INFO  AcpServerProcessHandlerImpl - [Claude Agent (ACP)] Sending SIGTERM (graceful shutdown)...
FINE  AcpSessionLifecycleManager - handleSessionConnectionFailed for agent=acp.claude-agent-acp, chatId=<id>, recoverable=false, ...
FINE  AcpSessionLifecycleManager - Stopping ACP reconnect loop for agent=acp.claude-agent-acp, chatId=<id>, reason=received non-recoverable session failure, ...
```

On the next prompt the client starts a new agent process that resumes the transcript. Background
subagents that were still running in the killed process reported afterwards that they "didn't
finish before the previous session ended", and their results never arrived.

We ported this PR's change to the compiled `dist/acp-agent.js` of 0.86.0 and fed each advisor
result type through `toAcpNotifications` with the call marked as emitted:

| result type | 0.86.0 | 0.86.0 + this PR |
| --- | --- | --- |
| `advisor_result` | call left unfinished, no terminal update | `completed` |
| `advisor_redacted_result` | call left unfinished, no terminal update | `completed`, ciphertext not rendered |
| `advisor_tool_result_error` | call left unfinished, no terminal update | `failed` |

One thing the PR's test does not model: the advisor docs say that "when the advisor finishes, the
`advisor_tool_result` arrives fully formed in a single `content_block_start` event (no deltas)"
(https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool, Streaming). With
`includePartialMessages`, `streamEventToAcpNotifications` forwards that block to
`toAcpNotifications`, so the new case can run twice per call: once from the stream event and once
from the consolidated assistant message. In a synthetic replay of both orderings the turn still
settles, but the second visit either logs `Got a tool result for tool use that wasn't tracked`
(stream result after the consolidated `server_tool_use`) or emits a second `tool_call` for the
same id (stream result before it). Live, the first ordering is what happens: with the change
installed, the IDE log shows `Got a tool result for tool use that wasn't tracked: srvtoolu_...`
for advisor calls whose result did arrive (44 times in one day). It
may be worth handling the result at one site, or skipping an advisor result whose call is already
settled.

End to end in the IDE, with the change installed, 31 of 31 advisor calls whose result arrived
settled without the client error. The error still fires for an advisor call whose result never
arrives (a steering message while it runs, or a client tool call earlier in the same response):
that is a separate fix, not covered by this PR.
