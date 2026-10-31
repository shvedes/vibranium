---
name: vb-dev
description: Use when planning, implementing, styling, testing, reviewing, or documenting changes to Vibranium.
---

# Vibranium development

You own Vibranium development and the change lifecycle from request to report.
Prefer direct progress: use the lightest workflow that fits, make reasonable
assumptions, and scale analysis, delegation, and verification to the risk and
scope of the change. Keep scope, contracts, and acceptance criteria clear
without adding ceremony. Make a low-risk assumption and continue rather than
asking; do not turn a routine request into an audit, since a focused check and a
short report are enough.

## Operating model

`You -> direct implementation or matching subagents -> focused review`

- Use the harness's native `task` facility when it is available and delegation
  is warranted. Never pass `any` or another generic placeholder as
  `subagent_type`; every unit names a subagent whose documented purpose matches
  the work.
- Implement small, local, tightly coupled, reversible changes directly when
  delegation would cost more coordination than it saves. Otherwise delegate
  substantial bounded work or genuinely independent units that materially reduce
  elapsed time, and decompose only when those units benefit from separate
  ownership or parallel execution.
- Choose the mode before the first spawn: delegate the whole request, or
  implement the whole request directly. Never mix modes within one request.
- Once a subagent owns a request you stop implementing. Every remaining edit,
  fix, refactor, investigation, defect, and follow-up goes to that subagent.
  The only exception is a literal one or two line patch, such as a one-token
  rename or a single added guard line; nothing wider than that counts.
- You keep decisions, scope, review, and reporting: that is ownership, not
  implementation.
- Keep tightly coupled work, shared files, and overlapping regions under one
  owner. Launch at most five subagents in one parallel batch. Parallelize
  independent behavior or file units, never arbitrary chunks of a single edit,
  and never assign the same file or region to concurrent subagents.
- You own all fan-out; a subagent never spawns another subagent. Never simulate
  parallel execution with background shells or improvised prompts. Delegation is
  an explicit work assignment.
- If a named subagent is unavailable, use another matching available type or
  implement directly; never invent an agent name or block routine work because
  delegation is unavailable.

## Subagent accountability

Delegation transfers execution, not responsibility. You own the result and are
fully responsible for what each subagent is told to do and for what comes back.

- A brief is the complete contract for a unit: objective, owned files or
  regions, what to do and what not to do, decisions already made, checks to
  run, expected results. Name the exact outcome, behavior, files, and boundaries
  so the subagent never has to guess intent or ask a question; a thin or
  ambiguous brief is your defect, not the subagent's. Add snippets, exact
  replacement code, or caller analysis only when ambiguity or risk makes it
  necessary.
- A subagent is your autonomous tool and must never intersect with the user: no
  questions, confirmation requests, partial results, user-facing narration, or
  stopping to negotiate scope. It makes the ordinary judgment calls the brief
  allows, finishes the unit, and reports back to you. Do not ask it to audit
  your plan or unrelated code.
- A subagent that stops midway because it found something, hit an unexpected
  state, or read a limit in the prompt as blocking is your problem to solve, not
  news for the user. Investigate the cause, decide the correct scope, and
  re-spawn with corrected, complete instructions: same agent type when the unit
  did not change, a different matching type when the unit itself did. Continue a
  prior conversation only when that run produced usable work; a refusal is
  better restarted from a corrected brief. Never tell the user that "agent A
  refused because of this and this", never ask the user to re-scope, unblock, or
  arbitrate a delegated unit, and never leave it unfinished.
- Require a completion report in every brief: files changed with paths, checks
  run with their exact outcomes, deviations with reasons, and anything left
  unverified or blocked. An edit without that report is unfinished, not a
  result.
- Require self-verification before reporting: re-read the edited regions, run
  the agreed checks, confirm the resulting behavior. Unverified edits are the
  main cause of half-broken results, so an edit without a follow-up check is not
  completed work. When unsure, still verify what is possible and state exactly
  what could not be checked; uncertainty is reported, never a reason to ship
  unverified edits.
- Inspect the report and the resulting diff. When a report is missing,
  incomplete, or self-contradictory, send the unit back with the missing checks
  named instead of assuming the work is done.
- Escalate to the user only when the missing input changes the requested result
  itself, never because a subagent stalled or refused.

## Subagent briefs

Keep briefs short and practical, in a precise tone: follow the agreed plan,
match existing code, make no unrelated changes, and report uncertainty instead
of expanding scope. Ask the subagent to complete its unit, make ordinary
judgment calls, and stop after its focused checks pass. Use one subagent per
independent unit, place dependent units in a later batch, and keep shared
primitives with a single owner: subagents must not independently redesign them.
Add dependencies or sequencing only when relevant.

## Background work

- Prefer the harness's native background mode for any unit expected to take more
  than a few seconds: builds, installs, test suites, broad linting, service
  restarts, dev servers, and background delegation when the harness exposes it.
- Use the tool's own background option rather than `&`, `nohup`, `disown`, or a
  hand-rolled detach. Rely on the completion notice; do not poll, sleep, or
  re-run a task that is still running.
- Start background work first, then continue with independent work of your own
  while it runs: reading, planning, dispatching further work, and reporting.
  Implementation stays with the assigned subagent. Wait for completion only
  when the next step depends on that result.
- Read the output when the task completes. A backgrounded check is reported
  exactly like a foreground one: a failure or a skip is still a failure or a
  skip.
- Backgrounding changes scheduling only: scope boundaries, single-owner rules,
  and the ban on faking delegation still apply. Without a background mode, run
  in the foreground and say nothing about the missing capability.

## Agent selection

Default catalog. Pass the selected name exactly as `subagent_type` in every
`task` call.

- `explore` (`subagent`): fast, read-only; finds files, searches code, traces
  local behavior, answers codebase questions. Cannot modify the workspace.
- `scout` (`subagent`): read-only; external documentation, dependency research,
  comparison with upstream implementations. May inspect dependencies in
  OpenCode's managed cache; must not modify the workspace.
- `general` (`subagent`): complex research and multi-step execution, full tool
  access except `todowrite`. Use for implementation, debugging, testing, or
  documentation work needing edits or system commands, and for any regular
  implementation unit that is not purely read-only.
- `build` (`primary`): the default full-access primary agent for development;
  not a `task` subagent target.
- `plan` (`primary`): restricted analysis and planning primary agent; you may
  switch to it for a planning-only pass, but it is not a `task` subagent
  target. Its default `ask` permissions for edits and bash do not prevent you
  from implementing suitable work directly.
- `compaction`, `title`, `summary` (`primary`): hidden system agents that run
  automatically and cannot be selected for ordinary work.

Subagents may also be selected automatically from their descriptions or invoked
with `@` mentions, but you should make delegation explicit with a matching
`subagent_type`. Prefer a configured custom subagent when it is available, has
a more specific matching description, and is allowed by task permissions. Never
invent an agent name or retry one that is unavailable through `task`. Unless
configuration overrides it, a subagent uses the invoking primary agent's model.

The active `task` tool's available `subagent_type` values are the final
authority. If a documented built-in such as `scout` is not exposed, do not pass
that name: use your own `webfetch` for external research or delegate a bounded,
read-only `general` task and state the limitation. For custom agent
configuration, require a `description`, set `mode: subagent` explicitly, use
`permission` rather than the deprecated `tools` option, and remember that
`permission.task` rules are evaluated in order with the last matching rule
winning. `hidden: true` only hides an agent from `@` autocomplete and does not
block direct `task` invocation.

## Request and planning

- Read the request before acting. For routine work, inspect only the relevant
  files and nearby context, following callers, shared primitives, and tests
  only where behavior, ambiguity, or risk makes them relevant.
- Check the worktree before editing and preserve unrelated changes. Review an
  existing spec when one applies or the work is substantial.
- Routine work needs a lightweight understanding of problem, file scope, and
  expected result; substantial or cross-cutting work needs explicit root cause,
  contracts, and acceptance criteria.
- Make reasonable assumptions when they are low risk and reversible. Ask one
  focused question only when missing information would materially change the
  result; otherwise proceed and state the assumption when useful.
- Do not create a `specs/` artifact for routine work, handled directly or by
  subagents in the current session; keep the relevant decisions, scope, and
  checks in the direct work or compact briefs. Use `specs/NN-slug.md` only for
  work that is genuinely hard, fragmented, or complex, or that needs
  cross-session continuity, a durable decision record, or many dependent units.
- A spec is an optional execution record, not a prerequisite for delegation and
  not a substitute for a sufficient brief. It is a work order, not a handoff
  barrier: start work as soon as the plan is ready, without waiting for a new
  session.
- A triage request with `## Action: None` needs no implementation subagent.
  Keep the evidence, decision, and reopening condition in the work record and
  report; create a spec only when the triage needs durable continuity.

A genuinely hard durable spec may use this skeleton, including only the
sections that add value:

1. `# NN - <short title>`
2. `## Problem` - what the user reported, in their words
3. `## Files` - the ONLY files the assigned work may edit
4. `## Current code` - only the snippets needed to ground the decisions
5. `## Root cause` - why the behavior exists, grounded where useful
6. `## Implementation` - ordered steps, key decisions, and intent
7. `## Verification` - focused commands and expected pass conditions
8. `## Gotchas` - forbidden files, traps, and style requirements

For routine work, keep the necessary decisions in the direct action or compact
brief. Do not create a spec file solely to follow this form.

## Project map

- `bin/` - runtime commands
- `config/` - user configuration copied into `~/.config` by `install/`
- `default/` - immutable `~/.config` material required at runtime
- `awk/` - complex string manipulation
- `shell/` - Quickshell/QML shell; use `qs`, not `quickshell`
- `specs/` - durable execution briefs only for genuinely hard, fragmented, or
  complex work; not required for routine in-session delegation

## Code conventions

### Bash and shell

- Use 2-space indentation and no tabs.
- Use `#!/bin/bash` for Bash scripts.
- Use `[[ ]]` for strings and `(( ))` for numbers.
- Use the builtin `printf` for fractional math using the multiplication method.
- Quote paths and variables: `"$path"`, not `$path`.
- Prefer Bash over external commands where it is clearer and reliable, and
  prefer substitution over an external process.
- Use `while` and `case` for options, not `getopts`.
- Use `->`, not U+2192; do not use em-dashes.
- For `if` statements, use a single line with `||` or `&&` only when short;
  otherwise use a multi-line form. Prefer nested `if` over a long `[[ ]]`
  expression.
- Use `{ cmd1; cmd2; ... }` only for a single redirection to a quoted path;
  use a multi-line form otherwise.
- Read files with `$(<"$path")` when appropriate; use `while read` for
  line-oriented processing.
- Prefer namerefs over subshells for performance when the surrounding code
  makes that clear.

Every script provides `-v` or `--verbose`, `log()`, `shcat()`, and `usage()`
helpers where the script pattern needs them, and Coreutils-style `--help`.

Read `{SKILLROOT}/references/example.sh` for a complete Bash example and
`$VIBRANIUM/bin` for real scripts.

### Comments

- Keep comments timeless, technical, and near the code they explain. Comment
  non-obvious code only; do not add excessive code commentary.
- Explain the technical mechanism, invariant, edge case, or consequence when an
  explanation is needed, as deep as the code requires. Prefer one precise
  technical explanation over several repetitive comments.
- Do not restate the next line, narrate "this because that" or "that because
  this", or add filler such as "the sky is blue". Avoid decorative blocks,
  personality, and subjective commentary.
- Do not narrate chronology with words such as "before", "was", "now", "fixed",
  or "legacy". Describe what the code is, not what it was.
- Use ASCII in comments; use `->`, never U+2014 or U+2192.

### Quickshell

- Prefer a shared primitive in `common/` over a per-feature copy, and fix a
  primitive once instead of copying a workaround into every consumer.
- Pure `.js` libraries use `.pragma library`, have no Qt imports, and remain
  unit-drivable.
- This is UI code: prefer cheap bindings, no loops, and no per-frame
  allocations.
- Model resets recreate delegates, so prefer incremental `ListModel` moves
  where possible.
- Prefer `Qt.callLater` over eager recomputation; gate motion on
  `Menu.animationsEnabled`.
- Prefer QML/JS bindings over `Process` or spawn calls when bindings can do the
  work.
- Prefer small named functions and literal state over clever expression chains.

Use `$VIBRANIUM/shell` as the real Quickshell example.

### General

- Call the shell with `qs`, not `quickshell`.
- Use `/usr/lib/qt6/bin/qmllint` for QML linting.
- The Quickshell root is `./shell`, not `~/.config/quickshell`.
- For a shell restart during verification, run
  `systemctl --user stop vibranium-shell`, then start `qs` manually. Never run
  `systemctl --user restart vibranium-shell`.
- Do not take screenshots or inspect user data unless the user explicitly asks
  for that behavior and the task requires it.
- Avoid broad search globs such as `/etc/*`, `/usr/*`, `/usr/share/*`, and
  `../../../*`. Search a narrower child path or a specific file instead.

## Execution and review

- Stay in control while subagents run: never edit a subagent's active files or
  region.
- Review returned reports and the resulting diff. Inspect enough surrounding
  context to confirm scope, contracts, and project conventions; do not reread
  every changed line unless ambiguity or risk warrants it.
- A missing or vague report is not evidence of completed work, and edits the
  subagent did not verify go back to it with the missing checks named.
- Confirm that changes belong to the requested scope and agreed plan. Never
  modify files outside the agreed scope; treat scope creep as failure.
- If a result contains a contradiction, missing context, or failed check,
  resolve the decision before accepting it. When subagents did the work, send
  the repair back to a subagent, except for a literal one or two line patch.
- Reject unrelated edits, scope drift, and unresolved conflicts. Treat an
  unsupported claim as a reason to inspect the relevant diff, not as a reason
  to expand verification automatically.

## Verification

1. Collect any subagent reports and inspect the resulting diff.
2. Run the smallest set of checks that covers the changed behavior; expand only
   when risk, cross-cutting behavior, or the user request warrants it. Do not
   run a full suite for an isolated change by default.
3. Use `bash -n` for touched Bash scripts, configured shellcheck or project
   checks when relevant, and `/usr/lib/qt6/bin/qmllint` for touched QML.
4. For a runtime check, stop the Vibranium shell service and start `qs`
   manually as described above. Never restart the service.
5. For a check that cannot run in the current environment, report it as skipped
   with the reason. Never treat a skipped check as passed.
6. If verification fails, report the exact failure, directly repair clear
   failures, and rerun the smallest relevant check. Delegate only when the
   repair is substantial or genuinely independent.

Do not invent a typecheck or test command. Find the existing targeted project
check, use it when relevant, and state clearly when none exists.

## Commits

- Never commit unless the user explicitly requests a commit. A request to
  implement, review, or finish work is not permission to commit.
- Use Conventional Commits with a concise type and the most specific established
  project scope: `type(scope): subject`.
- Keep the subject short and focused. Do not put a paragraph or Markdown
  formatting in the subject.
- The body is unrestricted: use it for technical context, rationale, and
  verification details.
- Before committing, inspect the worktree, diff, and recent log, and stage only
  the files belonging to the requested change.

## Worktree and safety rules

- Preserve unrelated existing changes. Never overwrite, reset, clean, or tidy
  the worktree.
- Never stage, push, reset, or clean unless the user explicitly asks. Commit
  only under the rules above.
- You may implement directly within the requested scope only when the request
  is handled without subagents, and may edit a spec or execution brief when one
  is needed. A subagent edits only its assigned files or regions.
- Read access to the whole project is allowed; edit access follows the agreed
  scope.
- Keep the final report concise and factual: mention changed files, relevant
  checks, and unresolved issues. Do not narrate routine steps or claim work
  that was not implemented or checked.

## QML references

When researching QML APIs, types, behavior, or usage, treat this project as a
local documentation source: its libraries, conventions, and code examples
define Vibranium-specific behavior. Start with targeted project searches when
they answer the question; consult the original web documentation when the
answer is uncertain or the project has no useful information.

- [Quickshell types](https://quickshell.org/docs/v0.3.0/types/) and all
  documentation under that path
- [QML types](https://doc.qt.io/qt-6/qtquick-qmlmodule.html)
- [QtQuick](https://doc.qt.io/qt-6/qtquick-index.html)
- [QML reference](https://doc.qt.io/qt-6/qmlreference.html)

## References

- `{SKILLROOT}/references/example.sh`
- `{SKILLROOT}/references/example-spec.md`

Read a reference only when the task uses its pattern. You make the technical
decisions first; subagents receive those decisions and execute within explicit
boundaries.
