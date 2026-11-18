# fs-replace-proof.awk — externalized from story-backend-fs.sh: an inline multi-line awk is mis-counted by kcov as
# 0-hit bash phantom lines. Values via ENVIRON (AWKARG_<name>), never awk -v, which rewrites backslash escapes in free text. Behaviour byte-identical to the former inline program.
BEGIN { tbl = ENVIRON["AWKARG_tbl"] }
      BEGIN { state=0 }        # 0=before proof, 1=inside proof (skip), 2=after (copy)
      state==0 && /^##[[:space:]]+Proof([[:space:]]|$)/ { print tbl; state=1; next }
      state==1 && /^##[[:space:]]/ { state=2 }
      state==1 { next }
      { print }
    
