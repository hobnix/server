import { Plugin } from "@opencode/plugin"
import { execFile } from "node:child_process"

// OpenCode equivalent of the Claude Code SessionStart hook (.claude/settings.json): injects the repo
// orientation from scripts/dev/session-context.sh --plain (branch, open TODO.md items, last test log,
// specs in progress) into the first model request of a session. Zero tool calls. Subagent sessions are
// skipped (they bring their own task prompt); after a server restart the context is injected again,
// like a Claude Code resume. Keep the output small: it is paid for once per session.

const SUBAGENTS = new Set([
  "general",
  "explore",
  "architect",
  "coder",
  "implementer",
  "tester",
  "reviewer",
  "docs-writer",
])

function sessionContext(cwd: string): Promise<string> {
  return new Promise((resolve) => {
    execFile(
      "bash",
      ["scripts/dev/session-context.sh", "--plain"],
      { cwd, timeout: 10_000, windowsHide: true },
      (error, stdout) => resolve(error ? "" : stdout.trim()),
    )
  })
}

export default Plugin.define({
  id: "hobnix.session-context",
  async setup(ctx) {
    const seen = new Set<string>()
    await ctx.session.hook("context", async (event) => {
      if (seen.has(event.sessionID) || SUBAGENTS.has(event.agent)) return
      seen.add(event.sessionID)
      const text = await sessionContext(ctx.location.directory)
      if (text) {
        event.system.push({
          type: "text",
          text: `<session-context>\n${text}\n</session-context>`,
        })
      }
    })
  },
})
