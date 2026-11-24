#!/usr/bin/env bash
# rulebook.generated.sh (Kyklos hook lib) - the rulebook of shared/src/DogmaSolutions.Kyklos.Settings/Rules, as shell
# variables: the one source of every rule the hooks judge (who may push, close modes, the self-drive default, the API
# scopes, the token state, the topologies). Sourced through lib/rulebook.sh only. RulebookTests (shared settings tests) writes and checks it.
# >>> kyklos rulebook, written from SessionRules (change SessionRules, then write the blocks again)
KYKLOS_RULE_SWITCH_ON="1"
KYKLOS_RULE_PUSH_SWITCHES="KYKLOS_ALLOW_PUSH KYKLOS_CI_MONITOR"
KYKLOS_RULE_CLOSE_MODES_THAT_PUSH="push mr mr-automerge"
KYKLOS_RULE_MR_CLOSE_MODES="mr mr-automerge"
KYKLOS_RULE_SELF_DRIVE_DEFAULT="true"
KYKLOS_RULE_API_CAPABLE_SCOPES="api write_api"
KYKLOS_RULE_TOKEN_STATE_VAR="KYKLOS_CONTAINER_API_TOKEN_STATE"
KYKLOS_RULE_TOKEN_STATES="none host-only allowed"
KYKLOS_RULE_TOPOLOGIES="PriSta PriComPubSou PriSouPubArt PriComPriSou"
KYKLOS_RULE_COMPANION_TOPOLOGIES="PriComPubSou PriComPriSou"
KYKLOS_RULE_SECRETS_MODES="env bridge both"
KYKLOS_RULE_TOPOLOGY_ROWS="PriSta:internal:gitflow:- PriComPubSou:companion:gitflow:Repo PriSouPubArt:internal:gitflow:- PriComPriSou:companion:gitflow:Repo"
# <<< kyklos rulebook
