# fs-insert-after-anchor.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
      { print }
      {
        line=$0
        if (match(line, /^[[:space:]]*[-*][[:space:]]+\*\*[^*]*\*\*/)) {
          fld=line; sub(/^[[:space:]]*[-*][[:space:]]+\*\*/, "", fld); sub(/:\*\*.*$/, "", fld); sub(/\*\*.*$/,"",fld)
          if (tolower(fld)==tolower(anchor) && !ins) { print "- **" f ":** " val; ins=1 }
        }
      }
    
