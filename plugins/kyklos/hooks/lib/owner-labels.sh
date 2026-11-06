#!/usr/bin/env bash
# owner-labels.sh — the names of the labels through which the OWNER grants an exception to the story judge. SOURCED,
# not executed. The names are fixed on purpose: if a label name could be chosen through a variable, an agent could
# point it at a label someone else already applied for an unrelated reason (for example the requester's own `story`
# label) and so obtain the exception without the owner ever granting it. Every consumer (the story tool and the proof
# and close guards) reads the names from here and checks authorship with user-applied-label / the backend's label
# history, so a label the agent applied itself never counts.
# [CySec] CWE-863 "Incorrect Authorization": the exception is keyed to fixed label names an agent cannot redirect.

# The owner's exception for a story's Done gates (an unproven or migrated close the owner accepts).
OWNER_OVERRIDE_LABEL="proof-override"
# The owner's marker for a migrated historical close: graded under the tolerant historical rules.
OWNER_GRANDFATHER_LABEL="proof-grandfather"
