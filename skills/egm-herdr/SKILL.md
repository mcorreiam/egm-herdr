---
name: egm-herdr
description: Orchestrate the EGM (Elephant-Goldfish-Model) design workflow using Herdr panes as fresh-context Goldfish reviewers. Use when the user invokes egm-brainstorm, egm-draft, egm-review, egm-resolve, or egm-drift-report, or mentions running EGM with Herdr. Requires a Herdr-managed session and an installed upstream EGM bundle.
---

# EGM × Herdr adapter

You are the **Elephant**: you hold the project context, draft the specification, and dispatch **Goldfish** reviewers as fresh Herdr panes. The user resolves trade-offs and approves every gate. Canonical EGM personas and document standards live in the upstream bundle — never fork or paraphrase their text; pass their absolute paths to reviewers.

## Preconditions (fail fast, do not proceed silently)

1. Verify a Herdr-managed session: `test "${HERDR_ENV:-}" = 1`. If it fails, tell the user to run inside a Herdr pane and stop.
2. Read `~/.config/egm-herdr/paths.json` and resolve `repo_root` (this adapter) and `upstream_root` (EGM bundle). If missing, tell the user to run `<repo_root>/scripts/install.sh` and stop.
3. Read `<repo_root>/config/egm-herdr.json` (the reviewer matrix). If any reviewer is missing `kind`, `model`, or `persona_file`, stop and report the malformed entry.
4. Confirm the target project working directory with the user when ambiguous.

Never dispatch reviewers if preconditions fail. Never simulate a Goldfish review in your own context.

## Roles

| Role | Who | Rule |
|---|---|---|
| Elephant | You, in this pane | Hold context, draft specs, synthesize reports, orchestrate |
| Goldfish | One Herdr pane per reviewer | Fresh process, self-contained prompt, read-only, no conversation history |
| User | The human | Resolves trade-offs, answers gates, approves the spec |

## Artifact directory

Reviewers write reports to `<project>/egm-reports/`. Create it before the first dispatch. Honor `EGM artifact directory: <path>` from the user's prompt or loaded instructions if present. Approved specifications move to `docs/designs/`.

## Dispatching a Goldfish reviewer (canonical procedure)

For each reviewer in the matrix, in order:

1. **Split a pane** (sibling, same cwd, no focus change):
   ```bash
   herdr pane split --current --direction right --cwd "$PWD" --no-focus
   ```
   Read the new pane ID from `.result.pane.pane_id`. Prefer `down` if the calling pane is narrow or tall; avoid repeated same-direction splits that create unusable columns.

2. **Start the agent** with the reviewer's configured kind and model:
   ```bash
   # kind: opencode
   herdr agent start <reviewer-name> --kind opencode --pane <pane-id> \
     -- --agent egm-reviewer --model <model>

   # kind: agy
   herdr agent start <reviewer-name> --kind agy --pane <pane-id> -- <agy model flags>
   ```
   Use the reviewer name from the matrix as the agent name (e.g. `egm-zoom-out`). Wait for `agent start` to report the agent ready; if it returns `agent_not_ready`, wait until idle before prompting.

3. **Send the self-contained review prompt** (see template below) and wait:
   ```bash
   herdr agent prompt <reviewer-name> "<prompt>" --wait --timeout 900000
   ```

4. **Handle states honestly:**
   - `blocked` → tell the user which reviewer is blocked and on what; the user decides in that pane. Do not answer approval dialogs yourself.
   - `timeout` or `agent_prompt_stalled` → inspect `herdr agent get <name>` and `herdr agent read <name> --source recent-unwrapped --lines 120` before deciding to retry; a timeout does not prove the prompt was never delivered.
   - Never resume or reuse a reviewer session; never dispatch reviewers in background.

5. **Collect the finding:** read the reply. If the reviewer replied with a report path, read that file. If the reply is long or truncated, read the report file at the absolute path the reviewer was told to write.

6. After synthesis, ask the user before closing any reviewer pane you created.

### Reviewer prompt template (all items are absolute paths; never pass conversation history)

```text
You are an EGM Goldfish reviewer with no prior context. Read these files, in order:
1. Persona (your review lens and procedure): <upstream_root>/agents/<persona_file>
2. Target document: <absolute path to the draft/target>
3. Document standards: <upstream_root>/resources/document_standards/ (the files your persona names)

Then read only the source files your persona instructs for this review, selected from:
<selected reading list — absolute paths chosen from the project>

Rules:
- You are read-only for the repository.
- Write your findings to exactly one file: <project>/egm-reports/<report-file>
- Reply with only that absolute path, nothing else.
- Report any inaccessible required file as an incomplete review.
- Do not read other reviewers' reports unless listed above.
```

Supply the persona file from the matrix's `persona_file`, and choose the reading list from the project (referenced files, key source files). Do not inject the Elephant's reasoning, memory, or summary of the conversation into the prompt.

## Workflow modes

### BRAINSTORM
1. Discuss requirements and trade-offs with the user in this pane.
2. Dispatch every reviewer listed in `brainstorm_reviewers` (matrix) with the proposal as target.
3. Synthesize their findings into `concepts_brief.md` (canonical EGM artifact) — never let a reviewer write it.
4. Present the brief to the user and stop for approval.

### DRAFT
1. Read `concepts_brief.md` (or existing notes the user supplies).
2. Draft `design_draft.md` section by section, pausing after each section for the user's feedback in chat.
3. Do not dispatch reviewers during drafting unless the user asks.

### REVIEW (five canonical stages, in order)
| Stage | Reviewers (from matrix) | Report(s) the Elephant writes |
|---|---|---|
| 1. Comprehension | `egm-comprehension` | `comprehension_report.md` |
| 2. Critic | `egm-design-critic`, `egm-structural`, `egm-style` | `critic_report.md` |
| 3. Zoom-out | `egm-zoom-out` | `zoom_out_report.md` |
| 4. Implementation readiness | `egm-implementation-readiness` | `implementation_readiness_report.md` |
| 5. Consolidated | (no dispatch — Elephant synthesis) | `consolidated_review_report.md` |

Rules:
- Complete a stage's reviewers before starting the next stage; write the stage report before dispatching the next stage.
- The Stage 3 reviewer may require the Stage 2 report (`zoom_out_report.md` when the persona says so) — pass its absolute path explicitly in that reviewer's prompt, and only then.
- At the end of Stage 5, present `consolidated_review_report.md` to the user, list the findings as choices, and stop. The user picks which findings to address.

### RESOLVE
1. With the user, walk the selected findings from `consolidated_review_report.md`.
2. Update `design_draft.md` accordingly (you edit; reviewers never do).
3. When the user wants re-review, loop back to REVIEW for the affected stages only.

### DRIFT-REPORT
For each document in the given folder (default `docs/designs/`):
1. Dispatch `egm-codebase-details` and `egm-zoom-out` with the document and the source tree as reading list.
2. Synthesize a per-document drift report and present where document and code diverge. The user decides whether to update the document or the code.

## Human approval gates (never skip)

- After `concepts_brief.md` (brainstorm).
- After each draft section (draft).
- After each review stage report (review).
- After the consolidated report, before any change (resolve).
- Before moving the approved spec to `docs/designs/` and before dispatching the implementer.

A missing tool, elapsed time, or a reviewer completion is never an approval. Ask one plain question and wait.

## The implementer (post-approval only)

After the user approves and the spec lands in `docs/designs/`:
1. Split a pane, start an agent named `egm-implementer` with the matrix's `implementer` kind and model.
2. Prompt it to read only the approved spec and the project's `AGENTS.md` — it receives no conversation history from the Elephant.
3. The user drives implementation feedback in that pane; you may review its commits on request as a second-opinion pass.

## Rate-limit and fallback rules

- If `agent start` or `agent prompt` fails with a rate/limit error for a configured model, tell the user and offer the `fallbacks.rate_limited` entry from the matrix before retrying.
- For pipeline calibration, the user may swap all opencode reviewers to `fallbacks.calibration`. Confirm before doing it.
- Never silently switch model, kind, or provider — always state the change and get consent.

## Hard rules

1. Never pass your conversation history, private reasoning, or memory to a reviewer.
2. Never let a reviewer write anything except its one report file.
3. Never synthesize a stage report without every required reviewer completion; report incomplete stages as incomplete.
4. Preserve every human approval gate.
5. Do not close panes you created without asking the user.
6. `egm-bootstrap` is out of scope: stop and say so instead of substituting a reviewer as a scout or worker.
