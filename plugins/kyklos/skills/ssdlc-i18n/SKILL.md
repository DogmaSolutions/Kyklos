---
name: ssdlc-i18n
description: Perform the internationalization pass for the ssdlc-story-proof i18n dimension — find every user-facing string a development story added or changed (labels, GUI text, validation and exception messages, API messages), and promote it into the project's existing, centralized i18n resources without duplicates. Use when the i18n row is UNPROVEN, before closing a kind::development story, or when asked to internationalize strings.
user-invocable: true
---

# ssdlc-i18n — promote user-facing strings into i18n resources

The **doer** for the [`ssdlc-story-proof`] **i18n** dimension (which is only the *auditor*). Every text a story
adds or changes that can reach a user — through the GUI or through an API — ends up as a reference to a
centralized, deduplicated internationalization resource, not as a hardcoded literal.

## When it applies

- Only **`kind::development`** stories carry the i18n row. Analysis, documentation and ops stories do not.
- The row can **never be `NOT_PERTINENT`** on a development story. A change with no user-facing strings still
  proves it: run the scan and record `Candidates 0 / Promoted 0 / Ignored 0`, citing the scanner.
- Scope is the code the story **wrote or changed on its branch** — not the rest of the codebase.

## What is a candidate, what is not

**Candidates** — text that can reach a user: GUI labels, captions, descriptions, tooltips, validation messages,
exception messages, messages returned by an API, notifications.

**Excluded** (never promoted — each ignored candidate records which rule applied):

- **Log messages** — anything passed to a logger or trace call.
- **Strings that drive business logic** — values compared in `if`/`switch`, switch labels, lookup/configuration
  keys, dictionary keys, attribute arguments, protocol tokens.
- **Script files** — sh, ps1, bat, cmd and the like are out of scope entirely.
- **Agent-facing messages** — text a tool, gate, hook or MCP server returns to an AI agent or to developer tooling,
  never shown in an end-user GUI or returned in an end-user API response: proof-gate findings, close refusals, guard
  block reasons, tool and MCP error results, CLI diagnostics of developer tools.
  *Excluded:* a proof gate's `"metrics do not add up: Promoted 4 + Ignored 2 = 6, but Candidates is 7"`, a bridge MCP
  tool's `"no scanner for: view.ts"`, a hook's block reason.
  *Still a candidate:* the same kind of sentence when it reaches an end user — a web API's
  `"The order quantity must be positive."` in a validation response, or a desktop app's error dialog text.
  The test is who reads it, not how it is produced: the same `throw new ArgumentException("…")` is agent-facing in a
  gate and user-facing in an application. That cannot be decided from the literal alone, so the scanner reports these
  as CANDIDATE and you classify them.

Technical literals with no human text (separators, format-only strings, URLs, file names) are not candidates either.

**Project exclusions.** A project may exclude a further category, decided by the user and recorded in its
`CLAUDE.md` under `## i18n` as `- **i18n exclusions:** …` (for example, diagnostics a tool returns to agents rather
than to people). `--detect` prints it as `exclusions=`. Apply it exactly like the rules above: a matching candidate
is Ignored, with the recorded exclusion as its reason. Only the user adds or widens an exclusion; never record one
on your own to make a count come out.

## Procedure

1. **Know the technique — never guess.** Read the project's `CLAUDE.md` for a recorded decision
   (`- **i18n technique:** …` under `## i18n`). If none is recorded, detect what the code already uses:

       bash "$CLAUDE_PLUGIN_ROOT/skills/ssdlc-i18n/scan-strings.sh" --detect --repo <source-root>

   `technique=resx` (RESX + generated `Resources` class) or `technique=IStringLocalizer` → keep using it, do not
   introduce a second system. `technique=both` or `none` → **ask the user once** which to use (for C#: classic RESX
   or `IStringLocalizer`, and where the resources live: one global location or one per module), then **persist the
   answer** in the project's `CLAUDE.md`:

   ```markdown
   ## i18n
   - **i18n technique:** RESX (Properties/Resources.resx, one per project)
   ```

   The next run reads that line and does not ask again.

2. **Find the candidates mechanically.** Do not spend tokens on ad-hoc greps. For C#, the shipped scanner lists
   every literal on the lines the branch changed, with log, logic, key, attribute and technical strings already
   pre-excluded:

       bash "$CLAUDE_PLUGIN_ROOT/skills/ssdlc-i18n/scan-strings.sh" --repo <source-root> [--base <trunk-ref>]

   It prints `<file>:<line>  CANDIDATE|EXCLUDED:<reason>  <literal>` and the tally on stderr. It exits **3** when the
   change touches a language it cannot read (TypeScript, Razor, XAML, Python, …): then **build a scanner for that
   language first**, keep it in the project's tooling so the next story reuses it, and cite it in the metrics.

3. **Judge each CANDIDATE by meaning.** The scanner is a pre-filter; you decide. A candidate is **promoted** when an
   end user can see it, or **ignored** with the exclusion rule that applies: a logic-driving value, a key, a log
   message, an **agent-facing message** (decide by who reads it — see the exclusions), or text that never leaves the
   code at all (test assertions and fixtures). Count them: `Promoted + Ignored` must equal `Candidates`.

4. **Deduplicate before adding.** For every string to promote, look for an existing resource with the same text in
   the correct scope first, and reuse its key:

       bash "$CLAUDE_PLUGIN_ROOT/skills/ssdlc-i18n/scan-strings.sh" --find "Save changes" --repo <source-root>

   Deduplicate in the **scope the project uses** — the global resource file, or the module's own one — never across
   modules that keep separate resources. Only add a new key when nothing equivalent exists; name it for its meaning,
   not its current wording.

5. **Promote.** Replace each promoted literal with the resource reference in the project's technique (for RESX: add
   the entry to the `.resx`, use the generated `Resources.<Key>`; for `IStringLocalizer`: `localizer["<Key>"]` with
   the entry in the resource file). Keep formatting placeholders in the resource (`{0}`), not in code. Build and run
   the tests — behaviour must not change.

6. **Record the proof.** The three metrics are mandatory, each citing the tool that produced it:

       story proof <id> --set "i18n=PROVEN|<what was promoted, and why each ignored one was ignored>|<kbd>Candidates (scan-strings.sh):</kbd> 7<br><kbd>Promoted (scan-strings.sh + review):</kbd> 5<br><kbd>Ignored (scan-strings.sh + review):</kbd> 2"

   The close gate checks the three metrics and their sum (the row's rules are in [`ssdlc-story-proof`]). A story
   whose proof table was written before this dimension existed gets the row added in place by the next
   `story proof <id> --set`.

## Scope limits

- Translating resources into other languages is out of scope; so is internationalizing code the story did not touch.
- The scanner reads single-line C# literals; a literal split across lines, or text built from pieces at run time, is
  judged by reading the change itself.
