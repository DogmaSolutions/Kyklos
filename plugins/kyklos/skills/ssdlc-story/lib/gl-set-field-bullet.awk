# gl-set-field-bullet.awk — externalized from story-backend-gitlab.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Values via ENVIRON (AWKARG_<name>), never awk -v, which rewrites backslash escapes in free text. Behaviour byte-identical to the former inline program.
BEGIN { f = ENVIRON["AWKARG_f"]; v = ENVIRON["AWKARG_v"] }
            !seen && $0 ~ ("^[[:space:]]*[-*][[:space:]]+\\*\\*" f ":\\*\\*") {
                match($0, /\*\*[^*]*\*\*[[:space:]]*/)          # the "**Field:** " label + trailing space
                print substr($0, 1, RSTART + RLENGTH - 1) v; seen=1; next
            }
            { print }
