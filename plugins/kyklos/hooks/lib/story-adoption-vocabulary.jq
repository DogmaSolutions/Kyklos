# story-adoption-vocabulary.jq -- the label vocabulary of the bridge's label codec (LabelCodec.Decode), the reference the
# story tool follows: a namespace is matched as "ns::value" or the legacy "ns:value", case-insensitively, and only a value
# the codec knows counts. A free-form type (type::security) is no type, a bare "parked" or an "S:todo" is no status (they
# are legacy forms the codec does not read), and the bare legacy "bug" is the type fix. Included by
# story-adoption-missing.jq and by the helpers in story-adoption.sh.
def labels: [(.labels // [])[] | select(type == "string") | gsub("^\\s+|\\s+$"; "") | ascii_downcase];
def values($ns): [labels[]
    | if startswith($ns + "::") then .[($ns + "::" | length):]
      elif startswith($ns + ":") and ((.[($ns + ":" | length):] | startswith(":")) | not) then .[($ns + ":" | length):]
      else empty end
    | select(length > 0)];
def type_words: ["feat","fix","docs","ci","perf","test","build","chore","infra","style","plugin","revert","library","service","refactor"];
def type_aliases: {"bug": "fix", "feature": "feat"};
def status_words: ["todo","doing","blocked","wontfix","archived","parked","duplicate","invalid"];
# the type the codec reads (canonical word), or empty
def codec_type: ([(labels[] | select(. == "bug") | "fix"),
                  (values("type")[] | if (. as $v | type_words | index($v) != null) then . else (type_aliases[.] // empty) end)] | first // "");
def has_status: any(values("status")[]; (. as $v | status_words | index($v) != null) or (startswith("blocked-on-") and length > 11));
# a legacy status form the codec does not read, mapped to the scoped status it stands for: parked, S:todo|doing|blocked
def legacy_status: ([(.labels // [])[] | select(type == "string") | . as $o | (gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $l
                      | if $l == "parked" then {label: $o, status: "parked"}
                        elif ($l | test("^s:(todo|doing|blocked)$")) then {label: $o, status: $l[2:]} else empty end] | first // null);
# every type label as written (the bare "bug" and the type namespace, a free-form value included): the labels a type write replaces
def type_labels: [(.labels // [])[] | select(type == "string") | select((gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $l | $l == "bug" or ($l | startswith("type:")))];
def header_value($f): [(.description // "") | splits("\n")
    | capture("^[ \t]*[-*][ \t]+\\*\\*(?<k>[^*\r\n]+):\\*\\*(?<v>[^\r]*)") | select((.k | ascii_downcase) == ($f | ascii_downcase))
    | .v | gsub("^\\s+|\\s+$"; "")] | first // "";
def header($f): header_value($f) as $v | ($v != "" and $v != "-");
# the epic id a milestone title or an Epic line starts with (E and digits, then a blank, a dash, a colon or the end), or ""
def epic_id($t): ($t | capture("^(?<id>E[0-9]+)([\\s\u2014\u2013:-]|$)") | .id) // "";
