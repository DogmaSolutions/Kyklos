# gl-insert-metadata-bullet.awk — externalized from story-backend-gitlab.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
            !ins && (/^##[[:space:]]/ || /<!-- spec:/) { print line; ins=1 }
            { print }
            END { if (!ins) print line }
