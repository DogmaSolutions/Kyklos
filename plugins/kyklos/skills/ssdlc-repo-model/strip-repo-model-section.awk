# strip-repo-model-section.awk — emit CLAUDE.md WITHOUT its '## Repository model' section (up to the next
# top-level '## ' or EOF), so topology-declare can append a fresh one. Externalized from topology-declare.sh
#an inline multi-line awk is mis-counted by kcov as 0-hit bash phantom lines. Behaviour byte-identical.
BEGIN{skip=0}
/^##[[:space:]]+Repository model[[:space:]]*$/ {skip=1; next}
skip==1 && /^##[[:space:]]/ {skip=0}
skip==0 {print}
