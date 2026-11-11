# What Kyklos assumes about the agent

[← Back to the README](../README.md) · [← The Proof Table](PROOF.md)

Kyklos protects you from an agent that **makes mistakes**: it forgets a step, trusts a claim it did not check, edits a file after
its proof was taken, or cites evidence that does not exist. It is **not** designed to withstand an agent that is **acting
deliberately against you**, one that sets out to defeat the checks. No tooling around a language model can promise that, and a
design that tried would also get in the way of an honest agent.

Signing is the clearest example. The Bridge signs the facts it records after a passing test run (which changed lines the tests
ran) with a key the agent never sees:

- **What the signing stops:** a plain write to those records, by accident or by a test that does not go after the key, and a
  record that was changed or copied from somewhere else. Such a record reads as absent and is named in the answer.
- **What it does not stop:** a test written to steal the key. Tests run as the same user on the same machine as the Bridge,
  and a program running as that user can read the key from the credential store or from the Bridge's own memory. Starting
  the tests without the key in their environment does not change that. Only running tests under another account or on
  another machine would, and Kyklos does not do that.

The control Kyklos relies on for a deliberately hostile change is the one a person would use: the
[adversarial review](ADVERSARIAL_REVIEW.md) of the tests and the code (the [Adversarial Review](PROOF_DIMENSION_ADVERSARIAL_REVIEW.md)
row of the Proof Table), and your own reading of it.

## An optional hardening: `Agile:Proof:AdversarialAgentHardening`

For an owner who wants some extra defence anyway, the Bridge has one switch, **off by default**.
It is the one exception to the rule that every new check of Kyklos ships switched on: these checks add friction for an honest
agent and buy protection only against a deliberate one, so the choice is yours.

- `off` (the default): nothing changes.
- `on`: both of the following apply.

When it is `on`:

1. **Reserved markers.** The Bridge keeps several sections of a story (the proof table, the risk register, its signed records) in
   notes that begin with a marker line such as `<!-- kyklos:story-proof -->` or `<!-- kyklos:proof-discipline -->`. The Bridge's
   comment verbs (the coordination reply, and the comment given when closing or reopening a conversation) then refuse a note that
   begins with such a marker, and the answer points to the story tool, which is how those sections are meant to change. Without
   the switch, an agent could post a note that looks like one of those sections.
2. **The close checks the citations.** `proof_draft` records which items of the specification it found no evidence for, and
   `proof_set` already refuses a row that cites one of them. With the switch on, closing a story applies the same check to the
   rows already stored, using that record (which the Bridge signs). Without it, a row written another way could cite an item
   that was never covered and still pass the close.

With the Launcher, set the project's launch parameter `KYKLOS_BRIDGE_ADVERSARIAL_AGENT_HARDENING` to `on` in its configuration (the
default is `off`); the Launcher passes it to the Bridge it starts, when the project has the story tools switched on (without them there is nothing to harden, and the parameter does nothing). The Bridge itself reads it as the setting
`Agile:Proof:AdversarialAgentHardening`, which a Bridge you start by hand takes from the environment variable
`Agile__Proof__AdversarialAgentHardening=on`. A value placed in the project's Bridge settings file or in the launch environment is
dropped, because the Launcher builds that section itself.

Any value other than `off` or `on` stops the Bridge at start-up and names the setting. The owner's exception label on a story
still waives the close check, as it does for every other proof check.

## Related pages

[The Proof Table](PROOF.md), [Adversarial reviews](ADVERSARIAL_REVIEW.md), [Secrets](SECRETS.md), [Completeness](PROOF_DIMENSION_COMPLETENESS.md)
(where the citation check is explained step by step), and [the README](../README.md) for the full list.
