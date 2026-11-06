# gl-set-field-bullet.awk — externalized from story-backend-gitlab.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
            !seen && $0 ~ ("^[[:space:]]*[-*][[:space:]]+\\*\\*" f ":\\*\\*") {
                match($0, /\*\*[^*]*\*\*[[:space:]]*/)          # the "**Field:** " label + trailing space
                print substr($0, 1, RSTART + RLENGTH - 1) v; seen=1; next
            }
            { print }
