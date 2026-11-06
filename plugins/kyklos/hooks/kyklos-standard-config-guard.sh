#!/usr/bin/env bash
# kyklos-standard-config-guard.sh (Kyklos) — "use the standard solution, don't re-invent it" for DATABASE
# CONNECTION STRINGS. The standard .NET pattern is the well-known `ConnectionStrings` section of
# appsettings.json read via IConfiguration.GetConnectionString(name). A credential-bearing connection
# string hardcoded in C# re-invents that, drifts from appsettings, and leaks credentials into source.
#
# Blocks:
#   .cs               -> a whole credential-bearing connection string (the password-less skeleton belongs in
#                        appsettings.json, the password is supplied at runtime).
#   config JSON       -> an embedded PASSWORD in any appsettings*.json (environment and .local overlays included),
#                        any other *.local.json, and the user-secrets store secrets.json. The password never lives
#                        in a file: it comes at runtime from the secrets manager / OS credential store (an
#                        environment variable or a configuration provider), per the secret rule of the managed
#                        policy. A git-ignored local overlay is still a file on disk, so it is judged too.
# The JSON check judges every key path: a key that names a secret (password, pass, passphrase, secret, api key, token,
# access/private/signing/encryption/connection key, credential, or an Auth value of the form 'Basic ...') or any key
# under a secret-named parent, a number as well as a string, and a credential inside a URL. A key that only describes a
# secret (its name, location, issuer, expiry, policy, version...) is not judged. An exact key path that holds no secret
# can be declared in the repository's .claude/standards.env as KYKLOS_CONFIG_SECRET_ALLOW_KEYS (audited); there is
# no inline marker for JSON.
# A .example or .template copy of a file is judged as that file: a sample must carry a placeholder (<...>, %ENV%,
# $VAR), never a real password, because it is committed and copied. Inline escape on the same line of a .cs file:
# `// connection-string-ok: <reason>`.
#
# Wired PreToolUse, matcher Edit|Write|MultiEdit. Limit: a file written by a shell command (a heredoc, tee, cp, sed -i) is
# not seen here; no shared reader of the files a Bash command writes exists yet.
set -euo pipefail
_CG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_CG_HERE/lib/escape-audit.sh" 2>/dev/null || true   # escape_audit: every use of the declared key opt-out leaves a trail

INPUT="$(cat || true)"
# A missing jq must not SILENTLY disable the gate (the whole check parses INPUT with jq). Announce the INERT state
# LOUDLY and allow (a broken plugin install must not wedge every Edit/Write) — never a silent no-op.
command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: standard-config-guard is INERT — jq is missing, so hardcoded-connection-string / embedded-password checks are NOT running. Install jq to restore this gate." >&2; exit 0; }
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

# A sample copy is judged as the file it copies: strip every trailing .example / .template before classifying.
# [CySec] CWE-312 / CWE-798 (cleartext / hard-coded credential): no config-file spelling is exempt from the check.
# File names are matched case-insensitively (a Windows host treats AppSettings.Local.JSON as the same file).
JUDGED_NAME="${FILE_PATH##*/}"; JUDGED_NAME="${JUDGED_NAME,,}"
while :; do
  case "$JUDGED_NAME" in
    *.example) JUDGED_NAME="${JUDGED_NAME%.example}" ;;
    *.template) JUDGED_NAME="${JUDGED_NAME%.template}" ;;
    *) break ;;
  esac
done
GATE_MODE=""
case "$JUDGED_NAME" in
  *.cs) GATE_MODE="cs" ;;
  *appsettings*.json|*.local.json|secrets.json) GATE_MODE="json" ;;
  *) exit 0 ;;
esac

CONTENT="$(printf '%s' "$INPUT" | jq -r '
  [ (.tool_input.new_string // empty),
    (.tool_input.content // empty),
    ((.tool_input.edits // []) | map(.new_string // empty) | join("\n")) ]
  | join("\n")' 2>/dev/null || true)"

block() { printf '{"decision":"block","reason":"%s"}' "$1"; exit 0; }

if [ "$GATE_MODE" = "cs" ]; then
  # ADO.NET connection-string keys are CASE-INSENSITIVE ("server="/"SERVER=" open the same connection), so
  # the server-key match must be case-insensitive too (grep -niE) — it was case-SENSITIVE while the credential
  # match was already -i, so a lowercase `server=db;pwd=secret;` evaded the whole gate and leaked a credential.
  OFFENDERS="$(printf '%s' "$CONTENT" \
    | grep -niE '(Server=|Data Source=|Host=)' \
    | grep -iE '(Password=|Pwd=|User Id=|Uid=)' \
    | grep -ivE '//[[:space:]]*connection-string-ok:' || true)"
  if [ -n "$OFFENDERS" ]; then
    block "BLOCKED (standard-config-guard): a credential-bearing database connection string is hardcoded in C#. Do not re-invent the wheel — put the password-less connection string in the 'ConnectionStrings' section of appsettings.json, read it with IConfiguration.GetConnectionString(<name>) (tests read the SAME appsettings.json), and supply the password at runtime from the secrets manager / OS credential store (an environment variable or a configuration provider), never from a file on disk. If this is a genuine non-secret placeholder that never opens a connection, add an inline '// connection-string-ok: <reason>'."
  fi
else
  # A value is accepted only when ALL of it is a placeholder: <name>, %NAME% or $NAME / ${NAME}. A value that only
  # starts like one (Password=$abc123real, <real>x1, %X%real) is a real secret. The $ form must be an
  # environment-variable name in its usual spelling (upper case, digits, underscores), so a real value that
  # happens to start with $ is not mistaken for a reference.
  _whole_placeholder() {
    printf '%s' "$1" | grep -cE '^(<[^>]+>|%[A-Za-z0-9_]+%|\$\{?[A-Z_][A-Z0-9_]*\}?)$' >/dev/null
  }
  # _key_kind <segment> -> describe | secret | auth | plain, for one segment of a key path.
  # The segment is split into words at camel-case, '_' and '-' boundaries (TokenIssuer -> token issuer,
  # API_KEY_ID -> api key id). It DESCRIBES a secret only when its LAST word is a describing word (its name,
  # location, issuer, expiry, policy...): TokenValidation describes a setting, AuthenticationToken and PasswordValid
  # hold a secret. A describing segment is never judged.
  _key_words() {
    printf '%s' "$1" | sed -E 's/([a-z0-9])([A-Z])/\1 \2/g; s/([A-Z]+)([A-Z][a-z])/\1 \2/g; s/[_.-]+/ /g' | tr '[:upper:]' '[:lower:]'
  }
  _key_kind() {
    local words last joined w
    words="$(_key_words "$1")"; last="${words##* }"; joined="${words// /}"
    case "$last" in
      name|names|environmentvariable|variable|var|env|directory|dir|path|file|url|uri|endpoint|header|provider|prefix|pattern|mode|kind|type|id|ids) echo describe; return ;;
      issuer|audience|expir*|ttl|duration|lifetime|policy|version|hint|algorithm|handler|backend|validation|authentication|scheme|length|rotation|enabled|required|seconds|minutes|days) echo describe; return ;;
    esac
    for w in $words; do [ "$w" = pass ] && { echo secret; return; }; done
    case "$joined" in
      *password*|*passwd*|*pwd*|*passphrase*|*secret*|*apikey*|*token*|*accesskey*|*privatekey*|*signingkey*|*encryptionkey*|*connectionkey*|*credential*) echo secret ;;
      auth|authorization) echo auth ;;
      *) echo plain ;;
    esac
  }
  # The per-repository opt-out: KYKLOS_CONFIG_SECRET_ALLOW_KEYS lists exact key paths (dotted, ';'-separated,
  # case-insensitive), declared in the repository's .claude/standards.env, never by an inline marker in the file.
  # Every use is audited.
  ALLOW_KEYS="${KYKLOS_CONFIG_SECRET_ALLOW_KEYS:-}"
  if [ -z "$ALLOW_KEYS" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$_CG_HERE/lib/standards-env.sh" ]; then
    # shellcheck source=/dev/null
    . "$_CG_HERE/lib/standards-env.sh" 2>/dev/null && ALLOW_KEYS="$(standards_env_value "$CLAUDE_PROJECT_DIR/.claude/standards.env" KYKLOS_CONFIG_SECRET_ALLOW_KEYS 2>/dev/null || true)"
  fi
  _allowed_path() {
    local want="${1,,}" e
    [ -n "$ALLOW_KEYS" ] || return 1
    while IFS= read -r e || [ -n "$e" ]; do
      e="$(printf '%s' "$e" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$e" ] && [ "${e,,}" = "$want" ] && return 0
    done < <(printf '%s' "$ALLOW_KEYS" | tr ';' '\n')
    return 1
  }
  OFFENDERS=""
  # _judge <dotted path> <value> <json type>: append to OFFENDERS when the value is a secret the path may not hold.
  _judge() {
    local path="$1" val="$2" typ="$3" seg kind leaf_kind="" ancestor_secret=0 n i
    IFS='.:' read -r -a _segs <<<"$path"; n=${#_segs[@]}
    for ((i = 0; i < n; i++)); do
      seg="${_segs[$i]}"; [[ "$seg" =~ ^[0-9]+$ ]] && continue
      kind="$(_key_kind "$seg")"
      if [ "$i" -eq $((n - 1)) ]; then leaf_kind="$kind"; elif [ "$kind" = secret ]; then ancestor_secret=1; fi
    done
    case "$typ" in string|number) : ;; *) return 0 ;; esac
    [ -n "$val" ] || return 0
    _whole_placeholder "$val" && return 0
    local judged=0
    case "$leaf_kind" in
      secret) judged=1 ;;
      auth) printf '%s' "$val" | grep -ciE '^(basic|bearer|digest)[[:space:]]+[^[:space:]]' >/dev/null && judged=1 ;;
      describe) : ;;
      *) [ "$ancestor_secret" = 1 ] && judged=1 ;;
    esac
    [ "$judged" = 1 ] || return 0
    if _allowed_path "$path"; then
      command -v escape_audit >/dev/null 2>&1 && escape_audit "config-secret-allow-key" "file=$FILE_PATH key=$path" 2>/dev/null || true
      return 0
    fi
    OFFENDERS="${OFFENDERS}${path}"$'\n'
  }
  # (a) the connection-string form inside any value: Password=x / Pwd = x / Pass=x (spaces around '=' allowed).
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    _v="$(printf '%s' "$_m" | sed -E 's/^[^=]*=[[:space:]]*//')"
    [ -z "$_v" ] && continue
    _whole_placeholder "$_v" && continue
    OFFENDERS="${OFFENDERS}${_m}"$'\n'
  done < <(printf '%s' "$CONTENT" | grep -oiE '(^|[^A-Za-z])(Password|Pwd|Pass)[[:space:]]*=[[:space:]]*[^;"'"'"'[:space:]]*' || true)
  # (b) a credential inside a URL in any value: scheme://user:password@host.
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    _v="$(printf '%s' "$_m" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/:@[:space:]]+:##; s/@$//')"
    _whole_placeholder "$_v" && continue
    OFFENDERS="${OFFENDERS}url-credential"$'\n'
  done < <(printf '%s' "$CONTENT" | grep -oE '[A-Za-z][A-Za-z0-9+.-]*://[^/:@"[:space:]]+:[^/@"[:space:]]+@' || true)
  # (c) key paths. A whole JSON document is read with jq: nesting is known (a value under a secret-named parent is
  # judged) and escapes in keys are decoded. An Edit fragment that is not a whole document falls back to its
  # "key": value pairs, each key decoded by jq and judged on its own.
  _PAIRS="$(printf '%s' "$CONTENT" | jq -r 'paths(scalars) as $p | [ ($p | map(tostring) | join(".")), (getpath($p) | tostring), (getpath($p) | type) ] | @tsv' 2>/dev/null)" || _PAIRS=""
  if [ -z "$_PAIRS" ]; then
    _PAIRS="$(printf '%s' "$CONTENT" \
      | grep -oE '"([^"\\]|\\.)*"[[:space:]]*:[[:space:]]*("([^"\\]|\\.)*"|-?[0-9]+(\.[0-9]+)?)' \
      | jq -rR 'capture("^(?<k>\"(?:[^\"\\\\]|\\\\.)*\")\\s*:\\s*(?<v>.*)$") | [ (.k | fromjson), (.v | fromjson | tostring), (.v | fromjson | type) ] | @tsv' 2>/dev/null || true)"
  fi
  while IFS=$'\t' read -r _p _v _t; do
    [ -n "$_p" ] || continue
    _judge "$_p" "$_v" "$_t"
  done <<<"$_PAIRS"
  if [ -n "$OFFENDERS" ]; then
    _list="$(printf '%s' "$OFFENDERS" | sed -E 's/=.*/=…/' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    block "BLOCKED (standard-config-guard): a secret (a password, key or token) is embedded in a configuration file (appsettings*.json, a *.local.json overlay, secrets.json, or a sample copy of one); found at: ${_list}. A git-ignored local file is still a file on disk. Supply the secret at runtime from the secrets manager / OS credential store (an environment variable or a configuration provider). A placeholder is accepted only when the whole value is one: <name>, %NAME% or \$NAME. A key path that holds no secret can be declared once in the repository's .claude/standards.env as KYKLOS_CONFIG_SECRET_ALLOW_KEYS=<Path.To.Key>;... (audited)."
  fi
fi
exit 0
