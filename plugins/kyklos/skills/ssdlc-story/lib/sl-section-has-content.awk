# sl-section-has-content.awk — externalized from story-lib.sh: an inline multi-line awk is mis-counted by kcov as 0-hit
# bash phantom lines. Behaviour byte-identical to the former inline program.
    index(tolower($0),tolower(h))==1 { inseg=1; next }
    inseg && /^## / { inseg=0 }
    inseg && $0 !~ /^[[:space:]]*$/ { found=1 }
    END { exit(found?0:1) }
