#!/usr/bin/env bash
# refs-footer.sh -- THE one definition, for every shell reader, of what a commit footer cites. Sourced; the bridge holds
# the same definition for the code that cannot call shell (CommitFooter), and one shared case file
# (tests/fixtures/refs-footer-cases.txt) is read by the tests of both sides and of every reader below, so no reader can
# drift from it.
#
# THE DEFINITION. A footer line starts with `Refs:` (any letter case) and continues with a LIST of items; the list ends
# at the first thing that is not another item, and whatever follows is a REMARK that is never read for numbers.
#   item     `#N` (zero padding allowed: a padded number is the same item) or `group/project#N` (the group path may hold
#            sub-groups)
#   list     one item, or items joined by commas (`#N, #M`, blanks around a comma allowed)
#   remark   anything after the list: `Refs: #N (see #M)` cites N only; `Refs: #N and #M` cites N only
#   own      a plain `#N`, and `group/project#N` when the path is the story's own project path (letter case ignored), cite
#            item N of the story's own project; any other `group/project#N` is a FOREIGN item (it never cites the story)
# What is NOT a footer: a line that does not start with `Refs:` (leading blanks are allowed), `Refs:` with no item right after it
# (`Refs: see #N`), an item written without its `#` or inside a bracket. A message may hold several footer lines; the
# cited items are all of them, in order, once each.
# The command-line form (mode `command`) reads the text of a `git commit -m ...` command, where `Refs:` follows a quote
# and not a line start: every `Refs:` that is not the tail of a longer word starts a list (a literal backslash-n, as in
# an ANSI-C quoted `$'...\n\nRefs: ...'`, ends the word before it).
#
# OWN PROJECT. The readers that cannot ask the bridge (the commit hook, the push guard) take the repository's own
# project path: STORY_GITLAB_PROJECT of the repository's settings when it is a path, else the path of its origin remote
# (refs_footer_own_project). A bridge that is down therefore never refuses a commit. Empty when neither is known: every
# `group/project#N` is then foreign (never guessed to be the story's).
#
# Functions (all pure: they read nothing but their arguments and, for refs_footer_own_project, the repository):
#   refs_footer_cited   TEXT OWN [command]      the cited items, one per line, in order, once each: `N` (an own item, no zero
#                                               padding) or `group/project#N` (a foreign item)
#   refs_footer_cites   TEXT OWN KEY [command]  rc 0 when an own item of a footer is KEY
#   refs_footer_has     TEXT OWN [command]      rc 0 when TEXT holds a footer that cites at least one item
#   refs_footer_story_key TEXT OWN              the first own item (the story a head commit names), or nothing
#   refs_footer_grep    KEY OWN                 the `git log -E --grep` / `grep -E` pattern of a footer line citing own item
#                                               KEY: the same rule as an ERE, for the readers that filter with git
#   refs_footer_own_project REPO                the repository's own project path (see above)
#   REFS_FOOTER_AWK                             the same rule as awk functions (refs_footer_line_items, refs_footer_cites_line,
#                                               refs_footer_has_line, refs_footer_number): the readers that judge records in
#                                               awk put it in front of their own program, so they call the one definition
# [CySec] CWE-345 (insufficient verification of data authenticity): a number that only sits in a remark never cites an
# item, and another project's item never cites this project's story.

_REFS_FOOTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The awk side of the definition. mawk-compatible (no interval expressions, no gensub).
# refs_footer_line_items(line, own, anywhere, items): fill items[1..n] with the items the footer in `line` cites and return
# n. `line` is one line (it must start with Refs:) or, with anywhere set, any text.
REFS_FOOTER_AWK='
function refs_footer_norm_path(path) {
    path = tolower(path)
    sub(/\.git$/, "", path); sub(/^\/+/, "", path); sub(/\/+$/, "", path)
    return path
}
function refs_footer_number(digits) {
    sub(/^0+/, "", digits)
    return (digits == "") ? "0" : digits ""
}
function refs_footer_list(rest, own, items, n,    token, hash, path, num) {
    while (1) {
        sub(/^[ \t]+/, "", rest)
        if (!match(rest, /^([A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)+)?#[0-9]+/)) return n
        token = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
        hash = index(token, "#"); path = substr(token, 1, hash - 1); num = refs_footer_number(substr(token, hash + 1))
        n++
        items[n] = (path == "" || refs_footer_norm_path(path) == own) ? num : path "#" num
        if (!match(rest, /^[ \t]*,/)) return n
        rest = substr(rest, RLENGTH + 1)
    }
}
function refs_footer_line_items(line, own, anywhere, items,    n, low, at) {
    n = 0; own = refs_footer_norm_path(own)
    sub(/\r$/, "", line)
    low = tolower(line)
    if (!anywhere) {
        sub(/^[ \t]+/, "", line); low = tolower(line)
        if (substr(low, 1, 5) != "refs:") return 0
        return refs_footer_list(substr(line, 6), own, items, 0)
    }
    while ((at = index(low, "refs:")) > 0) {
        # not the tail of a longer word; a backslash escape (the literal \n of an ANSI-C quoted -m) counts as a boundary
        if (at == 1 || substr(low, at - 1, 1) !~ /[a-z0-9_]/ || (at > 2 && substr(low, at - 2, 2) ~ /^\\[nrt]$/)) n = refs_footer_list(substr(line, at + 5), own, items, n)
        line = substr(line, at + 5); low = substr(low, at + 5)
    }
    return n
}
# refs_footer_lead(line, anywhere, leads): the CI-visible reading, for the commit hook pertinent-issue rule. For each
# footer line (the keyword exactly `Refs:`, leading blanks allowed in a message), leads[k] is the number of its FIRST item
# when that item is a plain `#N`; a footer whose first item is project-qualified, or a remark-first line, adds nothing.
function refs_footer_lead(line, anywhere, leads,    n, at, rest, digits) {
    n = 0
    sub(/\r$/, "", line)
    if (!anywhere) {
        sub(/^[ \t]+/, "", line)
        if (substr(line, 1, 5) != "Refs:") return 0
    }
    while ((at = index(line, "Refs:")) > 0) {
        if (!anywhere || at == 1 || substr(line, at - 1, 1) !~ /[A-Za-z0-9_]/ || (at > 2 && substr(line, at - 2, 2) ~ /^\\[nrt]$/)) {
            rest = substr(line, at + 5)
            if (match(rest, /^[ \t]*#[0-9]+/)) { digits = substr(rest, RSTART, RLENGTH); sub(/^[ \t]*#/, "", digits); n++; leads[n] = refs_footer_number(digits) }
        }
        line = substr(line, at + 5)
        if (!anywhere) break
    }
    return n
}
function refs_footer_cites_line(line, own, key, anywhere,    items, n, i) {
    n = refs_footer_line_items(line, own, anywhere, items)
    key = refs_footer_number(key)
    for (i = 1; i <= n; i++) if ((items[i] "") == key) return 1
    return 0
}
function refs_footer_has_line(line, own, anywhere,    items) {
    return refs_footer_line_items(line, own, anywhere, items) > 0
}
'

# _refs_footer_key TEXT -> the first number in TEXT without zero padding, nothing when there is none.
_refs_footer_key() { printf '%s' "${1-}" | grep -oE '[0-9]+' | head -1 | sed -E 's/^0+([0-9])/\1/'; }

# refs_footer_cited TEXT OWN [command] -> the cited items, one per line (see the header).
refs_footer_cited() {
    local anywhere=""
    [ "${3:-}" = command ] && anywhere=1
    printf '%s\n' "${1-}" | awk -v own="${2-}" -v anywhere="$anywhere" "$REFS_FOOTER_AWK"'
        { delete items; n = refs_footer_line_items($0, own, anywhere, items)
          for (i = 1; i <= n; i++) if (!(items[i] in seen)) { seen[items[i]] = 1; print items[i] } }'
}

# refs_footer_lead_plain TEXT [command] -> the CI-visible leads (see refs_footer_lead), one number per line, once each: the
# first item of every `Refs:` footer line, when it is a plain `#N`. The commit hook's pertinent-issue rule reads this, so it
# accepts exactly what the CI commit check accepts until that check reads the whole definition.
refs_footer_lead_plain() {
    local anywhere=""
    [ "${2:-}" = command ] && anywhere=1
    printf '%s\n' "${1-}" | awk -v anywhere="$anywhere" "$REFS_FOOTER_AWK"'
        { delete leads; n = refs_footer_lead($0, anywhere, leads)
          for (i = 1; i <= n; i++) if (!(leads[i] in seen)) { seen[leads[i]] = 1; print leads[i] } }'
}

# refs_footer_cites TEXT OWN KEY [command] -> rc 0 when an own item cited is KEY.
refs_footer_cites() {
    local key
    key="$(_refs_footer_key "${3-}")"
    [ -n "$key" ] || return 1
    refs_footer_cited "${1-}" "${2-}" "${4:-}" | grep -cxF -- "$key" >/dev/null
}

# refs_footer_has TEXT OWN [command] -> rc 0 when TEXT holds a footer citing at least one item.
refs_footer_has() { refs_footer_cited "${1-}" "${2-}" "${3:-}" | grep -c . >/dev/null; }

# refs_footer_story_key TEXT OWN -> the first own item cited (digits only), nothing when none.
refs_footer_story_key() { refs_footer_cited "${1-}" "${2-}" | grep -xE '[0-9]+' | head -1; }

# _refs_footer_ci_pattern TEXT -> TEXT as an ERE that ignores letter case ([Aa] for a letter, a dot escaped).
_refs_footer_ci_pattern() {
    printf '%s' "${1-}" | awk '{ out = ""
        for (i = 1; i <= length($0); i++) { c = substr($0, i, 1)
            if (c ~ /[A-Za-z]/) out = out "[" toupper(c) tolower(c) "]"; else if (c == ".") out = out "\\."; else out = out c }
        printf "%s", out }'
}

# refs_footer_grep KEY OWN -> the ERE of a footer line citing own item KEY: `Refs:`, blanks, any number of items each
# followed by a comma, then an item for KEY (zero padding allowed, no longer number); what follows is the remark.
refs_footer_grep() {
    local key own item own_item hash="#"
    key="$(_refs_footer_key "${1-}")"
    [ -n "$key" ] || { printf '%s' '$^.'; return 0; }   # no key: a pattern no line can match
    own="$(printf '%s' "${2-}" | tr 'A-Z' 'a-z' | sed -E 's/\.git$//; s,^/+,,; s,/+$,,')"
    item="([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)?${hash}[0-9]+"
    own_item=""
    # the own path, with or without a ".git" suffix, as the item's project path
    [ -n "$own" ] && own_item="($(_refs_footer_ci_pattern "$own")(\\.[Gg][Ii][Tt])?)?"
    printf '^[[:space:]]*[Rr][Ee][Ff][Ss]:[[:space:]]*(%s[[:space:]]*,[[:space:]]*)*%s%s0*%s([^0-9]|$)' "$item" "$own_item" "$hash" "$key"
}

# refs_footer_own_project REPO -> the repository's own project path: STORY_GITLAB_PROJECT in its settings when that holds a
# path, else the path of its origin remote (scheme, host, user and ".git" removed). Nothing when neither is known.
refs_footer_own_project() {
    local repo="${1:-.}" top cfg declared url
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || top="$repo"
    command -v standards_env_value >/dev/null 2>&1 || . "$_REFS_FOOTER_DIR/standards-env.sh" 2>/dev/null
    if command -v standards_env_value >/dev/null 2>&1; then
        cfg="$top/.claude/standards.env"
        declared="$(standards_env_value "$cfg" STORY_GITLAB_PROJECT 2>/dev/null)"
        case "$declared" in */*) printf '%s' "$declared"; return 0 ;; esac
    fi
    command -v same_repository_remote_path >/dev/null 2>&1 || . "$_REFS_FOOTER_DIR/same-repository.sh" 2>/dev/null
    command -v same_repository_remote_path >/dev/null 2>&1 || return 0
    url="$(git -C "$top" remote get-url origin 2>/dev/null)" || return 0
    same_repository_remote_path "$url"
}
