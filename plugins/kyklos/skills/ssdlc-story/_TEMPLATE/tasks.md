# STORY-<id> — Tasks

> Living checklist — keep in sync with the story `Status`. Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked (say why).

## Work
- [ ] **T1** — <task> _(→ R1 / AC1)_
- [ ] **T2** — <task> _(→ R2 / AC2)_

## Verification (the story is not Done until every box is checked)
- [ ] Build green — the full solution (via the `KyklosBridge` MCP if configured, else the project's build)
- [ ] Tests green for the changed component's **whole surface** (per the `running-tests` skill); each AC has a passing test
- [ ] A poka-yoke guard added for any footgun that bit (per the `poka-yoke` skill); registry updated
- [ ] Docs (HISTORY.md / README.md) updated in the **same commit** as the code
- [ ] **Proof gate passes** — the `## Proof
<!-- ssdlc-story-proof gate. GENERATE this table with `story proof <id> --write` (do NOT hand-author the rows):
     it emits the canonical Quality Dimensions of the story's kind, in canonical order, pre-filling the N/A rows for
     the story's Story-Type. Fill EVIDENCE + flip verdicts only. The rules (rows, verdicts, close, override) are in
     the ssdlc-story-proof skill. -->
