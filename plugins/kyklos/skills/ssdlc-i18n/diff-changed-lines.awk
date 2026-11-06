# diff-changed-lines.awk — from `git diff -U0` output, print each changed file with the line numbers the change
# added or modified in the NEW version: <path><TAB><n1,n2,...>. Deleted files and pure deletions yield nothing.
/^\+\+\+ / {
  flush()
  path = substr($0, 5)
  if (path == "/dev/null") { path = ""; next }
  sub(/^b\//, "", path)
  next
}
/^@@ / {
  if (path == "") next
  spec = $3; sub(/^\+/, "", spec)
  count = 1
  if (index(spec, ",")) { split(spec, parts, ","); start = parts[1] + 0; count = parts[2] + 0 } else start = spec + 0
  for (k = 0; k < count; k++) changed = changed (changed == "" ? "" : ",") (start + k)
}
END { flush() }
function flush() {
  if (path != "" && changed != "") print path "\t" changed
  changed = ""
}
