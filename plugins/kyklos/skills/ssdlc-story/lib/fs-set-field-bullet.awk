# fs-set-field-bullet.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
      BEGIN{ IGNORECASE=1; lc=tolower(f) }
      {
        line=$0
        if (match(line, /^[[:space:]]*[-*][[:space:]]+\*\*[^*]*\*\*/)) {
          lbl=substr(line, 1, RSTART+RLENGTH-1)
          # extract the field name between the ** ** to compare case-insensitively
          fld=lbl; sub(/^[[:space:]]*[-*][[:space:]]+\*\*/, "", fld); sub(/:\*\*.*$/, "", fld); sub(/\*\*.*$/,"",fld)
          if (tolower(fld)==lc) { print "- **" f ":** " val; next }
        }
        print
      }
    
