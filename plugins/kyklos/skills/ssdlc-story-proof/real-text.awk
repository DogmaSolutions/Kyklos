# real-text.awk — the plugin's reading of "real text", the same cases as the bridge's StorySpecMarkdown.HasRealText
# (tests/fixtures/*-cases.txt are read by both suites). Loaded with `awk -f real-text.awk -f <script>`.
# A line holds real text when a letter or a digit remains once HTML comments, tags, character entities, keycap emoji,
# invisible format characters and the leading quote/list markers are removed. Byte-based (mawk, gawk, BSD awk alike):
# ASCII letters and digits count, and so do UTF-8 letters of the Latin, Greek, Cyrillic and CJK blocks.

# The line without its markup and invisible characters (one comment may span only this line; a cell is one line).
function rt_clean(s,    e) {
  while (match(s, /<!--/)) {
    e = index(substr(s, RSTART + 4), "-->")
    if (e == 0) { s = substr(s, 1, RSTART - 1); break }
    s = substr(s, 1, RSTART - 1) " " substr(s, RSTART + 4 + e + 2)
  }
  gsub(/<\/?[A-Za-z][A-Za-z0-9-]*([ \t][^<>]*)?\/?>/, " ", s)
  gsub(/&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);/, " ", s)
  gsub(/[0-9#*](\357\270\217)?\342\203\243/, " ", s)
  gsub(/\342\200[\213-\217\252-\256]|\342\201[\240-\244]|\357\273\277|\302\255|\341\240\216|\357\270\217/, " ", s)
  sub(/^[ \t]*(>[ \t]*)*(([-*+]|[0-9]+[.)])([ \t]+|$))?(\[[ xX~]\]([ \t]+|$))?/, "", s)
  return s
}

# 1 when the already cleaned text holds a letter or a digit. ASCII letters and digits count; so does any UTF-8
# character of a letter or digit block: Latin-1 and Latin Extended, Greek, Cyrillic, Armenian, Hebrew, Arabic (Arabic-Indic
# digits too), the scripts of U+0800-1FFF (Thai, Devanagari, Hangul Jamo ...), kana, CJK and Hangul syllables
# (U+3040-D7FF), and the Arabic presentation forms. Not counted, as in the bridge: symbols and punctuation (U+2000-2BFF,
# the 2-byte symbols of U+0080-00BF, CJK punctuation U+3000-303F, combining marks U+0300-036F, emoji, the replacement
# character). Letters outside the BMP (rare) are not recognised here.
function rt_has_letter(s) {
  if (s ~ /[A-Za-z0-9]/) return 1
  if (s ~ /[\303-\313\316-\337][\200-\277]/) return 1
  if (s ~ /[\340\341][\200-\277][\200-\277]/) return 1
  if (s ~ /\343[\201-\277][\200-\277]/) return 1
  if (s ~ /[\344-\355][\200-\277][\200-\277]/) return 1
  if (s ~ /\357[\244-\267][\200-\277]/) return 1
  return 0
}

function rt_real_text(s) { return rt_has_letter(rt_clean(s)) }

# The lower-case letters and digits of the cleaned text: "n/a" and "N / A" are both "na".
function rt_key(s,    t) {
  t = tolower(rt_clean(s))
  gsub(/[^a-z0-9]/, "", t)
  return t
}
