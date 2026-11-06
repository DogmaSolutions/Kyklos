<!--
  ORGANISATION LAYER (sample / template).

  kyklos ships a GENERIC engineering policy in dist/CLAUDE.kyklos.md. Your organisation supplies this
  overlay with the organisation-specific facts the generic policy refers to — the name of your push-authorised
  session, the repositories it owns, your secrets manager, and any house rules that do not weaken the baseline.

  Copy this file, fill in every <placeholder>, keep it in YOUR OWN private configuration (never in a public-bound
  repository), and compose it onto the baseline to produce the managed /etc/claude-code/CLAUDE.md:

      render-managed-policy.sh --product dist/CLAUDE.kyklos.md --org <your-org-layer>.md --out /etc/claude-code/CLAUDE.md

  The generic baseline and this overlay are the ONLY two inputs to the managed policy; there is no hand-maintained
  managed copy to drift. Re-render whenever either input changes.
-->

# Organisation layer — <Your Organisation>

Organisation-specific baseline that composes onto the generic kyklos engineering policy. It fills in the
concrete facts the baseline leaves abstract. It never softens a baseline rule; it only adds specifics.

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

- Add any organisation-specific conventions here. They extend the baseline; they cannot weaken a Tier-0 rule.
