#!/usr/bin/env bash
# issue-api-detect.sh -- SHARED raw-issue-API-write detection primitives for the PreToolUse guards that police
# hand-crafted writes to the GitLab issues API:
#   * kyklos-agent-msg-guard.sh   -- COORDINATION issues (create/reply/reopen/close)  -> the `agent-msg` tool
#   * kyklos-tool-first-guard.sh  -- STORY issues (governance-labelled lifecycle)      -> the `story` tool
#   * kyklos-epic-gate-guard.sh   -- EPICS (milestone writes, an issue's milestone)    -> the epic verbs / `story epic`
#   * kyklos-proof-table-guard.sh -- PROOF TABLES (a proof note written by hand)       -> `story proof`
# ONE detector, one policy per guard (Non-Duplication): this file answers only the client-agnostic
# question "is this shell segment a raw WRITE to the issues API, and by what client/target/verb". It holds NO
# policy -- which labels/ops matter is each guard's business.
#
# HONEST SCOPE: pure string inspection of the command. A strong DETERRENT for the realistic clients (curl, wget,
# glab, python one-liners), NOT an airtight sandbox -- a compiled/bespoke client or a URL hidden in a shell
# variable can still slip. Accepted by design: the sanctioned tool is the path of least resistance, and every
# tool-made issue carries a marker label so an out-of-band one is detectable (reconciliation).
#
# Sourced (not executed). No `set -e` here -- callers own their shell options; the greps below are used as
# predicates and their non-zero exits are expected control flow.

# --- client detection ------------------------------------------------------------------------------------------
# The realistic raw-HTTP clients an agent reaches for: curl/wget (classic), glab (GitLab CLI), python(3)
# (urllib/requests), node (fetch/https). Word-boundaried so `mycurl` / `pythonic` / `nodes` do not match.
# The text before a client name: a start, a separator, or a program directory (/usr/bin/curl, /snap/bin/glab), so a
# client called by its absolute path is the same client. A name that only ends a longer path (docs/curl.md) is not.
IAD_CLIENT_PREFIX='(^|[^[:alnum:]_/]|/s?bin/)'
# Script runtimes that ship an HTTP client: PowerShell (Invoke-RestMethod / Invoke-WebRequest), ruby (Net::HTTP), perl
# (HTTP::Tiny, LWP), deno and bun (fetch). httpie (http, https) and xh are clients only as a command word followed by a
# blank, so a URL scheme (http://) is never one.
IAD_SCRIPT_CLIENTS='pwsh|powershell(\.exe)?|ruby|perl|deno|bun'
IAD_CLIENT_RE="${IAD_CLIENT_PREFIX}(curl|wget|glab|python3?|node|${IAD_SCRIPT_CLIENTS})([^[:alnum:]_]|\$)|${IAD_CLIENT_PREFIX}(https?|xhs?)[[:space:]]"

# iad_normalize_cmd <cmd> -- the command as the shell runs its program names and glab reads its words, for inspection:
# a backslash-newline is joined (a URL may be split over two lines), ANSI-C quoting is decoded ($'c\x75rl' runs curl), each
# word is unquoted the way the shell unquotes it (unquote-words.awk: c""url, "c"url, c'u'rl, "cu"'rl', c\url and \c\u\r\l
# all run curl), and glab's repository flag (-R / --repo with its value, also attached: -Ra/b) is dropped wherever it
# stands (glab -R a/b issue update runs the same write as glab issue update). The unquoted text of every quoted word the
# shell may run (the body of bash -c after any options, an eval string, a here-string, a piped echo, an ssh command; see
# unquote-words.awk) is normalised as a command line of its own, to a depth of three, and appended as further statements.
# Each guard that sources this file inspects this view, so no spelling of a program name or flag position needs its own rule.
# When the normaliser cannot run (awk, sed or unquote-words.awk is missing or broken, found by running a tiny known
# transform first) the detectors' own awk and sed cannot be trusted either: for a command that names a client, glab, a
# quote or a backslash nothing can be said, so the function prints IAD_NORMALISER_BROKEN and returns 1, and each guard
# refuses the command with a named reason (iad_refuse_broken_normaliser). Any other command passes through unchanged, so a
# broken install does not wedge every command.
# [CySec] CWE-436 (Interpretation Conflict): the guard reads a program name and a flag the way the shell and glab do.
# [CySec] CWE-636 (Not Failing Securely): a broken normaliser refuses; it never reads the command as written.
IAD_NORMALISER_BROKEN='@@IAD:NORMALISER_BROKEN@@'
_IAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
iad_normaliser_healthy() {
    [ "$(printf '%s' 'c"u"\rl' | awk -f "$_IAD_LIB_DIR/unquote-words.awk" 2>/dev/null)" = "curl" ] \
        && [ "$(printf '%s' 'glab -R a/b issue' | sed -E 's/(glab|issue)([[:space:]]+((-R|--repo)([[:space:]]+|=)|-R)[^[:space:];|&]+)+/\1/g' 2>/dev/null)" = "glab issue" ] \
        && [ "$(printf '%s' 'ab' | awk '{ print length($0) }' 2>/dev/null)" = "2" ]
}
iad_normalize_cmd() {
    local in="$1" depth="${_IAD_NORM_DEPTH:-0}" s lit u extras extra n=0
    s="${in//\\$'\n'/}"
    while [[ $s =~ \$\'([^\']*)\' ]]; do
        lit="$(printf '%b' "${BASH_REMATCH[1]}" 2>/dev/null | tr -d '\000')"
        s="${s/"${BASH_REMATCH[0]}"/$lit}"
    done
    if { [ "$depth" -gt 0 ] || iad_normaliser_healthy; } \
        && u="$(printf '%s' "$s" | awk -f "$_IAD_LIB_DIR/unquote-words.awk" 2>/dev/null)" \
        && s="$(printf '%s' "${u%%$'\002'*}" | sed -E \
            -e 's/(glab|issue)([[:space:]]+((-R|--repo)([[:space:]]+|=)|-R)[^[:space:];|&]+)+/\1/g' 2>/dev/null)"; then
        :
    else
        if [[ $in == *[\'\"\\]* || $in == *glab* || $in =~ $IAD_CLIENT_RE ]]; then printf '%s' "$IAD_NORMALISER_BROKEN"; return 1; fi
        printf '%s' "$in"; return 0
    fi
    if [ "$depth" -lt 3 ] && [[ $u == *$'\002'* ]]; then
        extras="${u#*$'\002'}"
        while [ -n "$extras" ] && [ "$n" -lt 40 ]; do
            extra="${extras%%$'\002'*}"
            if [[ $extras == *$'\002'* ]]; then extras="${extras#*$'\002'}"; else extras=""; fi
            n=$((n + 1))
            u="$(_IAD_NORM_DEPTH=$((depth + 1)) iad_normalize_cmd "$extra")" || { printf '%s' "$IAD_NORMALISER_BROKEN"; return 1; }
            s+=$'\n'"$u"
        done
    fi
    printf '%s' "$s"
}

# iad_refuse_broken_normaliser <guard label> -- the block decision a guard prints when iad_normalize_cmd answered
# IAD_NORMALISER_BROKEN, so a broken install refuses instead of letting a spelled command through unread.
iad_refuse_broken_normaliser() {
    printf '{"decision":"block","reason":"BLOCKED (%s): the command normaliser could not run (awk, sed or unquote-words.awk is missing or broken), so this command with quotes, backslashes or glab cannot be inspected. Repair or reinstall the kyklos plugin, then retry."}' "$1"
}

# --- HTTP write-verb detection (curl / wget) -------------------------------------------------------------------
# A WRITE (create/mutate), never a bare GET: an explicit method, a body/form flag, or a GitLab state transition.
IAD_HTTP_WRITE_RE='(-X[[:space:]="'"'"']*(POST|PUT|DELETE)|--request[[:space:]="'"'"']*(POST|PUT|DELETE)|--method[[:space:]="'"'"']*(POST|PUT|DELETE)|(^|[[:space:]])(-d|-F)([[:space:]]|=|$)|--data(-urlencode|-binary|-raw|-ascii)?([[:space:]]|=|$)|--form([[:space:]]|=|$)|--(body-data|post-data|post-file)([[:space:]]|=|$)|state_event[[:space:]=]*(close|reopen))'

# --- glab write-subcommand detection ---------------------------------------------------------------------------
# glab has TWO write surfaces: the `glab issue <verb>` porcelain (below) AND the `glab api` REST passthrough
# (handled by IAD_GLAB_API_FIELD_RE + the glab-api arm in iad_seg_is_raw_issue_write). NOTE: `glab api` is NOT
# caught by the curl/wget HTTP arm (that arm requires the curl|wget keyword), so it needs its own arm.
IAD_GLAB_WRITE_RE='glab[[:space:]]+issue[[:space:]]+(create|new|note|comment|close|reopen|update|edit|delete|subscribe|label)'
# `glab api` REST write to /issues: a mutating --method/-X (via IAD_HTTP_WRITE_RE) OR a field flag. glab api defaults
# to POST the moment a -f/--field/--raw-field is present, so a field flag alone (no explicit method) IS a write.
IAD_GLAB_API_FIELD_RE='(^|[[:space:]])(-f|--field|--raw-field)([[:space:]]|=)'

# --- node write-hint detection ---------------------------------------------------------------------------------
# A node snippet that WRITES: an explicit mutating method (fetch/https options), an https.request/http.request call,
# or a .post( helper. Paired with a /issues target this indicates a raw issue write.
IAD_NODE_WRITE_RE='(method\\?['"'"'"]?[[:space:]]*:[[:space:]]*\\?['"'"'"`](POST|PUT|DELETE)|https?\.request\(|\.post\()'

# --- python write-hint detection -------------------------------------------------------------------------------
# A python snippet that WRITES via urllib/requests: a requests.post/put/delete, an explicit method=, a urlopen
# with a body, or a data= body. Paired with a /issues target this indicates a raw issue write.
IAD_PY_WRITE_RE='(\.(post|put|patch|delete|request)\(|requests\.(post|put|delete)|method[[:space:]]*=[[:space:]]*['"'"'"](POST|PUT|DELETE)|urlopen\(|(^|[^[:alnum:]_])data[[:space:]]*=)'

# iad_split_segments <cmd> -- emit the command split into shell STATEMENT segments (on ; && || and newline), so a
# guard evaluates client+target+verb as CO-OCCURRING in ONE statement, never smeared across an unrelated command
# (e.g. an OpenBao `-d` login beside a later `/issues` GET). Bare `|` is NOT a split point (a body piped into a
# create stays one segment). Over-splitting only ever makes a guard MORE permissive (fail-open).
# The split follows the shell: a backslash-newline continues the statement, and `;`, `&&`, `||` or a newline inside
# quotes (an issue title `a; b`, a multi-line body) or escaped with a backslash is text, not a statement end. A newline
# inside quotes becomes a blank so the statement stays on one line.
# IAD_AWK_SHELL_SCAN -- awk functions shared by the statement splitter and the client-words cut, so both follow the
# shell the same way. shscan(s) fills, for every character i of s: D[i] = the nesting depth of command substitutions
# and subshells ($( ), ( ), backticks) it sits in, and A[i] = 1 for a character the shell acts on at that depth
# (outside quotes, not escaped), 2 for a closing ) or backtick, 3 for an opening one, 0 otherwise (quoted, escaped, or
# the backslash itself). A backslash escapes the next character outside quotes and inside double quotes; single quotes
# escape nothing; a substitution inside double quotes is active and starts its own quoting. A parameter expansion
# ${ ... } is its own context: a ( or ) inside it opens or closes nothing (${Z#(}), a nested $( ) still does. A | right
# after > (>|, 2>|: the noclobber override) belongs to the redirect, it is no pipe.
IAD_AWK_SHELL_SCAN='
function shscan(s,   i, c, n, q, sp, esc) {
    n = length(s); q = ""; sp = 0; esc = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); D[i] = sp; A[i] = 0; QQ[i] = q
        if (esc) { esc = 0; continue }
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (c == "\\") { esc = 1; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") { A[i] = 3; sp++; ST[sp] = "("; SQ[sp] = q; q = ""; i++; D[i] = sp; A[i] = 0; QQ[i] = q; continue }
        if (c == "$" && substr(s, i + 1, 1) == "{") { A[i] = 3; sp++; ST[sp] = "{"; SQ[sp] = q; q = ""; i++; D[i] = sp; A[i] = 0; QQ[i] = q; continue }
        if (sp > 0 && ST[sp] == "{" && q == "") { if (c == "}") { A[i] = 2; q = SQ[sp]; sp--; continue }
                                                  if (c == "(" || c == ")") continue }
        if (c == "`") { if (sp > 0 && ST[sp] == "`" && q == "") { A[i] = 2; q = SQ[sp]; sp-- } else { A[i] = 3; sp++; ST[sp] = "`"; SQ[sp] = q; q = "" }; continue }
        if (q == "\"") { if (c == "\"") q = ""; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "(") { A[i] = 3; sp++; ST[sp] = "("; SQ[sp] = ""; continue }
        if (c == ")") { if (sp > 0 && ST[sp] == "(") { A[i] = 2; q = SQ[sp]; sp-- } else A[i] = 1; continue }
        if (c == "|" && i > 1 && substr(s, i - 1, 1) == ">" && A[i - 1] == 1) continue
        A[i] = 1 }
    N = n }
'
IAD_CLIENT_REDEF_RE='(^|[^[:alnum:]_./-])(curl|wget)[[:space:]]*\(\)|function[[:space:]]+(curl|wget)([[:space:]({]|$)|alias[[:space:]](.*[[:space:]])?(curl|wget)='
# [RiskMitigation RA-02] Statements and words are split the way the shell splits them, so quoting, substitutions and redirects cannot hide a write (CWE-436).
iad_split_segments() {
    local cmd="${1//\\$'\n'/}"   # a backslash-newline continues the word: the shell joins it with nothing between
    # A command that defines a curl or wget function or alias runs that definition, not the client, in a later statement:
    # every statement that names the client is marked, so its words are no known text (iad_http_client_words).
    local redef=0
    printf '%s' "$cmd" | grep -Ec "$IAD_CLIENT_REDEF_RE" >/dev/null && redef=1
    printf '%s' "$cmd" | awk "$IAD_AWK_SHELL_SCAN"'
        BEGIN { RS = "\001" }
        { shscan($0); out = ""
          for (i = 1; i <= N; i++) { c = substr($0, i, 1); d = substr($0, i + 1, 1)
              if (A[i] == 1 && D[i] == 0) {
                  if (c == ";" || c == "\n") { out = out "\n"; continue }
                  if ((c == "&" && d == "&" && A[i + 1] == 1) || (c == "|" && d == "|" && A[i + 1] == 1)) { out = out "\n"; i++; continue }
              }
              if (c == "\n") c = " "
              out = out c }
          printf "%s", out }' | if [ "$redef" = 1 ]; then sed -E "\\%${IAD_CLIENT_PREFIX}(curl|wget)([^[:alnum:]_]|\$)%s/^/@@IAD:redef@@ /"; else cat; fi
}

# --- per-segment target predicates (return 0 = matches) --------------------------------------------------------
# iad_route_norm <text> -- the text with routes spelled the way the server reads them: a percent-encoded unreserved
# character decoded (`/%69ssues`, `/is%73ues`), `//` and `/./` collapsed, a `/.` before the route's end dropped.
_iad_pct_sed=""
for _iad_c in a b c d e f g h i j k l m n o p q r s t u v w x y z A B C D E F G H I J K L M N O P Q R S T U V W X Y Z 0 1 2 3 4 5 6 7 8 9 - . _ '~'; do
    _iad_pct_sed="${_iad_pct_sed}s/%$(printf '%02X' "'$_iad_c")/${_iad_c}/gI;"
done
unset _iad_c
# A `..` segment removes the segment before it, as curl and the server resolve it (`/issues/1/..` is `/issues`); a
# percent-encoded dot is decoded first.
iad_route_norm() {
    printf '%s' "$1" | sed -E "${_iad_pct_sed}"'s#/+#/#g; s#/(\./)+#/#g; s#/\.([^A-Za-z0-9_.-]|$)#\1#g' \
        | sed -E ':a; s#/[^/[:space:]"'"'"'.][^/[:space:]"'"'"']*/\.\.(/|[^A-Za-z0-9_.-]|$)#\1#; ta; s#/+#/#g'
}
# create-target: the `/issues` collection, NOT `/issues/<n>` (an item). The route ends at anything that is not a
# letter, digit, `_` or `-` (a quote, ?, ), |, >, &, a backtick, a blank, a backslash, a format suffix `.json`/`.xml`,
# `%`, or the end); `/issues/` is the same collection route, `/issues/<n>` an item.
IAD_ISSUES_COLLECTION_RE='/issues([^A-Za-z0-9_/-]|/([^0-9]|$)|$)'
iad_seg_hits_issues_collection() { iad_route_norm "$1" | grep -Ec "$IAD_ISSUES_COLLECTION_RE" >/dev/null; }
# An issue number written as a placeholder a program fills in: a format field ({iid}, {0}), a shell variable ($IID,
# ${IID}), a printf directive (%s, %d) or a route parameter (:iid). Only a route that goes on past the placeholder
# (`/issues/{iid}/notes`) names an existing issue: a placeholder that ends the route may be empty, and an empty one
# leaves the issues collection (`/issues/$E` with E unset is `/issues/`), so it counts as the collection.
IAD_ISSUE_PLACEHOLDER_RE='\{[A-Za-z0-9_][^}/]*\}|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*|%[sdi]|:[A-Za-z_][A-Za-z0-9_]*'
# edit-target: `/issues/<n>` (a specific issue -- close/reopen/update), the number literal or a placeholder.
iad_seg_hits_issue_item()        { iad_route_norm "$1" | grep -Ec "/issues/([0-9]|(${IAD_ISSUE_PLACEHOLDER_RE})/[A-Za-z0-9_])" >/dev/null; }
# iad_seg_has_collection_route <seg> -- TRUE (0) if at least one issues route in the segment is the collection: each
# route is judged on its own, so a segment that names an existing issue (`/issues/1`) and also the collection
# (`/issues`) still reaches the collection.
iad_seg_has_collection_route() {
    iad_route_norm "$1" | grep -oE "/issues([^A-Za-z0-9_-][^[:space:]\"'\`]*)?" \
        | grep -vEc "^/issues/([0-9]|(${IAD_ISSUE_PLACEHOLDER_RE})/[A-Za-z0-9_])" >/dev/null
}
# reply-target: `/issues/<n>/notes` (a note == a reply; also `/notes/<id>`, the edit of one note).
iad_seg_hits_notes()             { iad_route_norm "$1" | grep -Ec "/issues/([0-9]+|${IAD_ISSUE_PLACEHOLDER_RE})/notes" >/dev/null; }

# --- per-segment client predicates -----------------------------------------------------------------------------
iad_seg_has_curl() { printf '%s' "$1" | grep -Ec "${IAD_CLIENT_PREFIX}curl([^[:alnum:]_]|\$)" >/dev/null; }
iad_seg_has_curl_wget() { printf '%s' "$1" | grep -Ec "${IAD_CLIENT_PREFIX}(curl|wget)([^[:alnum:]_]|\$)" >/dev/null; }
iad_seg_has_python()    { printf '%s' "$1" | grep -Ec "${IAD_CLIENT_PREFIX}python3?([^[:alnum:]_]|\$)" >/dev/null; }
iad_seg_has_glab()      { printf '%s' "$1" | grep -Ec "${IAD_CLIENT_PREFIX}glab([^[:alnum:]_]|\$)" >/dev/null; }
iad_seg_has_node()      { printf '%s' "$1" | grep -Ec "${IAD_CLIENT_PREFIX}node([^[:alnum:]_]|\$)" >/dev/null; }

# iad_seg_is_raw_issue_write <seg> -- TRUE (0) if the segment is a raw WRITE to the issues API by ANY supported
# client, regardless of the specific op. Composition (each arm requires the CLIENT and a WRITE to co-occur):
#   (glab issue write-subcommand)  OR  (glab api + /issues target + write-verb or -f/--field)  OR
#   (python + /issues target + python write-hint)  OR  (node + /issues target + node write-hint)  OR
#   (curl/wget + /issues target + HTTP write-verb).
# A guard uses this as the CLIENT/TRANSPORT gate, then applies its OWN policy discriminator (labels/op).
iad_seg_is_raw_issue_write() {
    local seg="$1"
    # glab: the subcommand IS both the client, the target (an issue) and the write.
    printf '%s' "$seg" | grep -Ec "$IAD_GLAB_WRITE_RE" >/dev/null && return 0
    # everything else must name the /issues endpoint (as the server reads the route).
    iad_route_norm "$seg" | grep -Ec '/issues' >/dev/null || return 1
    # glab api REST passthrough (client=glab, NOT the `glab issue` porcelain): a write to /issues via a mutating
    # method OR a -f/--field flag. The curl/wget arm below requires curl|wget, so this glab-only form needs its own arm.
    if printf '%s' "$seg" | grep -Ec 'glab[[:space:]]+api' >/dev/null; then
        printf '%s' "$seg" | grep -Eic "$IAD_HTTP_WRITE_RE" >/dev/null && return 0
        printf '%s' "$seg" | grep -Ec "$IAD_GLAB_API_FIELD_RE" >/dev/null && return 0
    fi
    # python urllib/requests write.
    if iad_seg_has_python "$seg" && printf '%s' "$seg" | grep -Ec "$IAD_PY_WRITE_RE" >/dev/null; then return 0; fi
    # node fetch/https write.
    if iad_seg_has_node "$seg" && printf '%s' "$seg" | grep -Ec "$IAD_NODE_WRITE_RE" >/dev/null; then return 0; fi
    # curl/wget HTTP write, judged on the client's own arguments (iad_http_words_write): a data flag beside -G/--get only
    # builds a GET's query string (a search), so it writes nothing unless a mutating method or an upload is also named.
    # A GitLab state transition (state_event=close|reopen) anywhere in the segment still counts, as before.
    if iad_seg_has_curl_wget "$seg"; then
        iad_http_words_write "$(iad_http_client_words "$seg")" "$seg" && return 0
        printf '%s' "$seg" | grep -Eic 'state_event[[:space:]=]*(close|reopen)' >/dev/null && return 0
    fi
    return 1
}

# --- the HTTP method of a write ---------------------------------------------------------------------------------
# Only a POST creates an issue. A write that names its method, and names only methods other than POST (PUT, PATCH,
# DELETE, GET, HEAD), creates nothing even at the issues collection. A method the command does not show (a variable, a
# config file, a POST implied by a body) is no named method, so such a write stays a creation.
IAD_NAMED_POST_RE='(method[[:space:]]*[=:][[:space:]]*\\?['"'"'"`]POST|\.post\(|\.request\([[:space:]]*['"'"'"]POST|(-X|--request|--method)[[:space:]="'"'"']*POST)'
IAD_NAMED_OTHER_METHOD_RE='(method[[:space:]]*[=:][[:space:]]*\\?['"'"'"`](GET|HEAD|PUT|PATCH|DELETE)['"'"'"`\\]|\.(get|head|put|patch|delete)\(|\.request\([[:space:]]*['"'"'"](GET|HEAD|PUT|PATCH|DELETE)['"'"'"]|(-X|--request|--method)[[:space:]="'"'"']*(GET|HEAD|PUT|PATCH|DELETE)([[:space:]"'"'"']|$))'
# A method given by a name the reader cannot see: method=m, method: m, -X "$M".
IAD_UNSEEN_METHOD_RE='(method[[:space:]]*[=:][[:space:]]*[A-Za-z_$({]|(-X|--request|--method)[[:space:]="'"'"']*[$`(])'
# iad_seg_names_non_post_method <seg> -- TRUE (0) when every write in the segment names its method and none is POST.
# A curl or wget request is judged on its own words (quotes removed, so a header text holding "-X PUT" is no method);
# a program (python, node, glab api) on its text. Anything not shown, or a POST anywhere, answers FALSE.
iad_seg_names_non_post_method() {
    local seg="$1" cl get hid unk meth w named=0
    printf '%s' "$seg" | grep -Eic "$IAD_UNSEEN_METHOD_RE" >/dev/null && return 1
    if iad_seg_has_curl_wget "$seg"; then
        while IFS=$'\t' read -r cl get hid unk meth w; do
            # curl sends the last method named; a config file or a word the command does not show may name another.
            [ "$cl" = curl ] && [ "$unk" = 0 ] || return 1
            printf '%s' "$w" | grep -Ec "$IAD_CURL_HIDDEN_RE" >/dev/null && return 1
            case "$meth" in GET|HEAD|PUT|PATCH|DELETE) named=1 ;; *) return 1 ;; esac
        done < <(iad_http_requests "$(iad_http_client_words "$seg")")
        [ "$named" = 1 ] || return 1
        { iad_seg_has_python "$seg" || iad_seg_has_node "$seg" || iad_seg_has_glab "$seg"; } || return 0
    fi
    printf '%s' "$seg" | grep -Eic "$IAD_NAMED_POST_RE" >/dev/null && return 1
    printf '%s' "$seg" | grep -Eic "$IAD_NAMED_OTHER_METHOD_RE" >/dev/null
}
# iad_seg_is_issue_graphql_create <seg> -- TRUE (0) if the segment holds GitLab's GraphQL issue-creation mutation
# (createIssue), which needs no /issues route.
# iad_decode_body_escapes <text> -> <text> with the escapes a request body may use decoded: JSON \uXXXX (behind any
# number of backslashes) and form %XX, so an escaped name (create\u0049ssue, create%49ssue) reads as written. When
# more than 200 escapes are left the text is returned with the marker @@IAD:undecoded@@, read as unreadable.
iad_decode_body_escapes() {
    local t="$1" n=0 h
    while [[ "$t" =~ \\+u([0-9A-Fa-f]{4}) ]] && [ "$n" -lt 200 ]; do
        h="${BASH_REMATCH[1]}"; t="${t/"${BASH_REMATCH[0]}"/$(printf "\\u$h")}"; n=$((n + 1))
    done
    while [[ "$t" =~ %([0-9A-Fa-f]{2}) ]] && [ "$n" -lt 200 ]; do
        h="${BASH_REMATCH[1]}"; t="${t/"${BASH_REMATCH[0]}"/$(printf "\\x$h")}"; n=$((n + 1))
    done
    [ "$n" -ge 200 ] && t+=" @@IAD:undecoded@@"
    printf '%s' "$t"
}
# Quotes and backslashes are dropped before the names are matched, so a name split by quoting (create""Issue) is the
# same name. Both GitLab creations count: createIssue and workItemCreate.
iad_seg_is_issue_graphql_create() {
    local t
    t="$(iad_decode_body_escapes "$1" | tr -d '"'"'"'\\')"
    printf '%s' "$t" | grep -Eic 'mutation' >/dev/null && printf '%s' "$t" | grep -Ec '(createIssue|workItemCreate)' >/dev/null
}
# iad_seg_is_opaque_graphql_write <seg> -- TRUE (0) if the segment sends a write to the GraphQL endpoint whose document
# the command does not show (a body file -d @q.json, a substitution, a variable: -f query="$Q"): what it creates cannot
# be told, so it counts as a creation. A document written out in the command (query { ... }) is judged by its text.
iad_seg_is_opaque_graphql_write() {
    local seg="$1"
    iad_route_norm "$seg" | grep -Eic '(/graphql([^A-Za-z0-9_-]|$)|glab[[:space:]]+api[[:space:]]+graphql)' >/dev/null || return 1
    if printf '%s' "$seg" | grep -Ec 'glab[[:space:]]+api[[:space:]]+graphql' >/dev/null; then :
    elif iad_seg_has_curl_wget "$seg" && iad_http_words_write "$(iad_http_client_words "$seg")" "$seg"; then :
    else return 1; fi
    # [CySec] CWE-284: a mutation whose text cannot be fully decoded may name a creation; it is refused.
    iad_decode_body_escapes "$seg" | grep -Eic 'mutation' >/dev/null && iad_decode_body_escapes "$seg" | grep -Ec '@@IAD:undecoded@@' >/dev/null && return 0
    # [CySec] CWE-284: a GraphQL body the reader cannot see may hold a creation; it is refused, not trusted.
    ! printf '%s' "$seg" | tr -d '"'"'"'\\' | grep -Eic '(query|mutation)[[:space:]]*[A-Za-z0-9_]*[[:space:]]*[({]|query[[:space:]]*[:=][[:space:]]*\{' >/dev/null
}

# iad_cmd_is_issue_create <cmd> -- TRUE (0) if ANY statement of the command creates an issue. Besides the per-segment
# test, a python or node program split at its own `;` (python3 -c "import x; x.post(.../issues)") is caught: when the
# command starts python/node anywhere, a segment that carries that language's STRONG write hint (an explicit post/put,
# a mutating method, urlopen; never a bare `data=`, which a read's query string can carry) at an issues collection counts.
IAD_PY_STRONG_WRITE_RE='(\.(post|put|request)\(|requests\.(post|put)|method[[:space:]]*=[[:space:]]*\\?['"'"'"](POST|PUT)|urlopen\()'
iad_cmd_is_issue_create() {
    local cmd="$1" seg py=1 nd=1 client=1
    iad_seg_has_python "$cmd" && py=0
    iad_seg_has_node "$cmd" && nd=0
    printf '%s' "$cmd" | grep -Ec "$IAD_CLIENT_RE" >/dev/null && client=0
    while IFS= read -r seg || [ -n "$seg" ]; do
        [ -n "$seg" ] || continue
        iad_seg_is_issue_create "$seg" && return 0
        # A GraphQL creation sent by any client the command starts (a program split at its own ; included).
        [ "$client" = 0 ] && iad_seg_is_issue_graphql_create "$seg" && return 0
        iad_seg_has_collection_route "$seg" || continue
        iad_seg_names_non_post_method "$seg" && continue
        [ "$py" = 0 ] && printf '%s' "$seg" | grep -Ec "$IAD_PY_STRONG_WRITE_RE" >/dev/null && return 0
        [ "$nd" = 0 ] && printf '%s' "$seg" | grep -Ec "$IAD_NODE_WRITE_RE" >/dev/null && return 0
    done < <(iad_split_segments "$cmd")
    return 1
}

# iad_seg_is_issue_create <seg> -- TRUE (0) if the segment CREATES an issue: a raw write (iad_seg_is_raw_issue_write)
# aimed at an issues COLLECTION (`.../issues` not followed by `/<n>`, so not an edit/close/note of an existing issue),
# or the glab porcelain `glab issue create|new`. URL-encoded project paths (group%2Fproject) match like ids. Label-
# and policy-agnostic: an issue is created only through the sanctioned tools, whatever it is meant to be.
iad_seg_is_issue_create() {
    local seg="$1"
    printf '%s' "$seg" | grep -Ec 'glab[[:space:]]+issue[[:space:]]+(create|new)([^[:alnum:]_-]|$)' >/dev/null && return 0
    iad_seg_is_issue_graphql_create "$seg" && printf '%s' "$seg" | grep -Ec "$IAD_CLIENT_RE" >/dev/null && return 0
    iad_seg_is_opaque_graphql_write "$seg" && return 0
    iad_seg_is_raw_issue_write "$seg" || return 1
    iad_seg_has_collection_route "$seg" || return 1
    # [CySec] CWE-284: the route and the method decide a creation, never the word "issues": a write that names only
    # methods other than POST creates nothing; a method the command does not show still counts as a creation.
    iad_seg_names_non_post_method "$seg" && return 1
    return 0
}

# --- milestone (epic) writes -----------------------------------------------------------------------------------
# An epic is a GitLab milestone; the sanctioned path is the bridge's epic verbs (the `story epic ...` commands). These
# predicates answer only "does this command WRITE a milestone, or set an issue's milestone, by hand"; the policy is
# kyklos-epic-gate-guard.sh's.
# A milestones endpoint: a project's or group's `/milestones` collection or one milestone (`/milestones/<n>`).
iad_seg_hits_milestones() { iad_route_norm "$1" | grep -Ec '/milestones([^A-Za-z0-9_-]|$)' >/dev/null; }
# The client's own arguments: what follows each curl/wget word up to the first pipe at the client's own depth, or the )
# or backtick that closes the substitution the client runs in (R=$(curl ... URL) ends at the paren). Pipes inside
# quotes, escaped (x\|y), or inside a nested $( ) or backticks are no cut, so a write flag after them stays in view.
# Each client's words are led by a marker word naming it (@@IAD:curl@@ or @@IAD:wget@@), because the two read -G
# differently, and by --config=@env when a config home (CURL_HOME, HOME, XDG_CONFIG_HOME, WGETRC) is assigned before it.
# A client word inside another client's words (a header value, an output file name) is no new client.
iad_http_client_words() {
    printf '%s' "$1" | awk -v re="${IAD_CLIENT_PREFIX}(curl|wget)([^[:alnum:]_]|\$)" "$IAD_AWK_SHELL_SCAN"'
        BEGIN { RS = "\001"
                split("if then else elif do while until ! { time sudo env nohup command exec builtin nice ionice timeout stdbuf", K, " ")
                for (k in K) plain[K[k]] = 1 }
        # known_launch(s, cp, d): 1 when the client word at cp is run by the shell as written: not inside quotes (bash -c
        # "...", ssh "...", a body text), and led in its pipe piece only by assignments, redirects, keywords and launchers
        # that pass their words through unchanged (sudo, env, timeout 5, nice -n 5, ...). Anything else (xargs, find
        # -exec, parallel, eval, watch, ...) may append or re-read words, so the request is not known text.
        function known_launch(s, cp, d,   k, ch, pre, nw, PW) {
            if (QQ[cp] != "") return 0
            pre = ""
            for (k = cp - 1; k >= 1; k--) { if (D[k] < d) break; ch = substr(s, k, 1)
                if (D[k] == d && A[k] == 1 && ch ~ /[|;&\n]/) break
                pre = ((D[k] > d || QQ[k] != "") ? "Q" : ch) pre }
            sub(/[^ \t\n]*$/, "", pre)
            nw = split(pre, PW, /[ \t\n]+/)
            for (k = 1; k <= nw; k++) { if (PW[k] == "" || PW[k] in plain) continue
                if (PW[k] ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ || PW[k] ~ /^-/ || PW[k] ~ /^[0-9][0-9.]*[smhd]?$/ || PW[k] ~ /^[0-9]*[<>]/) continue
                return 0 }
            return 1 }
        { shscan($0); s = $0; pos = 1; cover = 0; redef = (s ~ /@@IAD:redef@@/)
          while (pos <= N && match(substr(s, pos), re)) {
              p = pos + RSTART - 1; e = p + RLENGTH; m = substr(s, p, RLENGTH); pos = e
              if (p < cover) continue
              cp = p + (substr(s, p, 1) ~ /[cw\/]/ ? 0 : 1); while (cp <= N && substr(s, cp, 1) !~ /[cw]/) cp++
              d = D[cp]; cl = (m ~ /wget/) ? "wget" : "curl"
              unk = (redef || !known_launch(s, cp, d)) ? " @@IAD:unknown@@" : ""
              for (j = e; j <= N; j++) {
                  if (D[j] == d && A[j] == 2) break
                  if (D[j] == d && A[j] == 1 && substr(s, j, 1) == "|") break }
              cfg = (substr(s, 1, p) ~ /(^|[^A-Za-z0-9_])(CURL_HOME|HOME|XDG_CONFIG_HOME|WGETRC|SYSTEM_WGETRC)=/) ? " --config=@env" : ""
              w = substr(s, e, j - e); gsub(/\n/, " ", w)
              printf " @@IAD:%s@@%s%s %s", cl, cfg, unk, w
              cover = j } }'
}
# Write flags, looked for in every word of a request (also a word another option takes as its value: that only ever
# refuses more): --json implies POST, -T/--upload-file PUT, any --data*/--form* (--form-string too), --expand-data, and
# wget's --post-data/--body-data/--post-file; plus the short options curl accepts attached or in a cluster: an attached
# value (-d@file, -dtitle=x, -Ffile=@f, -Tup.json), a cluster ending in a data flag (-sd 'title=x') or an upload flag
# (-sT file), and a method flag ending a cluster (-sXDELETE, -XPOST). Letters are matched case-sensitively (-D dumps
# headers and -f fails on error, they write nothing).
IAD_CURL_LONG_WRITE_RE='(^|[[:space:]])--(json|upload-file|data[a-z-]*|expand-data|form[a-z-]*|body-data|post-data|post-file)([[:space:]]|=|$)'
IAD_CURL_SHORT_WRITE_RE='(^|[[:space:]])-[sSLkvViIOfgGjlnNpqRZ0-9#]*([dFT]|X[[:space:]="'"'"']*(POST|PUT|DELETE))'
IAD_CURL_METHOD_RE='(-X|--request|--method)[[:space:]="'"'"']*(POST|PUT|DELETE)'
IAD_CURL_UPLOAD_RE='(^|[[:space:]])(--upload-file|-[A-Za-z]*T)([[:space:]=]|[^[:space:]]|$)'
# A multipart form (-F, --form, --form-string) is a POST even beside -G: curl moves only -d/--data*/--json into the
# query string.
IAD_CURL_FORM_RE='(^|[[:space:]])(--form[a-z-]*([[:space:]]|=|$)|-[sSLkvViIOfgGjlnNpqRZ0-9#]*F)'
# What the command does not show counts as a write: a method held in a variable or a command substitution (-X "$M"),
# or a config file (-K file, --config file, also -K - whose lines are not read here) that may carry a body or a method.
IAD_CURL_HIDDEN_RE='((-X|--request|--method)[[:space:]="'"'"']*[$`]|(^|[[:space:]])(--config([[:space:]]|=|$)|--expand-(request|json|form[a-z-]*|upload-file|config)([[:space:]]|=|$)|-[sSLkvViIOfgGjlnNpqRZ0-9#]*K))'
# iad_http_requests <words> -- split the client words into requests, one line each:
# "<client><TAB><get><TAB><hidden><TAB><unknown><TAB><method><TAB><words>". <hidden> is 1 when the request names a
# method other than GET or HEAD, or one it does not show; <unknown> is 1 when the words cannot be read for sure (an
# expansion, a rewritten word, an ambiguous request), so the method may differ from the one shown; <method> is the
# last method named as written, or "-".
# A request starts at each client marker and at curl's --next (or -:), because options do not carry across --next.
# Words are read as the shell splits them: quotes group, a backslash escapes the next character (also a blank, so
# `title=x\ -G` is one word), an escaped quote inside double quotes does not close them. <words> are those words with
# their quotes and backslashes removed (a blank inside a word becomes `_`), so every write flag below is matched at the
# start of a real word (`-X PO""ST` is `-X POST`; a search text `'search=curl -F x'` holds no -F word), and a long
# option abbreviated the way curl and wget accept (`--jso`, `--post-dat=`, `--metho=POST`) is written out in full when
# it can stand for a write option.
# <get> is 1 only when a genuine -G/--get option of curl is present and the request is unambiguous. An option that
# takes a value consumes the next word (-o -G names a file, -A -G a user agent); an option not known to take no value
# is taken to take one, which can only hide a -G (refuse more), never invent one; a word quoted in any part is never an
# option. A request is ambiguous, and so never a GET, when it holds what a word-by-word reading cannot follow: a
# backslash, an unbalanced quote, a word starting a comment (#), a background `&`, a parenthesis or a backtick; and when
# a word exists only when the command runs: an unquoted expansion ($X, ${X}, $@, $*, $1, $(...)), a quoted word starting
# with one in an option position ("$M" may be -XPOST), an unquoted glob that can match a name starting with -, or a client
# run where words are appended or re-read (xargs, find -exec, parallel, eval, bash -c, a curl function or alias).
# A redirect (`> out.json`, `2>&1`, `>| out`, `>& out`) is followed: its target, also a separate word after an operator
# ending in | or &, is no option. wget has no GET flag (its -G is
# --ignore-tags), so a wget request never has <get> 1.
iad_http_requests() {
    printf '%s' "$1" | awk '
        BEGIN { noarg = "sSLkvViIOfgjlnNpqRZ0123456789#aBJMG"
                split("get silent show-error fail fail-with-body fail-early location insecure verbose include head compressed globoff no-progress-meter no-buffer raw remote-name remote-header-name remote-name-all ipv4 ipv6 http1.0 http1.1 http2 http2-prior-knowledge http3 tcp-nodelay no-keepalive no-sessionid disable-epsv path-as-is styled-output no-styled-output trace-time ssl-reqd tlsv1 tlsv1.2 tlsv1.3 location-trusted junk-session-cookies create-dirs append list-only crlf digest basic ntlm negotiate anyauth netrc netrc-optional proxy-insecure", L, " ")
                for (k in L) longnoarg[L[k]] = 1
                nw = split("json data data-ascii data-binary data-raw data-urlencode form form-string upload-file request method expand-data post-data post-file body-data body-file config execute", WO, " ")
                cl = "curl"; get = 0; amb = 0; hid = 0; nxt = 0; txt = ""; started = 0 }
        # an explicit method is a read only when it is GET or HEAD written out; any other, or one the command does not show, writes
        # meth: the method the request names, as written; unk: what the request does not show (an expansion, a
        # rewritten word or an ambiguous reading), so its method cannot be told.
        function method(m, t) { if (UX[t] || LX[t] || m ~ /[$`]/) { hid = 1; unk = 1 } else if (m != "GET" && m != "HEAD") hid = 1; meth = m }
        function flush() { if (started) printf "%s\t%d\t%d\t%d\t%s\t%s\n", cl, ((amb || nxt) ? 0 : get), hid, (unk || amb), (meth == "" ? "-" : meth), txt; get = 0; amb = 0; hid = 0; unk = 0; meth = ""; endopt = 0; skip = 0; skipkind = ""; txt = ""; started = 0 }
        # a long option written as an unambiguous prefix of a write option stands for that option
        function expand(w,   name, rest, e, k) { if (w !~ /^--[a-z]/) return w
            name = substr(w, 3); rest = ""; e = index(name, "="); if (e) { rest = substr(name, e); name = substr(name, 1, e - 1) }
            if (length(name) < 2) return w
            for (k = 1; k <= nw; k++) if (name != WO[k] && index(WO[k], name) == 1) return "--" WO[k] rest
            return w }
        { n = length($0); i = 1; ntok = 0
          while (i <= n) {
              while (i <= n && substr($0, i, 1) ~ /[ \t\n]/) i++
              if (i > n) break
              raw = ""; val = ""; quoted = 0; esc = 0; q = ""; ux = 0; lx = 0; gx = 0; uqv = ""
              while (i <= n) { c = substr($0, i, 1)
                  if (q == "") {
                      if (c ~ /[ \t\n]/) break
                      if (c == "\\") { esc = 1; raw = raw c; i++; if (i <= n) { c = substr($0, i, 1); raw = raw c; val = val c; uqv = uqv "Q"; i++ }; continue }
                      if (c == "\047" || c == "\"") { q = c; quoted = 1; raw = raw c; i++; continue }
                  } else if (q == "\"" && c == "\\" && substr($0, i + 1, 1) ~ /[$`"\\\n]/) { raw = raw c substr($0, i + 1, 1); val = val substr($0, i + 1, 1); uqv = uqv "Q"; i += 2; continue }
                  else if (c == q) { q = ""; raw = raw c; i++; continue }
                  if (q != "\047" && ((c == "$" && substr($0, i + 1, 1) ~ /[A-Za-z_0-9{(@*#?$!-]/) || c == "`")) {
                      if (q == "") ux = 1
                      if (val == "" || (val ~ /^-/ && val !~ /=/)) lx = 1 }
                  if (q == "" && c ~ /[*?[]/ && (val == "" || (val ~ /^-/ && val !~ /=/))) gx = 1
                  uqv = uqv (q == "" ? c : "Q")
                  raw = raw c; val = val c; i++ }
              ntok++; T[ntok] = raw; V[ntok] = val; Q[ntok] = quoted; E[ntok] = esc; U[ntok] = (q != "")
              UX[ntok] = ux; LX[ntok] = lx; GX[ntok] = gx; UQV[ntok] = uqv }
          skip = 0
          for (t = 1; t <= ntok; t++) {
              w = V[t]; uq = !Q[t] && !E[t]
              if (uq && w ~ /^@@IAD:(curl|wget)@@$/) { flush(); cl = (w ~ /wget/) ? "wget" : "curl"; started = 1; skip = 0; continue }
              # the client runs where words are appended or re-read (xargs, find -exec, bash -c, a redefined curl): unknown
              if (uq && w == "@@IAD:unknown@@") { amb = 1; started = 1; continue }
              # --next (also quoted, or abbreviated to --ne/--nex) starts a new request; after any, no request is a GET
              if (cl == "curl" && (w == "-:" || w ~ /^--ne(xt?)?$/)) { flush(); nxt = 1; started = 1; skip = 0; continue }
              started = 1
              # a brace expansion (a comma list or a {a..b} sequence, braces outside quotes even when a quoted part sits
              # inside) or an ANSI-C/locale quote ($'...', $"...") rewrites the words: hidden
              if (UQV[t] ~ /\{[^}]*(,|\.\.)[^}]*\}/) { hid = 1; unk = 1 }
              if (T[t] ~ /\$\047|\$"/) { hid = 1; unk = 1 }
              if (E[t] || U[t]) amb = 1
              if (uq && w ~ /^#/) amb = 1
              redirect = (!Q[t] && T[t] ~ /[<>]/)
              if (!Q[t] && !redirect && T[t] ~ /[&()`]/) amb = 1
              if (!Q[t] && T[t] ~ /`|\$\(/) amb = 1
              if (T[t] ~ /\$\{/) { po = gsub(/\(/, "(", T[t]); pc = gsub(/\)/, ")", T[t]); if (po != pc) amb = 1 }
              # Words that exist only when the command runs make the request unknown (never a GET) where curl could read
              # them as an option or a method: an unquoted expansion ($X, ${X}, $@, $*, $1, $(...), backticks) is split
              # into any number of words, an unquoted glob that can match a name starting with - (-*, *, ?X) may expand
              # to options, and a quoted word that starts with an expansion ("$M", "-$X") may be any option. Known
              # positions are exempt: the target of a redirect (one word the shell does not split), a QUOTED expansion
              # inside a value (-d "page=$p", -H "X: $T": one word), and a quoted URL word "$URL/path". An unquoted one in a
              # value (-d page=$p) is split by the shell and may add -X POST, so it is unknown too.
              rtarget = (skip == 2)
              xw = (!rtarget && !(redirect && T[t] ~ /^[0-9]*[<>]/))
              if (xw && GX[t]) amb = 1
              w = expand(w); gsub(/[ \t\n]/, "_", w); prev = txt; txt = txt " " w
              if (skip) { k = skipkind; skip = 0; skipkind = ""
                  if (k == "meth") method(w, t)
                  else if (k != "redir" && UX[t]) amb = 1
                  continue }
              if (redirect) { if (T[t] ~ /[<>][|&]?$/) { skip = 2; skipkind = "redir" }; if (xw && UX[t]) amb = 1; continue }
              if (UX[t]) amb = 1
              if (LX[t] && !(V[t] ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\//)) amb = 1
              if (cl != "curl" || endopt) continue
              if (w == "--") { endopt = 1; amb = 1; continue }
              # curl reads its options whatever the shell quoting was ("-sX" POST is -s -X POST)
              if (w ~ /^--/) { name = substr(w, 3); rest = ""; e = index(name, "=")
                  if (e) { rest = substr(name, e + 1); name = substr(name, 1, e - 1) }
                  if (name == "get") get = 1
                  if (name == "request") { if (e) method(rest, t); else { skip = 1; skipkind = "meth" }; continue }
                  if (!e && !(name in longnoarg) && name != "") { skip = 1; skipkind = (name ~ /^data/) ? "data" : "other" }
                  continue }
              # A cluster is read the way curl reads it: letters that take no value, then the first letter that takes
              # one, whose value is the rest of the cluster or the next word (-GX POST, -sGiX POST, -GdX, -GsK cfg). The
              # cluster is written out letter by letter (-G -X POST) so every write rule sees each option on its own.
              if (w ~ /^-./) { norm = ""
                  for (p = 2; p <= length(w); p++) { ch = substr(w, p, 1)
                      if (index(noarg, ch)) { norm = norm " -" ch; if (ch == "G") get = 1; continue }
                      norm = norm " -" ch; rest = substr(w, p + 1)
                      if (rest != "") { norm = norm " " rest; if (ch == "X") method(rest, t) }
                      else { skip = 1; skipkind = (ch == "X") ? "meth" : (ch == "d") ? "data" : "other" }
                      break }
                  txt = prev norm } }
          flush() }'
}
# iad_http_words_write <words> [<segment>] -- TRUE (0) if any request of the curl/wget arguments writes: an explicit
# mutating method, an upload, a form, what the command does not show (a method in a variable, any config file
# including -K - on stdin, a config home assigned before the client, a brace expansion or $'...' quoting that rewrites
# the words), a wgetrc command that posts (wget -e post_data=..., method=...), or a data flag (--data*, --json, -d; for
# wget its --post-data/--body-data/--post-file). A data flag with a genuine curl -G/--get in an unambiguous request
# only builds the query string of a GET, so it does not count there. (<segment> is accepted for the callers' sake.)
# [RiskMitigation RA-01] A read is granted only to an unambiguous curl request; anything the scanner cannot be sure of counts as a write (CWE-693).
IAD_WGET_EXECUTE_WRITE_RE='(^|[[:space:]])(-[A-Za-z]*e[[:space:]]?|--execute[[:space:]=])(post[_-]?(data|file)|body[_-]?(data|file)|method)'
iad_http_words_write() {
    local cl get hid _unk _meth w
    while IFS=$'\t' read -r cl get hid _unk _meth w; do
        [ "$hid" = 1 ] && return 0
        printf '%s' "$w" | grep -Eic "$IAD_CURL_METHOD_RE" >/dev/null && return 0
        printf '%s' "$w" | grep -Ec "$IAD_CURL_UPLOAD_RE" >/dev/null && return 0
        printf '%s' "$w" | grep -Ec "$IAD_CURL_FORM_RE" >/dev/null && return 0
        printf '%s' "$w" | grep -Ec "$IAD_CURL_HIDDEN_RE" >/dev/null && return 0
        [ "$cl" = wget ] && printf '%s' "$w" | grep -Eic "$IAD_WGET_EXECUTE_WRITE_RE" >/dev/null && return 0
        [ "$cl" = curl ] && [ "$get" = 1 ] && continue
        printf '%s' "$w" | grep -Ec "$IAD_CURL_LONG_WRITE_RE" >/dev/null && return 0
        printf '%s' "$w" | grep -Ec "$IAD_CURL_SHORT_WRITE_RE" >/dev/null && return 0
    done < <(iad_http_requests "$1")
    return 1
}
# glab's own milestone commands write through the API like `glab api` does (create, edit, delete); a flag may sit between
# the words (glab -R group/project milestone delete 34, glab milestone --repo group/project create).
IAD_GLAB_MILESTONE_WRITE_RE="${IAD_CLIENT_PREFIX}glab([[:space:]]+[^[:space:];|&]+)*[[:space:]]+milestone[[:space:]]+([^[:space:];|&]+[[:space:]]+)*(create|new|edit|update|delete|close|reopen)([^[:alnum:]_-]|\$)"
# `glab api` without a method is a write the moment it carries a field (-f x=y, -Fx=y, --field, --raw-field) or a body file.
IAD_GLAB_API_MILESTONE_WRITE_RE='(^|[[:space:]])(-[fF]|--(input|field|raw-field|form))([^[:space:]]|[[:space:]]|$)'
# python/node write hints for the milestone predicate: any client method call named post/put/delete/patch, a request()
# call with a mutating method, an explicit method option in any letter case, urlopen (a bare `data =` is no hint: a read can hold one).
IAD_PY_MILESTONE_WRITE_RE='(\.(post|put|delete|patch)\(|\.request\([[:space:]]*['"'"'"](POST|PUT|DELETE|PATCH)|method[[:space:]]*=[[:space:]]*['"'"'"](POST|PUT|DELETE|PATCH)|urlopen\()'
IAD_NODE_MILESTONE_WRITE_RE='(method\\?['"'"'"]?[[:space:]]*:[[:space:]]*\\?['"'"'"`](POST|PUT|DELETE|PATCH)|https?\.request\(|\.(post|put|delete|patch)\()'
# An issue write that names a milestone (`milestone_id`, glab's `--milestone`, a `/milestone` quick action written in a
# note body): it moves an issue between epics.
iad_seg_names_milestone() { printf '%s' "$1" | grep -Eic '(milestone_id|--milestone([[:space:]=]|$)|(^|[^[:alnum:]_])/(milestone|remove_milestone)([[:space:]%]|$))' >/dev/null; }
# A GraphQL mutation that names a milestone (updateIssue with milestoneId, a milestone create/update mutation).
iad_seg_is_milestone_graphql() { printf '%s' "$1" | grep -Eic 'mutation' >/dev/null && printf '%s' "$1" | grep -Eic 'milestone' >/dev/null; }

# iad_seg_is_milestone_write <seg> -- TRUE (0) if the segment WRITES a milestone through the API (curl/wget with a
# write verb, `glab api` with a write verb or a field flag, python/node with a write hint), or is a raw issue write
# (iad_seg_is_raw_issue_write, or the same curl short/quoted spellings) that sets an issue's milestone.
iad_seg_is_milestone_write() {
    local seg="$1" words=""
    printf '%s' "$seg" | grep -Eic "$IAD_GLAB_MILESTONE_WRITE_RE" >/dev/null && return 0
    iad_seg_has_curl_wget "$seg" && words="$(iad_http_client_words "$seg")"
    if iad_seg_hits_milestones "$seg"; then
        if printf '%s' "$seg" | grep -Ec 'glab[[:space:]]+api' >/dev/null \
            && ! printf '%s' "$seg" | grep -Eic '(-X|--method)[[:space:]="'"'"']*GET' >/dev/null; then
            printf '%s' "$seg" | grep -Eic "$IAD_HTTP_WRITE_RE" >/dev/null && return 0
            printf '%s' "$seg" | grep -Ec "$IAD_GLAB_API_FIELD_RE" >/dev/null && return 0
            printf '%s' "$seg" | grep -Ec "$IAD_GLAB_API_MILESTONE_WRITE_RE" >/dev/null && return 0
        fi
        [ -n "$words" ] && iad_http_words_write "$words" "$seg" && return 0
        iad_seg_has_python "$seg" && printf '%s' "$seg" | grep -Eic "$IAD_PY_MILESTONE_WRITE_RE" >/dev/null && return 0
        iad_seg_has_node "$seg" && printf '%s' "$seg" | grep -Eic "$IAD_NODE_MILESTONE_WRITE_RE" >/dev/null && return 0
        iad_seg_has_script "$seg" && printf '%s' "$seg" | grep -Eic "$IAD_SCRIPT_MILESTONE_WRITE_RE" >/dev/null && return 0
        iad_seg_httpie_write "$seg" && return 0
    fi
    # glab's own issue commands take the milestone as -m / --milestone; -m may carry its value attached (-mE07).
    printf '%s' "$seg" | grep -Ec 'glab[[:space:]]+issue[[:space:]]+(update|edit|create|new)' >/dev/null \
        && printf '%s' "$seg" | grep -Ec '(^|[[:space:]])-m([[:space:]=]|[^[:space:]]|$)' >/dev/null && return 0
    if iad_seg_names_milestone "$seg"; then
        iad_seg_is_raw_issue_write "$seg" && return 0
        if [ -n "$words" ] && printf '%s' "$seg" | grep -Ec '/issues' >/dev/null && iad_http_words_write "$words" "$seg"; then return 0; fi
    fi
    if iad_seg_is_milestone_graphql "$seg" && printf '%s' "$seg" | grep -Eic "$IAD_CLIENT_RE" >/dev/null; then return 0; fi
    # A GitLab client library (python-gitlab, the ruby gitlab gem, gitbeaker) writes a milestone without naming its URL.
    iad_seg_has_any_script "$seg" && iad_text_is_lib_milestone_write "$seg" && return 0
    # A program file a runtime runs (python3 tools/del.py, deno run x.ts) is read like the command itself.
    iad_seg_script_file_writes_milestone "$seg" && return 0
    # A client whose URLs come from xargs or parallel has an unknown target: a write by it counts as a milestone write.
    iad_seg_xargs_fed_write "$seg" && return 0
    return 1
}

# --- more clients for the milestone predicate --------------------------------------------------------------------
iad_seg_has_script() { printf '%s' "$1" | grep -Eic "${IAD_CLIENT_PREFIX}(${IAD_SCRIPT_CLIENTS})([^[:alnum:]_]|\$)" >/dev/null; }
iad_seg_has_any_script() { iad_seg_has_python "$1" || iad_seg_has_node "$1" || iad_seg_has_script "$1"; }
# A write call in PowerShell, ruby, perl, deno or bun: an explicit mutating -Method or method option, a Net::HTTP
# request class, a .post/.put/.delete/.patch call, a perl ->post/->put/->delete/->patch/->request, an HTTP::Request with
# a mutating method, or a PowerShell -Body / -InFile (which sends the body as a POST by default).
IAD_SCRIPT_MILESTONE_WRITE_RE="(-(Custom)?Method[[:space:]:]+[\"']?(post|put|delete|patch)|[\"'](POST|PUT|PATCH|DELETE)[\"']|Net::HTTP::(Post|Put|Delete|Patch)|\\.(post|put|delete|patch)[[:space:](]|->(post|put|delete|patch|request)[[:space:]]*\\(|HTTP::Request->new\\([[:space:]]*[\"']?(POST|PUT|DELETE|PATCH)|(^|[[:space:]])-(Body|InFile)[[:space:]]|${IAD_NODE_MILESTONE_WRITE_RE})"
# A GitLab client library call that writes a milestone, or sets an issue's milestone and saves it.
IAD_LIB_MILESTONE_WRITE_RE='(milestones\.(create|delete|update|edit|remove|save)\(|milestones\.get\([^)]*\)\.(delete|save)\(|(create|edit|update|delete|close)_milestone\(|Milestones\.(create|edit|remove)\()'
iad_text_is_lib_milestone_write() {
    printf '%s' "$1" | grep -Ec "$IAD_LIB_MILESTONE_WRITE_RE" >/dev/null && return 0
    printf '%s' "$1" | grep -Ec 'milestone_id[[:space:]]*=' >/dev/null && printf '%s' "$1" | grep -Ec '\.save\(' >/dev/null
}
# iad_text_is_script_milestone_write <text> -- program text that names a milestones endpoint and writes it in python,
# node, PowerShell, ruby, perl, deno or bun, or writes a milestone through a GitLab client library.
iad_text_is_script_milestone_write() {
    iad_text_is_lib_milestone_write "$1" && return 0
    iad_seg_hits_milestones "$1" || return 1
    printf '%s' "$1" | grep -Eic "$IAD_PY_MILESTONE_WRITE_RE" >/dev/null && return 0
    printf '%s' "$1" | grep -Eic "$IAD_SCRIPT_MILESTONE_WRITE_RE" >/dev/null
}
# httpie (http, https) and xh: a mutating method word anywhere after the client (options that take a value, such as
# --auth x:y, -A bearer or --timeout 5, may stand before it), or a data item (name=value, name:=json, name@file; never a
# name==value query) makes the request a write.
iad_seg_httpie_write() {
    local seg="$1"
    printf '%s' "$seg" | grep -Ec "${IAD_CLIENT_PREFIX}(https?|xhs?)[[:space:]]" >/dev/null || return 1
    printf '%s' "$seg" | grep -Eic "${IAD_CLIENT_PREFIX}(https?|xhs?)[[:space:]](.*[[:space:]])?(POST|PUT|PATCH|DELETE)([[:space:]]|\$)" >/dev/null && return 0
    printf '%s' "$seg" | grep -Ec '[[:space:]][A-Za-z_][][A-Za-z0-9_.-]*(=[^=]|:=|@|=$)' >/dev/null
}
# The files a runtime runs: the words of the segment ending in a program-file extension, resolved against the
# command's working folder (IAD_CWD, set by the guard from its payload) and read when readable and small. A file that
# cannot be read is no evidence (the runtime fails on it, or it is a compiled program the string check cannot see).
iad_seg_script_file_writes_milestone() {
    local seg="$1" w f
    iad_seg_has_any_script "$seg" || return 1
    for w in $(printf '%s' "$seg" | tr -s '[:space:]"'"'"'' '\n' | grep -E '\.(py|rb|pl|pm|js|mjs|cjs|ts|ps1)$'); do
        case "$w" in /*) f="$w" ;; *) f="${IAD_CWD:-$PWD}/$w" ;; esac
        [ -f "$f" ] && [ -r "$f" ] || continue
        [ "$(wc -c <"$f" 2>/dev/null || echo 0)" -le 524288 ] || continue
        iad_text_is_script_milestone_write "$(cat "$f" 2>/dev/null)" && return 0
    done
    return 1
}
# A curl, wget, httpie or xh run by xargs or parallel takes its URLs from the input, which the guard cannot see; a write
# by such a client counts (a read passes).
iad_seg_xargs_fed_write() {
    local seg="$1"
    printf '%s' "$seg" | grep -Ec "(^|[[:space:];|&(])(xargs|parallel)([[:space:]]+[^[:space:]]+)*[[:space:]]+(curl|wget|https?|xhs?)([[:space:]]|\$)" >/dev/null || return 1
    # curl -G / --get turns its data flags into a query string (a read), unless a method, an upload or a form is named.
    if printf '%s' "$seg" | grep -Ec '(^|[[:space:]])(--get|-[A-Za-z0-9#]*G[A-Za-z0-9#]*)([[:space:]]|$)' >/dev/null \
        && ! printf '%s' "$seg" | grep -Eic "$IAD_CURL_METHOD_RE|$IAD_CURL_UPLOAD_RE|$IAD_CURL_FORM_RE" >/dev/null; then return 1; fi
    printf '%s' "$seg" | grep -Eic "$IAD_HTTP_WRITE_RE" >/dev/null && return 0
    printf '%s' "$seg" | grep -Ec "$IAD_CURL_SHORT_WRITE_RE|$IAD_CURL_LONG_WRITE_RE|$IAD_CURL_UPLOAD_RE" >/dev/null && return 0
    printf '%s' "$seg" | grep -Eic "(^|[[:space:]])(https?|xhs?)[[:space:]](.*[[:space:]])?(POST|PUT|PATCH|DELETE)([[:space:]]|\$)" >/dev/null
}

# iad_cmd_is_milestone_write <cmd> -- TRUE (0) if ANY statement of the command writes a milestone or sets an issue's
# milestone by hand. A python or node program is split at its own `;` by the statement split, which can put the
# milestones URL and the write call in different pieces (r='.../milestones'; requests.post(r)); so when the command
# runs python/node, the whole command naming a milestones endpoint AND carrying that language's write hint counts.
iad_cmd_is_milestone_write() {
    local cmd="$1" seg
    while IFS= read -r seg || [ -n "$seg" ]; do
        [ -n "$seg" ] || continue
        iad_seg_is_milestone_write "$seg" && return 0
    done < <(iad_split_segments "$cmd")
    iad_seg_has_any_script "$cmd" && iad_text_is_lib_milestone_write "$cmd" && return 0
    iad_seg_hits_milestones "$cmd" || return 1
    iad_seg_has_python "$cmd" && printf '%s' "$cmd" | grep -Eic "$IAD_PY_MILESTONE_WRITE_RE" >/dev/null && return 0
    iad_seg_has_node "$cmd" && printf '%s' "$cmd" | grep -Eic "$IAD_NODE_MILESTONE_WRITE_RE" >/dev/null && return 0
    iad_seg_has_script "$cmd" && printf '%s' "$cmd" | grep -Eic "$IAD_SCRIPT_MILESTONE_WRITE_RE" >/dev/null && return 0
    return 1
}
