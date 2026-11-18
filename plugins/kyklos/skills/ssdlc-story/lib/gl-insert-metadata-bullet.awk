# gl-insert-metadata-bullet.awk — externalized from story-backend-gitlab.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Values via ENVIRON (AWKARG_<name>), never awk -v, which rewrites backslash escapes in free text. Behaviour byte-identical to the former inline program.
BEGIN { line = ENVIRON["AWKARG_line"] }
            !ins && /^# Proof Discipline[[:space:]]*$/ { print line; print ""; ins=1 }
            !ins && (/^##[[:space:]]/ || /<!-- spec:/) { print line; ins=1 }
            { print }
            END { if (!ins) print line }
