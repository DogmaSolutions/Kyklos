# fs-insert-after-anchor.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Values via ENVIRON (AWKARG_<name>), never awk -v, which rewrites backslash escapes in free text. Behaviour byte-identical to the former inline program.
BEGIN { anchor = ENVIRON["AWKARG_anchor"]; f = ENVIRON["AWKARG_f"]; val = ENVIRON["AWKARG_val"] }
      { print }
      {
        line=$0
        if (match(line, /^[[:space:]]*[-*][[:space:]]+\*\*[^*]*\*\*/)) {
          fld=line; sub(/^[[:space:]]*[-*][[:space:]]+\*\*/, "", fld); sub(/:\*\*.*$/, "", fld); sub(/\*\*.*$/,"",fld)
          if (tolower(fld)==tolower(anchor) && !ins) { print "- **" f ":** " val; ins=1 }
        }
      }
    
