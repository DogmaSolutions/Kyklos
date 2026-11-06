# sl-extract-goal.awk — externalized from story-lib.sh: an inline multi-line awk is mis-counted by kcov as 0-hit
# bash phantom lines. Behaviour byte-identical to the former inline program.
    /^>[[:space:]]*\*\*Goal:\*\*/ { started=1; line=$0;
      sub(/^>[[:space:]]*\*\*Goal:\*\*[[:space:]]*/, "", line); buf=line; next }
    started==1 && /^>/ { line=$0; sub(/^>[[:space:]]*/, "", line);
      if (line=="") { print buf; started=2; next } buf=buf " " line; next }
    started==1 { print buf; started=2 }
    END { if (started==1) print buf }
  
