# proof-apply-verdict.awk — apply a Verdict/Evidence/Metrics to a named dimension row (exit 3 => dimension not found). Externalized from proof-dimensions.sh: an inline multi-line awk is mis-counted
# by kcov as 0-hit bash phantom lines. Vars are passed with awk -v. Behaviour byte-identical to the inline form.
    BEGIN{ found=0; gsub(/^[ \t]+|[ \t]+$/,"",dim); ldim=tolower(dim) }
    {
      line=$0
      if (line ~ /^\|/) {
        n=split(line, c, "|")           # c[1]="" c[2]=Dimension c[3]=Verdict c[4]=Evidence c[5]=Metrics c[6]=""
        cell=c[2]; gsub(/^[ \t]+|[ \t]+$/,"",cell)
        if (n>=4 && tolower(cell)==ldim) {
          c[3]=" " verdict " "
          if (haveev=="1") c[4]=" " ev " "
          # Only a 4-column row has a Metrics cell (n>=6: empty c[1] + 4 content cells + empty c[n]).
          if (havemx=="1" && n>=6) c[5]=" " mx " "
          out=""; for(i=2;i<=n-1;i++) out=out "|" c[i]; out=out "|"
          print out; found=1; next
        }
      }
      print line
    }
    END{ if(!found) exit 3 }
