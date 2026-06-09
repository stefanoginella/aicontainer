// =============================================================================
// aicontainer OpenCode guardrail — thin shim over the shared PreToolUse hook
// =============================================================================
// Root-owned, baked into the image at /etc/aic/hooks/opencode-guardrail.js and
// referenced from the generated ~/.config/opencode/opencode.json via
// `"plugin": ["/etc/aic/hooks/opencode-guardrail.js"]` (the plugin: config key
// accepts absolute local paths). This is OpenCode's slice of the SAME guardrail
// Claude Code and Codex use: it translates OpenCode's
// tool.execute.before(input, output) into the JSON that
// /etc/aic/hooks/pre-tool-use.sh reads on stdin, so all three tools share ONE
// source of truth (the .env / curl|sh / self-protection rules live only in that
// script). Exit 2 from the script == block; we surface its stderr by throwing,
// which OpenCode reports back to the model.
//
// Dependency-free on purpose — node builtins only (no npm imports): the plugin
// dir is not an npm project and the image quarantines npm. Runs under OpenCode's
// Bun runtime, which supports node:child_process.
//
// Defense-in-depth, not the primary boundary (that's container isolation + the
// socket-proxy + RO mounts). Loading is what matters: it fires even with
// `permission: {"*": "allow"}` because OpenCode runs plugin hooks regardless of
// the permission gate.
import { spawnSync } from "node:child_process"

const HOOK = "/etc/aic/hooks/pre-tool-use.sh"

// OpenCode tool name (lowercase) -> the capitalized tool_name that
// pre-tool-use.sh dispatches on (its `case "$tool"`). Tools not in this map are
// passed through untouched (webfetch, list, task, etc. — same scope as the
// Claude/Codex matcher, which only covers Bash/Read/Edit/Write/Grep/Glob).
const NAME = {
  read: "Read",
  edit: "Edit",
  write: "Write",
  bash: "Bash",
  grep: "Grep",
  glob: "Glob",
}

export const AicGuardrail = async () => ({
  "tool.execute.before": async (input, output) => {
    const toolName = NAME[input?.tool]
    if (!toolName) return

    // Map OpenCode's args to the fields the shared script reads:
    //   bash       -> .tool_input.command
    //   read/edit/write -> .tool_input.file_path  (OpenCode: args.filePath)
    //   grep/glob  -> .tool_input.path            (the search root, mirrors
    //                 Claude's Grep/Glob handling — a path at a secret file)
    const a = (output && output.args) || {}
    const toolInput = {}
    if (typeof a.command === "string") toolInput.command = a.command
    if (typeof a.filePath === "string") toolInput.file_path = a.filePath
    if (typeof a.path === "string") toolInput.path = a.path

    const event = JSON.stringify({ tool_name: toolName, tool_input: toolInput })
    const res = spawnSync(HOOK, {
      input: event,
      encoding: "utf8",
      timeout: 30000,
    })

    // Fail-open only if the script genuinely could not run (missing/unexecutable
    // — a build bug the smoke tests catch, not a runtime threat). A clean exit 2
    // is the block signal; anything else (0, or a non-2 error) allows.
    if (res && res.status === 2) {
      const msg = (res.stderr || "blocked by aicontainer guardrail").trim()
      throw new Error(msg)
    }
  },
})
