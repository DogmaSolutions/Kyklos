# Externalized from proof_dimension_metrics_cell (inline multi-line awk = kcov phantom lines). On a
# 4-column proof row (NF>=6 with the leading/trailing empty cells), print the Metrics cell ($5) of the row whose
# Dimension cell ($2, emphasis/space stripped) equals d.
NF>=6 { dim=$2; gsub(/[`*_]/,"",dim); gsub(/^[ \t]+|[ \t]+$/,"",dim)
        if (dim==d) { m=$5; gsub(/^[ \t]+|[ \t]+$/,"",m); print m; exit } }
