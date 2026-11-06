# sl-strip-original-request.awk — the INVERSE of sl-extract-original-request.awk: print the input
# WITHOUT every `## Original request (verbatim)` section (heading through the line before the next `## ` or EOF).
# Used by cmd_requirements to make the spec-write IDEMPOTENT on the tool-owned provenance section: an incoming
# duplicate in the authored spec file is dropped (the adoption-written canonical wins).
/^##[[:space:]]+Original request \(verbatim\)/ { skip=1; next }
/^##[[:space:]]/ { skip=0 }
skip != 1 { print }
