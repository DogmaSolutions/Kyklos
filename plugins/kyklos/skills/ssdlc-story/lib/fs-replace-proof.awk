# fs-replace-proof.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Vars via awk -v. Behaviour byte-identical to the former inline program.
      BEGIN { state=0 }        # 0=before proof, 1=inside proof (skip), 2=after (copy)
      state==0 && /^##[[:space:]]+Proof([[:space:]]|$)/ { print tbl; state=1; next }
      state==1 && /^##[[:space:]]/ { state=2 }
      state==1 { next }
      { print }
    
