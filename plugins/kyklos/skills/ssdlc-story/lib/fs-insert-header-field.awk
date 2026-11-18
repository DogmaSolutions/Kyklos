# fs-insert-header-field.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Values via ENVIRON (AWKARG_<name>), never awk -v, which rewrites backslash escapes in free text. Behaviour byte-identical to the former inline program.
BEGIN { f = ENVIRON["AWKARG_f"]; val = ENVIRON["AWKARG_val"] }
      NR==1 && /^#[[:space:]]/ { print; print ""; print "- **" f ":** " val; ins=1; next }
      { print }
      END { if (!ins) { print "- **" f ":** " val } }
    
