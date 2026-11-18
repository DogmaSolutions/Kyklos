# fs-set-title-field.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Values via ENVIRON (AWKARG_<name>), never awk -v, which rewrites backslash escapes in free text. Behaviour byte-identical to the former inline program.
BEGIN { val = ENVIRON["AWKARG_val"] }
      NR==1 && /^#[[:space:]]/ {
        if (match($0, /:[[:space:]]/)) { print substr($0,1,RSTART) " " val; done=1; next }
        else { print $0 ": " val; done=1; next }
      }
      { print }
    
