# Spilled tool output: read by handle, stored per task

Status: implemented 2026-11-24.

## Problem

A tool result over `ToolResultCap.maxCharacters` is cut to a preview and the full text is saved to a
file. The preview named that file's path and told the agent to `file_read` or `grep` it.

On 2026-11-24 a worker on a task whose user-written rule was "any read outside
`/Users/andrew/ideas/v1/720` is an immediate ABORT" got a 140,556-character `glob` result. It
followed the instruction, grepped the overflow directory, and the Security Agent aborted the run.
The verdict was correct for what the Security Agent was shown: the app sent the worker outside the
boundary, and nothing told the Security Agent the path was the app's own.

Two defects:

1. Saved output was addressed by filesystem path, so reading it back was a filesystem read like any
   other, judged against the task's path rules.
2. Every task, session and validator shared one flat directory. The worker grepped the whole
   directory, which would have read other tasks' saved output.

## Decisions (user, 2026-11-24)

- Saved output is read back **by handle** through a built-in tool, `read_tool_output`. The capped
  text names the handle and never a path.
- Saved output is stored **per task**: `$TMPDIR/AgentSmith-tool-output/<task-id>/`.
- The existing `ToolResultCapTests` may be updated to locate the saved file by handle.

## Design

- `SpilledToolOutputStore` (`Utilities/`) is the one owner of where saved output lives and the one
  reader and writer of it. `forTask(_:)` gives `<root>/<task-id>/`; an agent with no task (Smith)
  gets `<root>/agent-<agent-id>/` through `forAgent(_:)`. A handle is a UUID; the store builds the
  file name from the parsed UUID, so a handle cannot name a path.
- `ToolContext.spilledToolOutputs` carries the store. The cap (`AgentActor`, `EvaluationRunner`)
  writes through it and `read_tool_output` reads through it, so both always agree.
- A worker and the validators of the same task share that task's folder. A validator only ever
  learns handles from its own results.
- `TaskWorkspace.cleanupTemporary()` removes the task's saved output with the task's scratch.
- `read_tool_output(handle, startingLineNum?, maxLines?, pattern?)`:
  - Without `pattern`: returns lines `startingLineNum ..< startingLineNum + maxLines`.
  - With `pattern` (regular expression): scans from `startingLineNum` and returns only matching
    lines; `maxLines` counts matches. So filtered output pages exactly like unfiltered output.
  - Every response that is not the end states the `startingLineNum` to resume from.
  - A response is bounded below the cap, so reading saved output never spills again.
  - A line longer than `maxLineCharacters` is split into consecutive numbered lines, so every
    character of a one-line result (minified JSON) is reachable.
  - The store returns only regular files it finds under a handle's name; a symbolic link planted
    in the folder is not followed.
- Access:
  - Offered to Brown, Smith and validators that have evidence tools.
  - `ToolPolicy.workerToolsApprovedByDefault` — a worker has it whatever tool scoping decides, the
    same standing as `save_memory`. A global Never or per-task Off still removes it.
  - `SecurityEvaluator.autoApprovedToolsByRole` for all three roles: the content was approved when
    the original call was, and the store limits a caller to its own folder.
- `glob` output no longer escapes `/` as `\/` (`.withoutEscapingSlashes`), which shrinks results.

## Not done, by decision

- No pre-approval for `file_read`/`grep` on the saved-output folder. The agent is never given the
  path.
- Files in the old flat directory are left for the operating system to clear.
- Folders of agents with no task are not removed at agent stop; the operating system clears them.

## Validation

1. Regression test written first and shown to fail before the change: a capped result must not
   contain the overflow directory's path (`ToolResultCapTests`, failed 2026-11-24 against the old
   code).
2. `ToolResultCapTests`: under-limit unchanged; over-limit preview plus byte-identical saved text
   found by handle; multibyte; distinct handles; write-failure fallback; no path in capped text.
3. `SpilledToolOutputStoreTests`: per-task and per-agent folders; one task cannot load another's
   handle; unknown handle; `removeAll`; `TaskWorkspace.cleanupTemporary` removes saved output.
4. `ReadToolOutputToolTests`: paging; resume cursor; pattern paging by matches; long-line splitting;
   output stays under the cap; bad handle, unknown handle, bad pattern, start past end; empty
   optional arguments read as absent; role availability.
5. Wiring tests: auto-approved for Brown, Smith and validator; approved by default for workers and
   removable by Never; classified read-only, not destructive, not open-world; has a tool group.
6. Full package suite passes; the app builds with no new warnings.

## Review fixes (2026-11-24)

An independent review of the first commit found three defects, each fixed test-first:

1. A page counted only line text toward its ceiling, so a page of short or blank lines exceeded
   the cap and spilled again. The ceiling now counts each line as sent (number prefix, line break).
2. `ToolPolicy.effectiveApprovedTools` held its base to the candidates at the start, which dropped
   a companion tool's principal when the task tool editor asked about the companion alone. The
   result is now held to the candidates at the end.
3. The store followed a symbolic link planted in a task's folder.

Known and left: a model-written `pattern` can backtrack exponentially (`GrepTool` has the same
exposure); a non-integer `maxLines` falls back to the default.
