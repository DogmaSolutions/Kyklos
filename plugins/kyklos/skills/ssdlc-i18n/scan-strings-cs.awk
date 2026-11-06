# scan-strings-cs.awk — list the string literals of a C# file and pre-classify each one for the i18n scan.
# Input: the C# source. Variables: file (the path to print), lines (comma-separated line numbers to report; empty =
# every line). Output, one line per literal: <file>:<line><TAB><CANDIDATE|EXCLUDED:<reason>><TAB><literal>.
# The classification is a PRE-FILTER, not the verdict: log messages, logic-driving comparisons, lookup keys,
# attributes and text-free literals are excluded by rule; everything else is a candidate the agent judges.
BEGIN {
  n = split(lines, wanted_list, ",")
  for (i = 1; i <= n; i++) if (wanted_list[i] != "") wanted[wanted_list[i]] = 1
  every_line = (n == 0)
  in_comment = 0
}
{
  text = $0
  if (in_comment) {
    close_at = index(text, "*/")
    if (!close_at) next
    text = substr(text, close_at + 2); in_comment = 0
  }
  trimmed = text; sub(/^[ \t]+/, "", trimmed)
  if (trimmed ~ /^\/\//) next
  if (trimmed ~ /^\/\*/) { if (index(trimmed, "*/") == 0) in_comment = 1; next }
  if (!every_line && !(FNR in wanted)) next
  rest = text; consumed = ""
  while (match(rest, /\$?@?"([^"\\]|\\.)*"/)) {
    literal = substr(rest, RSTART, RLENGTH)
    before = consumed substr(rest, 1, RSTART - 1)
    after = substr(rest, RSTART + RLENGTH)
    consumed = before literal
    rest = after
    inner = literal; sub(/^\$?@?"/, "", inner); sub(/"$/, "", inner)
    if (inner == "") continue
    print file ":" FNR "\t" classify(before, after, inner, trimmed) "\t" literal
  }
}
function classify(before, after, inner, trimmed) {
  if (before ~ /(\.Log(Trace|Debug|Information|Warning|Error|Critical)?|[Ll]ogger\.[A-Za-z]+|Log\.[A-Z][A-Za-z]*|Trace\.Write(Line)?|Debug\.Write(Line)?)[ \t]*\(/) return "EXCLUDED:log"
  if (before ~ /(case[ \t]+|==[ \t]*|!=[ \t]*|\.(Equals|StartsWith|EndsWith|Contains|IndexOf|Split|Replace)\([ \t]*)$/) return "EXCLUDED:logic"
  if (after ~ /^[ \t]*(==|!=)/) return "EXCLUDED:logic"
  if (before ~ /((GetSection|GetValue<[^>]*>|GetConnectionString|GetEnvironmentVariable|TryGetValue|ContainsKey|GetString)\([ \t]*|\[[ \t]*)$/) return "EXCLUDED:key"
  if (trimmed ~ /^\[/) return "EXCLUDED:attribute"
  # Text means letters outside escape sequences and interpolation holes: "\n", "\t" or "{m.Key} {m.Tool}" have none.
  text_only = inner
  gsub(/\\./, "", text_only)
  gsub(/\{[^}]*\}/, "", text_only)
  if (text_only !~ /[A-Za-z]/) return "EXCLUDED:no-text"
  if (inner ~ /^[a-z][a-z0-9+.-]*:\/\// || inner ~ /^[A-Za-z0-9_.\/\\-]+\.[A-Za-z0-9]+$/) return "EXCLUDED:technical"
  return "CANDIDATE"
}
