# resx-find.awk — print the key of every RESX entry whose value is exactly the given text (so an agent reuses an
# existing resource instead of adding a duplicate). Input: the text, XML-escaped by the caller, in the environment
# variable I18N_FIND_TEXT (not -v, which would interpret backslash escapes); the variable file names the RESX.
# Output: <file><TAB><key>. Handles the value on the same line as <data> or on following lines.
BEGIN { want = ENVIRON["I18N_FIND_TEXT"] }
/<data[ \t]/ {
  key = ""
  if (match($0, /name="[^"]*"/)) key = substr($0, RSTART + 6, RLENGTH - 7)
}
/<value>/ {
  value = $0
  sub(/.*<value>/, "", value); sub(/<\/value>.*/, "", value)
  if (key != "" && value == want) print file "\t" key
}
