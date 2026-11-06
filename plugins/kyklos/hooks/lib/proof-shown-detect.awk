# proof-shown-detect.awk — externalized from kyklos-story-proof-guard.sh: the proof-table-shown detector
# was an inline multi-line awk mis-counted by kcov as 0-hit bash phantoms (21 lines). Vars via awk -v; exit 0 iff the
# transcript renders the canonical Proof table for <id>. Behaviour byte-identical to the former inline program.
        { buf = buf $0 "\n" }
        END{
            ndim=0; n=split(canon, D, "\n")
            for (i=1;i<=n;i++) if (D[i] != "") { ndim++; DIM[ndim]=D[i] }
            t=buf; pos=1; L=length(t); idl=length(id); found=0
            while (pos<=L) {
                p=index(substr(t,pos), id); if (p==0) break
                start=pos+p-1
                win=substr(t, start, win_sz)
                if (ndim>0) {
                    all=1
                    for (i=1;i<=ndim;i++) {
                        # each canonical dimension must appear as its OWN table row-leader: `|<sp>Dim<sp>|`.
                        pat="\\|[ \t]*" DIM[i] "[ \t]*\\|"
                        if (win !~ pat) { all=0; break }
                    }
                    # the render must also carry the canonical column HEADER — the 3rd column literally named
                    # `Evidence` (not a hand-renamed "Notes"), exactly as the `story proof` generator emits it. This
                    # catches a reply that renders every dimension row but relabels/collapses the columns. The pattern
                    # `| Verdict | Evidence |` is the shared prefix of BOTH the 3-column (…| Evidence |) and 4-column
                    # (…| Evidence | Metrics |) canonical headers, so it does not wrongly reject a 3-column project.
                    if (all && win ~ /\|[ \t]*Verdict[ \t]*\|[ \t]*Evidence[ \t]*\|/) { found=1; break }
                    # ...or the TERMINAL form the story tool renders from the stored table (`story proof <id> --format
                    # text`): its heading, then every canonical dimension as its OWN numbered entry
                    # `N. <glyph> **Dim** <dash> VERDICT`, the shape only that renderer emits. A hand-abridged form
                    # (rows merged, a dimension missing, no verdict word) fails exactly as an abridged table does.
                    # The glyph and the dash are matched as any non-space run, so a transcript that stores them
                    # escaped (\uXXXX) is read the same way. [RiskMitigation RA-01] heading + every dimension + verdict.
                    if (win ~ /terminal form of the stored table/) {
                        all=1
                        for (i=1;i<=ndim;i++) {
                            pat="[0-9]+\\. [^ ]+ \\*\\*" DIM[i] "\\*\\* [^ ]+ (PROVEN|NOT_PERTINENT|UNPROVEN)"
                            if (win !~ pat) { all=0; break }
                        }
                        if (all) { found=1; break }
                    }
                } else {
                    # canonical list unavailable -> legacy fallback: >=4 rendered verdict cells.
                    c=gsub(/\|[^|]*(PROVEN|NOT_PERTINENT)/, "X", win)
                    if (c>=4) { found=1; break }
                }
                pos=start+idl
            }
            exit (found?0:1)
        }
