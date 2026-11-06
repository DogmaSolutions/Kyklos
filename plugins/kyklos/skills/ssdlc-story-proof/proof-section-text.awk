# Externalized from proof_section_text (inline multi-line awk = kcov phantom lines). Print the body of
# the markdown `## <prefix>...` section: start after the header whose text begins with `pre`, stop at the next `## `.
/^##[[:space:]]/ { if (inx) exit; if (index($0, pre)==1) { inx=1; next } }
inx { print }
