# fs-set-title-field.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
      NR==1 && /^#[[:space:]]/ {
        if (match($0, /:[[:space:]]/)) { print substr($0,1,RSTART) " " val; done=1; next }
        else { print $0 ": " val; done=1; next }
      }
      { print }
    
