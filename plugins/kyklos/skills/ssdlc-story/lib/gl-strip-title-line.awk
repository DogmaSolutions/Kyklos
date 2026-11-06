# gl-strip-title-line.awk — externalized from story-backend-gitlab.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
        NR==1 && $0 ~ /^#[[:space:]]+STORY-[0-9]+:/ { dropped=1; next }
        NR==2 && dropped && $0 ~ /^[[:space:]]*$/    { next }
        { print }
