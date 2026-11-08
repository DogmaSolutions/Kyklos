# sl-extract-header.awk — externalized from story-lib.sh: an inline multi-line awk is mis-counted by kcov as 0-hit
# bash phantom lines. Behaviour byte-identical to the former inline program.
    /^# Proof Discipline[[:space:]]*$/         { section=1; print; next }   # the owner's section is part of the header
    section && (/^##[[:space:]]/ || /<!-- spec:/) { exit }                  # it ends where the spec starts
    section                                    { print; next }
    /^[[:space:]]*#[[:space:]]/                { print; next }   # the H1 title line (single "# "; a "## " spec heading is NOT matched)
    /^[[:space:]]*-[[:space:]]+\*\*[^*]+:\*\*/ { print; next }   # a metadata bullet (Status/Type/Epic/Branch/Summary/Parent/…)
    /^[[:space:]]*$/                           { print; next }   # a blank line between header lines -> keep
    { exit }                                                     # first "## " heading / free-form prose / "---" -> header ends
  
