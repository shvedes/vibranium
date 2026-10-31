# NN - Example spec skeleton

Use this template only for work that is genuinely hard, fragmented, or complex,
or that needs cross-session continuity. Do not create a spec for a
straightforward task that can be planned, delegated, and verified in the
current session.

A filled template to copy. Every section below is required in every spec.
Bracketed text is what the development lead writes; keep the headings
verbatim. A spec records the plan; it does not replace a complete worker
prompt. Each delegated worker is a capable developer: give it the decisions
and load-bearing code, not a reprint of the files it will edit.

## Files

- `shell/widgets/Bar/Module/Module.qml` - the only file touched for this spec

## Current code

[Literal snippet from the worktree, with a line anchor. Never paraphrase a
binding - quote it exactly so the delegated worker can paste-match.]

    Module.qml:41:

      visible: root.active && root.text !== ""

## Root cause

[One paragraph, grounded in the quoted code. For a binding loop or a snap:
show which properties feed each other.]

## Implementation

1. [File, where] - add a property after the existing `maxWidth`:

       property int delay: 300

   [What it does, in one line.]

2. [File, where] - replace the `visible` line above with:

       visible: root._show && root.text !== ""

   [Why: `_show` is armed by the timer in step 1, so the surface now waits.]

## Verification

- `qmllint shell/widgets/Bar/Module/Module.qml` - no errors.
- [Behavioral check with the restart workflow from the
  `vb-dev` skill: what to do in the running shell and what
  "pass" looks like.]
- [Edge case check: what must NOT regress.]

## Gotchas

- Do NOT [touch something adjacent / rename the property contract / open the
  shared primitive's consumers].
- Keep [a specific condition, e.g. `text !== ""`] in `visible` - it is
  load-bearing.
- ASCII only in comments (`->`, never U+2014).
