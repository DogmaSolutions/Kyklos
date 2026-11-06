# epic-records.jq -- milestones (a JSON array; the filesystem backend feeds its registry files in the same shape) ->
# the epics among them as [{epic, id, title, goal, active, start, due}], ordered by epic number then milestone id. A milestone is an epic when its title is an epic id (E and
# the digits 0-9) followed only by a blank, a dash (em, en, hyphen), a colon or the end, then the epic's title: a
# milestone "E2E hardening" is no epic E2. The story tool's own milestone lookup reads epics through this one filter.
[ .[]?
  | select(.id != null)
  | (.title // "") as $t
  | ($t | capture("^(?<epic>E[0-9]+)(?=[\\s\u2014\u2013:-]|$)\\s*(?:[\u2014\u2013:-]\\s*)?(?<title>.*)$")?) as $p
  | select($p != null)
  | { epic: $p.epic, id: (.id|tostring), title: ($p.title | sub("\\s+$"; "")), goal: (.description // ""),
      active: ((.state // "active") == "active"), start: (.start_date // null), due: (.due_date // null) } ]
| sort_by((.epic[1:]|tonumber), (.id|tonumber? // .))
