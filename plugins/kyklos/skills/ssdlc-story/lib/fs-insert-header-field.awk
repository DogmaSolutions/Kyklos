# fs-insert-header-field.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
      NR==1 && /^#[[:space:]]/ { print; print ""; print "- **" f ":** " val; ins=1; next }
      { print }
      END { if (!ins) { print "- **" f ":** " val } }
    
