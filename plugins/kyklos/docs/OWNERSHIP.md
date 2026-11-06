# Who owns which fact

Every fact the Kyklos relies on (a setting, a label, a policy rule, a protocol step) is stated **once**, by the
component that owns it. Every other file that needs it **points** to that owner (a file, a function or a skill name)
instead of restating it. A restated copy goes stale the day the owner changes; a pointer cannot.

This map lists the owners. It never states the facts themselves: follow the pointer and read the owner.

| Kind of fact | Owner |
|---|---|
| Engineering policy for every agent (push policy, GitFlow, testing, response style) | `dist/CLAUDE.kyklos.md` |
| Which hook runs on which event | `plugins/kyklos/hooks/hooks.json` |
| How hooks and the fix loop reach CI (bridge verbs first, the direct-token exception, its settings) | `plugins/kyklos/hooks/lib/ci-access.sh` |
| Story lifecycle commands, story backends, the story fields | the `story` tool (`plugins/kyklos/skills/ssdlc-story/story`) and its `lib/story-backend-*.sh` |
| GitLab label names and scopes (`status::`, `kind::`, `severity::`, `ssdlc:phase::`, ...) | `_GL_KNOWN_LABELS` in `plugins/kyklos/skills/ssdlc-story/lib/story-backend-gitlab.sh` |
| Proof dimensions, row format and close rules | `plugins/kyklos/skills/ssdlc-story-proof/SKILL.md` |
| Proof-tool tokens (change window, mint, verify) | `plugins/kyklos/hooks/lib/proof-tool-gate.sh` |
| Proof table columns, the Metrics gate and its CRAP threshold | `plugins/kyklos/skills/ssdlc-story-proof/proof-dimensions.sh` |
| The token's coverage question (95 % of the story lines covered or limited) | the bridge: `StoryLineTolerance`, judged once when the token is issued (`StoryLineJudgement`); the close and `coverage_receipt_check` read the token's verdict. A story's `Coverage-Floor` line and the settings `Agile:Proof:CoverageFloorPercent` / `CoverageMinimumPercent` are obsolete for a story: `story_field_set` answers `obsolete`, the receipt names a stored line as obsolete, and `coverage_floor_check` only reports the figure. The CI project-wide `COVERAGE_THRESHOLD` is a different control (the `measuring-test-coverage` skill) |
| Story types and their pertinent dimensions | `plugins/kyklos/skills/ssdlc-story-proof/story-type-profile.sh` |
| Whether a story needs a mutation run | `plugins/kyklos/skills/measuring-test-coverage/mutation-due.sh` |
| The `[CySec]` annotation convention | the `ssdlc-cysec` skill |
| The build channel (`BUILD_EXECUTION`) and what it refuses | the `running-tests` skill (interview) and `plugins/kyklos/hooks/kyklos-build-execution-guard.sh` |
| Branch close modes and their close commands | `_mode_hint` in `plugins/kyklos/hooks/kyklos-branch-cleanup-guard.sh` |
| The inbound coordination gate and its settings | the header of `plugins/kyklos/hooks/kyklos-inbound-issues-guard.sh` and of `hooks/lib/inbound-issues-fetch.sh` |
| Raw-client refusals for coordination issues | the header of `plugins/kyklos/hooks/kyklos-agent-msg-guard.sh` |
| The `agent-msg` commands | `agent-msg --help` (`plugins/kyklos/skills/ssdlc-agent-msg/agent-msg`) |
| CI jobs the fleet templates provide (CRAP gate, mutation) | the CI templates' README (separate repository) |
| One-shot overrides and their names | `plugins/kyklos/hooks/lib/override-marker.sh` |
| The continue-guard's modes and settings | the header of `plugins/kyklos/hooks/kyklos-continue-guard.sh` |
| Bridge verbs, their arguments and the bridge's settings | `bridge/README.md` and each verb's own tool description |
| Launcher configuration parameters (names, defaults, stages, texts) | `ProjectParameters.cs` and `Resources/SettingTexts.resx` (the shared settings catalog, `shared/`) |
| Launcher-wide timeouts | `launcher/src/KyklosLauncher/Launch/LaunchTimeoutOptions.cs` |
| Launcher behaviour and API | `launcher/README.md` |

## New logic is built once, in the bridge

A new feature or any business logic is built **once**, in KyklosBridge. The Kyklos plugin only **guides** the agent to
the bridge verb that does the work and **enforces** that the verb is used (a hook that refuses the shortcut, a skill that
names the verb). The plugin never carries a second copy of the logic, because two copies drift apart and the agent then
meets two answers to one question. Plugin logic that duplicates the bridge is **deleted**, or reduced to a thin call to the
bridge verb. A plugin layer the agent does not need, because it can call the bridge directly, is removed.

Worked example: the token's coverage question. Its tolerance and its judgement of a story's lines live in the bridge; the
plugin holds no floor setting and compares no figure with a floor.

## The rule for authors

- **Describe your own component.** A skill states its own protocol; a hook states its own behaviour; a script's help
  text states its own options.
- **Point, don't restate.** When your text needs a fact another component owns, name the owner in one line ("the
  CI access settings are in `hooks/lib/ci-access.sh`") and stop. Do not copy its settings, defaults, label names or
  rules.
- **Check against the owner, not against a copy.** When you correct a statement, read the owner's code.
- **Worked example:** the `ssdlc-ai-fix-loop` skill once restated the CI-access settings, the push policy, the story
  backends and a label name (`sev:` where the story tool writes `severity::`). It now states only its own loop and
  points to `ci-access.sh`, the policy and the story tool.
