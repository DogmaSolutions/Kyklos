# Externalized from ai-fix-loop.sh (inline multi-line jq = kcov phantom lines). Rank the reviewer's
# findings by severity (blocker<major<minor<nit<other), then file, then line.
def rank: {blocker:0,major:1,minor:2,nit:3}[.] // 4;
(.findings // [])
| map(. + {_r: (.severity | rank)})
| sort_by(._r, (.file // ""), (.line // 0))
| map(del(._r))
