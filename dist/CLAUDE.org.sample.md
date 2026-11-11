<!--
  CORPORATE POLICY (Level 1, sample / template).

  Kyklos ships its rules in dist/CLAUDE.kyklos.md (Level 0, Kyklos). Your organisation supplies this file (Level 1,
  Corporate) with the organisation-specific facts the Kyklos rules refer to: the name of your push-authorised
  session, the repositories it owns, your secrets manager, and your house rules. Each project adds its own rules in
  its CLAUDE.md (Level 2, Project).

  Keep it in YOUR OWN private Git repository (never in a public-bound one). KyklosLauncher reads it from that
  repository on the host at every launch (settings KYKLOS_CORPORATE_POLICY_URL, _BRANCH, _PATH and _TOKEN_NAME) and
  composes the managed /etc/claude-code/CLAUDE.md from Level 0 and this file. Plain UTF-8, at most 256 KB; nothing in
  it is expanded or run.

  Everything in this file is added after the Kyklos rules. To replace or remove a Kyklos rule, see the last section.
-->

# Corporate policy — <Your Organisation>

Organisation-specific rules (Level 1, Corporate) composed onto the Kyklos rules (Level 0). They fill in the concrete
facts the Kyklos rules leave abstract; a rule they replace is named and marked, never changed silently.

## Roles

- **Push-authorised session.** The baseline's PUSH POLICY leaves "your organisation's designated push-authorised
  session" abstract. Name it here: `<your push-authorised session/role>` is the session that sets
  `KYKLOS_ALLOW_PUSH=1` and owns the shared repositories listed below. Every other session commits + merges +
  deletes its branch locally and lets that session (or a human) push.

## Shared repositories

- `<your shared repository>` — <what it is, and who may push to it>.
- (add one line per shared repository the push-authorised session owns)

## Secrets

- **Secrets manager.** Secrets live only in `<your secrets manager>` (and/or the OS credential store). Reference a
  secret by its name; fetch it in-place at runtime; never write a value to disk, a log, or a message.

## House rules (optional)

- Add any organisation-specific conventions here. They extend the Kyklos rules; to change one, replace it by its identifier (see the header).

## Replacing or removing a Kyklos rule (delete this section in your copy)

Name the rule or section by its permanent identifier (the `kyklos:rule` comment just before it in
`dist/CLAUDE.kyklos.md`) and give a reason. Each block starts at the beginning of a line:

```
<!-- kyklos:replace tier1.commit-after-each-change reason="Our projects commit once per reviewed task" -->
- **Commit after every reviewed task.** <your rule>
<!-- kyklos:end -->

<!-- kyklos:remove testing.repeat-under-load reason="No timing-dependent code in our projects" -->
```

The reason is required, and an unknown identifier refuses the launch, naming the closest valid ones. Every override is
marked where the rule stood and listed under "Overrides in force" at the top of the composed policy. Replacing a rule's
text leaves its Kyklos hook on: the hook keeps its own off-switch, which the launcher names for each override.
