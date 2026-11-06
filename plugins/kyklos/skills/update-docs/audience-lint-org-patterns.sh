#!/usr/bin/env bash
# audience-lint-org-patterns.sh - the ONE way the audience-lint grammar finds and matches the ORGANISATION-SPECIFIC
# patterns.
#
# The shipped audience-lint-patterns.txt is generic: it names nothing of any one organisation (no domain, no secret
# path, no CI variable of ours), so it can ship to anyone. The organisation's own markers (its hosts, its customers'
# and projects' names, ...) are configuration, read at run time from:
#   1. AUDIENCE_LINT_ORG_PATTERNS        entries one per line (a CI/CD or launcher-provided variable);
#   2. AUDIENCE_LINT_ORG_PATTERNS_FILE   a file of entries, one per line; when unset, the repository-local
#                                        .claude/audience-lint-org-patterns.txt of the project (CLAUDE_PROJECT_DIR,
#                                        else the git top level of the working directory) is used if it exists.
# Both sources are combined. Blank lines and '#' comment lines are skipped. An entry is one of:
#   <ERE>                                                    a plain pattern (no TAB), matched ignoring case;
#   re<TAB><category><TAB><cs|ci><TAB><ERE>                  a pattern with its category and case mode;
#   sealed<TAB><category><TAB><cs|ci><TAB><suffix><TAB><salt><TAB><hash>[,<hash>...]
#                                                            words the organisation keeps out of sight: each hash is the
#                                                            lowercase hex SHA-256 of "<salt>:<word>" (the word in lower
#                                                            case for ci). A word is a run of [A-Za-z0-9_] segments joined
#                                                            by '-'; with a suffix (an ERE starting with a character that
#                                                            cannot be part of a word, e.g. #[0-9]+) the word must be
#                                                            followed by it. The launcher writes this form, so a container
#                                                            never holds the names in clear text.
#   sealed-within<TAB><category><TAB><cs|ci><TAB><length><TAB><salt><TAB><hash>[,<hash>...]
#                                                            the same for names a pattern matched ANYWHERE inside a word
#                                                            (an unanchored literal): every stretch of <length> characters
#                                                            of each run of [A-Za-z0-9_-] is hashed and compared.
# Nothing here ever prints a pattern or a hash: a finding names the category and the matched text, which already sits
# in the scanned file. [CySec] Prevents CWE-200 (exposure of sensitive information): an organisation's pattern list
# names its customers and projects. [RiskMitigation RA-04]
#
# Usage (after sourcing this file):
#   al_org_patterns            -> the entries on stdout, normalised to the re/sealed forms, one per line; rc 1 (and
#                                 nothing printed) when none is configured; rc 2 (with a message) for an unreadable
#                                 named file or a malformed entry
#   al_org_scan FILE ENTRIES [OWN]
#                              -> one "<line>TAB<category>TAB<matched text>" line per organisation hit in FILE; a hit
#                                 that is, as a whole name, one of OWN (the output of al_org_own_names) is left out
#   al_org_own_names           -> the project's own names from KYKLOS_OWN_NAMES, lower case, one per line
#   al_org_patterns_notice     -> the ONE notice a caller prints (to stderr) when no organisation pattern is configured
# shell options: inherited from the caller (a sourced-only library; it never runs on its own).

AL_ORG_WORD_RUN='[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*'

# al_org_patterns_file -> the pattern file in effect (explicit, else the repository-local default), or nothing.
al_org_patterns_file() {
    if [ -n "${AUDIENCE_LINT_ORG_PATTERNS_FILE:-}" ]; then
        printf '%s' "$AUDIENCE_LINT_ORG_PATTERNS_FILE"
        return 0
    fi
    local top="${CLAUDE_PROJECT_DIR:-}"
    [ -n "$top" ] || top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] && [ -f "$top/.claude/audience-lint-org-patterns.txt" ] && printf '%s' "$top/.claude/audience-lint-org-patterns.txt"
    return 0
}

# _al_org_valid_ere ERE -> 0 when grep accepts ERE.
_al_org_valid_ere() { printf '' | grep -E -- "$1" >/dev/null 2>&1; [ "$?" -ne 2 ]; }

# _al_org_take N LINE -> 0 and the normalised entry on stdout when LINE is an entry, 1 for a blank/comment line, 2
# (with a message naming the entry's position, never its content) for a malformed entry: a malformed entry would
# otherwise never match, i.e. fail silently open.
_al_org_take() {
    local n="$1" line="${2%$'\r'}" kind cat mode rest suffix salt hashes h
    case "$line" in ''|'#'*) return 1 ;; esac
    _al_org_bad() { printf 'audience-lint: organisation entry %s is malformed (%s); fix the configured list\n' "$n" "$1" >&2; return 2; }
    if [ "${line#*$'\t'}" = "$line" ]; then
        _al_org_valid_ere "$line" || { _al_org_bad "not a valid extended regular expression"; return 2; }
        printf 're\t%s\tci\t%s\n' "organisation marker" "$line"
        return 0
    fi
    IFS=$'\t' read -r kind cat mode rest <<< "$line"
    case "$mode" in cs|ci) ;; *) _al_org_bad "the case mode must be cs or ci"; return 2 ;; esac
    [ -n "$cat" ] || { _al_org_bad "no category"; return 2; }
    case "$kind" in
        re)
            [ -n "$rest" ] && _al_org_valid_ere "$rest" || { _al_org_bad "not a valid extended regular expression"; return 2; }
            printf 're\t%s\t%s\t%s\n' "$cat" "$mode" "$rest" ;;
        sealed)
            # A suffix may be empty (the field is then empty between two TABs), so the fields are read by position.
            suffix="$(printf '%s' "$line" | cut -f4)"; salt="$(printf '%s' "$line" | cut -f5)"; hashes="$(printf '%s' "$line" | cut -f6)"
            printf '%s' "$salt" | grep -cxE '[0-9a-f]{32}' >/dev/null || { _al_org_bad "the salt must be 32 lowercase hex digits"; return 2; }
            [ -n "$hashes" ] || { _al_org_bad "no hash"; return 2; }
            for h in ${hashes//,/ }; do
                printf '%s' "$h" | grep -cxE '[0-9a-f]{64}' >/dev/null || { _al_org_bad "a hash must be 64 lowercase hex digits"; return 2; }
            done
            if [ -n "$suffix" ]; then
                _al_org_valid_ere "$suffix" || { _al_org_bad "the suffix is not a valid extended regular expression"; return 2; }
                case "$suffix" in [A-Za-z0-9_-]*) _al_org_bad "the suffix must not start with a word character"; return 2 ;; esac
            fi
            # The normalised form never leaves a field empty: no suffix is written as the word boundary \b.
            printf 'sealed\t%s\t%s\t%s\t%s\t%s\n' "$cat" "$mode" "${suffix:-\\b}" "$salt" "$hashes" ;;
        sealed-within)
            suffix="$(printf '%s' "$line" | cut -f4)"; salt="$(printf '%s' "$line" | cut -f5)"; hashes="$(printf '%s' "$line" | cut -f6)"
            printf '%s' "$suffix" | grep -cxE '[1-9][0-9]{0,2}' >/dev/null || { _al_org_bad "the length must be a whole number from 1 to 999"; return 2; }
            printf '%s' "$salt" | grep -cxE '[0-9a-f]{32}' >/dev/null || { _al_org_bad "the salt must be 32 lowercase hex digits"; return 2; }
            [ -n "$hashes" ] || { _al_org_bad "no hash"; return 2; }
            for h in ${hashes//,/ }; do
                printf '%s' "$h" | grep -cxE '[0-9a-f]{64}' >/dev/null || { _al_org_bad "a hash must be 64 lowercase hex digits"; return 2; }
            done
            printf 'sealed-within\t%s\t%s\t%s\t%s\t%s\n' "$cat" "$mode" "$suffix" "$salt" "$hashes" ;;
        *) _al_org_bad "unknown entry kind"; return 2 ;;
    esac
}

al_org_patterns() {
    local found=1 line file rc n=0 lines=()
    [ -n "${AUDIENCE_LINT_ORG_PATTERNS:-}" ] && mapfile -t lines <<< "$AUDIENCE_LINT_ORG_PATTERNS"
    file="$(al_org_patterns_file)"
    if [ -n "$file" ]; then
        # An explicitly named file that cannot be read is a configuration error, never a silent skip.
        if [ ! -r "$file" ]; then
            printf 'audience-lint: organisation patterns file not readable: %s\n' "$file" >&2
            return 2
        fi
        mapfile -t -O "${#lines[@]}" lines < "$file"
    fi
    local out="" entry sealed=0
    for line in ${lines[@]+"${lines[@]}"}; do
        n=$((n + 1))
        entry="$(_al_org_take "$n" "$line")"; rc=$?
        [ "$rc" -eq 2 ] && return 2
        [ "$rc" -eq 0 ] || continue
        found=0; out="$out$entry"$'\n'
        case "$entry" in sealed*) sealed=1 ;; esac
    done
    # [CySec] Prevents CWE-636 (not failing securely): sealed names can only be compared through a hash; without a
    # working hasher every comparison would miss, so the check refuses instead of passing unchecked.
    if [ "$sealed" -eq 1 ] && [ -z "$(_al_org_hasher)" ]; then
        printf 'audience-lint: the organisation list holds sealed names, which are compared through SHA-256, but neither perl with Digest::SHA nor sha256sum works here; refusing to pass unchecked (install one of them)\n' >&2
        return 2
    fi
    [ "$found" -eq 0 ] && printf '%s' "$out"
    return "$found"
}

# _al_org_hasher -> the hashing tool that works here ("perl" or "sha256sum"), proven on a known input, or nothing.
_al_org_hasher() {
    local want="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    if [ "$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex("abc")' 2>/dev/null)" = "$want" ]; then printf 'perl'
    elif [ "$(printf 'abc' | sha256sum 2>/dev/null | cut -d' ' -f1)" = "$want" ]; then printf 'sha256sum'
    fi
}

# _al_org_hash SALT -> for each word on stdin, "<word>TAB<sha256 hex of SALT:word>". One process for the whole list
# when perl's Digest::SHA is there; otherwise one sha256sum per word (same output, slower).
_al_org_hash() {
    if [ "$(_al_org_hasher)" = perl ]; then
        AL_ORG_SALT="$1" perl -MDigest::SHA=sha256_hex -ne 'chomp; print "$_\t", sha256_hex("$ENV{AL_ORG_SALT}:$_"), "\n"'
    else
        local w
        while IFS= read -r w; do
            printf '%s\t%s\n' "$w" "$(printf '%s:%s' "$1" "$w" | sha256sum | cut -d' ' -f1)"
        done
    fi
}

# _al_org_candidates FILE SUFFIX -> "<line>TAB<word>" for every word of FILE a sealed entry could name: every
# contiguous run of hyphen-joined segments of a word run (so "Name-source" also yields "Name"); with a SUFFIX only the
# word runs followed by it, and only the runs that end where the suffix starts.
_al_org_candidates() {
    local file="$1" suffix="$2" suffixed=1
    [ "$suffix" = '\b' ] && suffixed=
    LC_ALL=C grep -noE -- "${AL_ORG_WORD_RUN}${suffix}" "$file" 2>/dev/null \
        | LC_ALL=C awk -v suffixed="$suffixed" '{
            p = index($0, ":"); n = substr($0, 1, p - 1); s = substr($0, p + 1)
            match(s, /^[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*/); s = substr(s, 1, RLENGTH)
            k = split(s, seg, "-")
            for (i = 1; i <= k; i++) {
                w = ""
                for (j = i; j <= k; j++) {
                    w = (j == i) ? seg[j] : w "-" seg[j]
                    if (!suffixed || j == k) print n "\t" w
                }
            }
        }'
}

# _al_org_within_candidates FILE LENGTH -> "<line>TAB<stretch>" for every stretch of LENGTH characters of each run of
# [A-Za-z0-9_-] in FILE: an unanchored literal matched anywhere inside such a run, so every placement is tried.
_al_org_within_candidates() {
    LC_ALL=C grep -noE -- '[A-Za-z0-9_-]+' "$1" 2>/dev/null | LC_ALL=C awk -v len="$2" '{
        p = index($0, ":"); n = substr($0, 1, p - 1); s = substr($0, p + 1)
        for (i = 1; i + len - 1 <= length(s); i++) print n "\t" substr(s, i, len)
    }'
}

# _al_org_match CANDIDATES CATEGORY MODE SALT HASHES -> "<line>TAB<category>TAB<word>" for each candidate whose hash (in
# the entry's case mode: ci words in lower case) is one of HASHES.
_al_org_match() {
    local cands="$1" category="$2" mode="$3" salt="$4" hashes="$5" table status
    [ -n "$cands" ] || return 0
    # [CySec] Prevents CWE-636 "Not Failing Securely": the word table of a large file exceeds the size of one command-line
    # argument, so it travels in a file; a match that cannot run is reported as a finding, never as a clean answer.
    table="$(mktemp "${TMPDIR:-/tmp}/audience-lint.XXXXXX")" || { _al_org_unchecked "$category"; return 0; }
    printf '%s\n' "$cands" | cut -f2 | if [ "$mode" = ci ]; then tr 'A-Z' 'a-z'; else cat; fi | sort -u | _al_org_hash "$salt" > "$table"
    # A hasher that stops halfway, or a table that cannot be written, leaves nothing to compare: not a clean answer.
    status="$(printf '%s' "${PIPESTATUS[*]}" | tr -d ' 0')"
    if [ -n "$status" ] || [ ! -s "$table" ]; then
        rm -f -- "$table"
        _al_org_unchecked "$category"
        return 0
    fi
    printf '%s\n' "$cands" | LC_ALL=C awk -F'\t' -v ci="$([ "$mode" = ci ] && echo 1)" -v category="$category" -v hashes="$hashes" -v table="$table" '
        BEGIN { nh = split(hashes, hs, ","); for (i = 1; i <= nh; i++) want[hs[i]] = 1 }
        FILENAME == table { if ($2 in want) hit[$1] = 1; next }
        { w = ci ? tolower($2) : $2; if (w in hit) print $1 "\t" category "\t" $2 }' "$table" -
    status=$?
    rm -f -- "$table"
    [ "$status" -eq 0 ] || _al_org_unchecked "$category"
}

# _al_org_unchecked CATEGORY -> a finding on line 0: this file could not be checked against the category, so it is not clean.
_al_org_unchecked() {
    printf '0\t%s\t(not checked: the organisation patterns of this category could not run on this file)\n' "$1"
}

# al_org_own_names -> the project's own names, lower case, one per line, from KYKLOS_OWN_NAMES (';'-separated): the
# launcher setting, never a file of the repository. Only the shape a sealed word can have counts, so nothing that is
# not a plain whole name (a pattern, a blank, a non-ASCII letter) can widen the exemption.
# [CySec] Prevents CWE-636 (not failing securely): an unset, empty or malformed list exempts nothing.
al_org_own_names() {
    [ -n "${KYKLOS_OWN_NAMES:-}" ] || return 0
    printf '%s\n' "$KYKLOS_OWN_NAMES" | tr ';' '\n' | LC_ALL=C awk '
        { gsub(/^[ \t\r]+|[ \t\r]+$/, "") }
        /^[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*$/ { print tolower($0) }' | LC_ALL=C sort -u
}

# _al_org_drop_own FILE OWN WHOLE -> the hits on stdin without those that name one of OWN. WHOLE=1: the entry kind only
# ever matches whole words. WHOLE=0: a hit may sit inside a longer word, so it is kept when its line holds the name
# inside one: the name is exempt, a longer word that merely contains it is not.
_al_org_drop_own() {
    local file="$1" own="$2" whole="$3"
    if [ -z "$own" ]; then cat; return 0; fi
    LC_ALL=C awk -F'\t' -v file="$file" -v names="$(printf '%s' "$own" | tr '\n' ' ')" -v whole="$whole" '
        function embedded(text, name,   start, at, before, after) {
            start = 0
            while ((at = index(substr(text, start + 1), name)) > 0) {
                at += start
                before = at > 1 ? substr(text, at - 1, 1) : ""
                after = substr(text, at + length(name), 1)
                if (before ~ /[a-z0-9_]/ || after ~ /[a-z0-9_]/) return 1
                start = at
            }
            return 0
        }
        BEGIN {
            n = split(names, list, " "); for (i = 1; i <= n; i++) own[list[i]] = 1
            if (!whole) { lines = 0; while ((getline row < file) > 0) text[++lines] = tolower(row); close(file) }
        }
        {
            name = tolower($3)
            if (!(name in own)) { print; next }
            if (!whole && embedded(text[$1 + 0], name)) print
        }'
}

# al_org_scan FILE ENTRIES [OWN] -> "<line>TAB<category>TAB<matched text>" for every organisation hit in FILE, without
# the hits that are one of OWN as a whole name. A sealed entry with a suffix is never exempted: a name followed by an
# issue number is a reference into a tracker, not the name.
al_org_scan() {
    local file="$1" entries="$2" own="${3:-}" kind category mode a b c flag
    while IFS=$'\t' read -r kind category mode a b c; do
        case "$kind" in
            re)
                flag=-noE; [ "$mode" = ci ] && flag=-noiE
                {
                    grep "$flag" -- "$a" "$file" 2>/dev/null | awk -v category="$category" '{ p = index($0, ":"); print substr($0, 1, p - 1) "\t" category "\t" substr($0, p + 1) }'
                    # grep answers 1 for no match and more for a pattern or file it could not use.
                    [ "${PIPESTATUS[0]}" -le 1 ] || _al_org_unchecked "$category"
                } | _al_org_drop_own "$file" "$own" 0 ;;
            sealed)
                if [ "$a" = '\b' ]; then
                    _al_org_match "$(_al_org_candidates "$file" "$a")" "$category" "$mode" "$b" "$c" | _al_org_drop_own "$file" "$own" 1
                else
                    _al_org_match "$(_al_org_candidates "$file" "$a")" "$category" "$mode" "$b" "$c"
                fi ;;
            sealed-within) _al_org_match "$(_al_org_within_candidates "$file" "$a")" "$category" "$mode" "$b" "$c" | _al_org_drop_own "$file" "$own" 0 ;;
        esac
    done <<< "$entries"
}

al_org_patterns_notice() {
    printf '%s\n' "audience-lint: NOTICE no organisation-specific patterns are configured (set AUDIENCE_LINT_ORG_PATTERNS or add .claude/audience-lint-org-patterns.txt); only the generic patterns ran." >&2
}
