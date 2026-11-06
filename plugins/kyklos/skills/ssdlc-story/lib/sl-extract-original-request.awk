# sl-extract-original-request.awk — externalized from story-lib.sh: an inline multi-line awk is mis-counted by kcov as 0-hit
# bash phantom lines. Behaviour byte-identical to the former inline program.
# Returns ONLY the FIRST `## Original request` section: once grabbing, ANY subsequent `## ` heading ends
# it — INCLUDING a second `## Original request` (a doubly-damaged body). The old form re-triggered its own start
# rule on the second heading and grabbed both, so a damaged body's canonical-extraction itself carried the dup.
    grab && /^##[[:space:]]/          { exit }      # any next section (incl. a 2nd Original request) ends the block
    /^##[[:space:]]+Original request/ { grab=1; print; next }
    grab                             { print }
