#!/usr/bin/env bash
# dotnet-test-scope.sh — shared: does a shell `dotnet test` / `dotnet vstest` command run only PART of the suite?
# [RiskMitigation RA-04] a partial shell test run is never read as a whole run, so it cannot clear recorded failures.
#
# A green run of part of the suite says nothing about the rest, so the zero-failures gate must not read it as "all
# clear". A run counts as WHOLE only by an allow list: every word of it must be shown not to narrow the run. Anything
# the reader does not know (an option, a property, a variable, a second positional) makes it partial, so an option the
# CLI gains later fails closed instead of open.
#
# The command is split into words the way the shell does (quotes kept together; a backslash-newline joins two lines; a
# `#` comment is dropped; a backtick or `$(` starts another command). EVERY `dotnet test` / `dotnet vstest` in it
# (dotnet named plainly, as dotnet.exe or by a path) is judged up to its shell separator; one partial run makes the
# whole command partial.
#
# Contract — source this file, then:
#   dotnet_test_is_partial "<command-string>"
#     rc 1 : a whole run — `dotnet test` with no positional or exactly one solution (.sln/.slnx, any case, or the
#            folder `.`), preceded only by `time`, `timeout <duration>`, `nice` or an allowed environment setting, and
#            followed only by options listed in _DOTNET_SCOPE_WHOLE_FLAGS / _DOTNET_SCOPE_WHOLE_VALUE_OPTIONS (with
#            their literal values), `-p:`/`--property:` setting only _DOTNET_SCOPE_WHOLE_PROPERTIES, and
#            redirections.
#     rc 0 : partial — everything else: `dotnet vstest`; a project, folder or assembly; a second solution; --filter*,
#            -f/--framework, -s/--settings, --list-tests, an unknown option or property, `--` and what follows it; a
#            word holding `$` or a backtick (a value the reader cannot see); an earlier `export` of a variable not
#            in _DOTNET_SCOPE_WHOLE_ENVIRONMENT; a command whose quotes do not close; a `dotnet test` the reader
#            cannot find as words (inside a quoted string, `bash -c`, `eval`).
#   It is a reading of the command line, not of what MSBuild resolves: a solution that itself holds only some
#   projects, a filter inside a runsettings file the solution imports, or `cd sub && dotnet test` is not seen. The
#   bridge's structured partial marker is the authoritative one.

# shellcheck disable=SC2034  # sourced library
# The shell words of "$1", with quotes and backslashes removed the way the shell does, in the array
# _DOTNET_SCOPE_WORDS. A command separator outside quotes (; & | newline ( ) ) becomes its own word, the single
# character $'\x01', so a reader knows where one command ends (a backtick counts as one: what it wraps is a command). A `&` right after `>` or `<` (`2>&1`, `>&2`) or right
# before `>` (`&>`, `&>>`) is part of the redirection, not a separator. A backslash-newline is removed (the line goes
# on), and an unquoted `#` at the start of a word starts a comment up to the end of the line. Returns 1 when a quote
# does not close.
_dotnet_test_scope_words() {
  local s=$1 c quote='' cur='' have=0 i n=${#1}
  _DOTNET_SCOPE_WORDS=()
  for ((i = 0; i < n; i++)); do
    c=${s:i:1}
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then
        quote=''
      elif [ "$quote" = '"' ] && [ "$c" = '\' ] && [ "${s:i+1:1}" = $'\n' ]; then
        i=$((i + 1))
      elif [ "$quote" = '"' ] && [ "$c" = '\' ] && case ${s:i+1:1} in '"'|'\'|'$'|'`') true ;; *) false ;; esac; then
        i=$((i + 1)); cur+=${s:i:1}
      else
        cur+=$c
      fi
      continue
    fi
    case $c in
      '"'|"'") quote=$c; have=1 ;;
      '\')
        if [ "${s:i+1:1}" = $'\n' ]; then i=$((i + 1)); else i=$((i + 1)); cur+=${s:i:1}; have=1; fi ;;
      '#')
        if [ "$have" = 0 ]; then
          while [ $((i + 1)) -lt "$n" ] && [ "${s:i+1:1}" != $'\n' ]; do i=$((i + 1)); done
        else
          cur+=$c
        fi ;;
      ' '|$'\t') [ "$have" = 1 ] && _DOTNET_SCOPE_WORDS+=("$cur"); cur=''; have=0 ;;
      '&')
        if [ "${s:i+1:1}" = '>' ]; then cur+=$c; have=1
        else
          case $cur in *'>'|*'<') cur+=$c ;;
            *) [ "$have" = 1 ] && _DOTNET_SCOPE_WORDS+=("$cur"); cur=''; have=0; _DOTNET_SCOPE_WORDS+=($'\x01') ;;
          esac
        fi ;;
      ';'|'|'|$'\n'|'('|')'|'`') [ "$have" = 1 ] && _DOTNET_SCOPE_WORDS+=("$cur"); cur=''; have=0; _DOTNET_SCOPE_WORDS+=($'\x01') ;;
      *) cur+=$c; have=1 ;;
    esac
  done
  [ "$have" = 1 ] && _DOTNET_SCOPE_WORDS+=("$cur")
  [ -z "$quote" ]
}

# Options of `dotnet test` (VSTest and Microsoft.Testing.Platform) shown not to narrow which tests run: they set
# output, logging, reporting, diagnostics, time limits, retries or the build configuration.
_DOTNET_SCOPE_WHOLE_FLAGS=' --no-restore --no-build --nologo -nologo --blame --blame-crash --blame-hang
  --blame-crash-collect-always --report-trx --coverage --diagnostic --no-progress --no-ansi --interactive -bl /bl '
_DOTNET_SCOPE_WHOLE_VALUE_OPTIONS=' -c --configuration -v --verbosity -l --logger --results-directory --collect
  -d --diag --blame-hang-timeout --blame-crash-dump-type --blame-hang-dump-type -o --output --artifacts-path
  --report-trx-filename --timeout --retry-failed-tests --retry-failed-tests-max-percentage
  --retry-failed-tests-max-tests --coverage-output --coverage-output-format --diagnostic-output-directory
  --diagnostic-verbosity --minimum-expected-tests --max-parallel-test-modules
  -verbosity /v /verbosity -logger /l /logger '
# MSBuild properties (-p:Name=value) shown not to narrow the run. Matched without regard to case, as MSBuild does.
_DOTNET_SCOPE_WHOLE_PROPERTIES=' configuration continuousintegrationbuild deterministic treatwarningsaserrors '
# Environment variables that may be set before the run (or exported earlier) without narrowing it.
_DOTNET_SCOPE_WHOLE_ENVIRONMENT=' DOTNET_CLI_TELEMETRY_OPTOUT DOTNET_NOLOGO DOTNET_SKIP_FIRST_TIME_EXPERIENCE
  DOTNET_CLI_UI_LANGUAGE CI NO_COLOR TERM '

# Is "$1" one word of the space-padded list "$2"?
_dotnet_scope_listed() { case " ${2//$'\n'/ } " in *" $1 "*) return 0 ;; esac; return 1; }

# Does the MSBuild property list "$1" (Name=value, several joined by ; or ,) set only allowed properties?
_dotnet_scope_properties_whole() {
  local item name
  local -a items
  [ -n "$1" ] || return 1
  IFS=';,' read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    case "$item" in *=*) ;; *) return 1 ;; esac
    name=${item%%=*}; name=${name,,}
    _dotnet_scope_listed "$name" "$_DOTNET_SCOPE_WHOLE_PROPERTIES" || return 1
  done
  return 0
}

# Is the word "$1" an allowed environment setting (NAME=value with NAME allowed)?
_dotnet_scope_environment_whole() {
  case "$1" in [A-Za-z_]*=*) _dotnet_scope_listed "${1%%=*}" "$_DOTNET_SCOPE_WHOLE_ENVIRONMENT" ;; *) return 1 ;; esac
}

# Is the one invocation whose arguments are "$@" (up to its separator) a WHOLE run? Only listed words pass. The
# solution it names (lower case, without a leading ./) is left in _DOTNET_SCOPE_SOLUTION, empty for none.
_dotnet_scope_invocation_whole() {
  local word lower value=0 solution_value=0 solutions=0
  _DOTNET_SCOPE_SOLUTION=''
  for word in "$@"; do
    # A word the reader cannot see the value of (a variable, a substitution, an ANSI-C string) is never allowed.
    case "$word" in *'$'*|*'`'*) return 1 ;; esac
    lower=${word,,}
    if [ "$solution_value" = 1 ]; then
      solution_value=0
      case "$lower" in *.sln|*.slnx) ;; *) return 1 ;; esac
      solutions=$((solutions + 1)); _DOTNET_SCOPE_SOLUTION=${lower#./}; continue
    fi
    if [ "$value" = 1 ]; then value=0; continue; fi
    case "$word" in
      '>'|'>>'|'<'|[0-9]'>'|[0-9]'>>'|'&>'|'&>>') value=1; continue ;;   # a redirection and its target
      '>'?*|'<'?*|[0-9]'>'?*|'&>'?*) continue ;;                          # a redirection written with its target
    esac
    if _dotnet_scope_listed "$word" "$_DOTNET_SCOPE_WHOLE_FLAGS"; then continue; fi
    case "$word" in -bl:*|/bl:*) continue ;; esac
    if _dotnet_scope_listed "$word" "$_DOTNET_SCOPE_WHOLE_VALUE_OPTIONS"; then value=1; continue; fi
    case "$word" in
      --solution) solution_value=1; continue ;;   # the solution named as an option (dotnet 10)
      --solution=*) set -- "${word#*=}"; lower=${1,,}
        case "$lower" in *.sln|*.slnx) solutions=$((solutions + 1)); _DOTNET_SCOPE_SOLUTION=${lower#./}; [ "$solutions" -le 1 ] && continue ;; esac
        return 1 ;;
      --*=*|-?*:*|/?*:*) _dotnet_scope_listed "${word%%[=:]*}" "$_DOTNET_SCOPE_WHOLE_VALUE_OPTIONS" && continue ;;
    esac
    case "$lower" in
      -p:*|/p:*|--property:*|-property:*|/property:*) _dotnet_scope_properties_whole "${word#*:}" && continue; return 1 ;;
      *.sln|*.slnx) solutions=$((solutions + 1)); _DOTNET_SCOPE_SOLUTION=${lower#./}; [ "$solutions" -le 1 ] && continue; return 1 ;;
      .|./) solutions=$((solutions + 1)); [ "$solutions" -le 1 ] && continue; return 1 ;;
    esac
    return 1   # anything else may narrow the run
  done
  [ "$value" = 0 ] && [ "$solution_value" = 0 ]   # an option or redirection left without its value cannot be read
}

# Are the words "$@" (from the start of the statement up to `dotnet`) only allowed prefixes? `time` (also by path,
# with -v/-p, or -f/-o and a value), `timeout [-k|-s value] <duration>`, `nice [-n N | -N]`, `command`, `exec`,
# `env [-i] [-u NAME]`, and settings of allowed environment variables.
_dotnet_scope_prefix_whole() {
  local word name expect=''
  for word in "$@"; do
    case "$word" in *'$'*|*'`'*) return 1 ;; esac
    case "$expect" in
      value) expect=''; continue ;;
      timeout)
        case "$word" in
          -k|-s|--kill-after|--signal) expect=timeout-value ;;
          -*) ;;
          [0-9]*) expect='' ;;
          *) return 1 ;;
        esac
        continue ;;
      timeout-value) expect=timeout; continue ;;
      nice) case "$word" in -n|--adjustment) expect=value; continue ;; -[0-9]*|--adjustment=*) expect=''; continue ;; esac; expect='' ;;
      time) case "$word" in -v|-p|--verbose|--portability) continue ;; -f|-o|--format|--output) expect=time-value; continue ;; esac; expect='' ;;
      time-value) expect=time; continue ;;
      env) case "$word" in -i|--ignore-environment) continue ;; -u|--unset) expect=env-value; continue ;; esac; expect='' ;;
      env-value) expect=env; continue ;;
    esac
    name=${word##*/}
    case "$name" in
      time) expect=time ;;
      timeout) expect=timeout ;;
      nice) expect=nice ;;
      env) expect=env ;;
      command|exec) ;;
      *) _dotnet_scope_environment_whole "$word" || return 1 ;;
    esac
  done
  case "$expect" in ''|time|nice|env) return 0 ;; esac
  return 1
}

# Is the statement "$@" (one command up to its separator, run BEFORE a `dotnet test`) harmless: one that cannot
# change which tests that run executes? Only listed statements pass; anything else (an assignment of a variable that is
# not allowed, `declare`/`typeset`/`readonly`/`set -a`, `source`/`.`, `eval`, `alias`, a function, a `cd` to a
# relative path, a write to a file) may narrow the run. A `dotnet build`/`restore` passes with whole-run arguments;
# the solution it names is left in _DOTNET_SCOPE_SOLUTION.
_dotnet_scope_statement_harmless() {
  local word
  _DOTNET_SCOPE_SOLUTION=''
  # Leading settings of allowed variables (for this statement only, or for the shell when nothing follows).
  while [ "$#" -gt 0 ] && case "$1" in [A-Za-z_]*=*) true ;; *) false ;; esac; do
    case "$1" in *'$'*|*'`'*) return 1 ;; esac
    _dotnet_scope_environment_whole "$1" || return 1
    shift
  done
  [ "$#" -eq 0 ] && return 0
  case "$1" in
    echo|printf)
      # Output only to the terminal: a write into a file (a props file, an env file) could narrow a later run.
      shift
      for word in "$@"; do
        case "$word" in
          [0-9]'>&'[0-9]|'>&'[0-9]) ;;
          '>'*|[0-9]'>'*|'&>'*) return 1 ;;
        esac
      done
      return 0 ;;
    true|:|pwd|date|nproc) [ "$#" -eq 1 ] ;;
    ls) shift; for word in "$@"; do case "$word" in *'>'*) return 1 ;; esac; done; return 0 ;;
    set)
      shift; [ "$#" -ge 1 ] || return 1
      for word in "$@"; do
        case "$word" in [-+]*[!euxo]*|[-+]) [ "$word" = -o ] || [ "$word" = +o ] || return 1 ;; [-+]*) ;;
          pipefail|errexit|nounset|xtrace) ;;
          *) return 1 ;;
        esac
      done
      return 0 ;;
    cd)
      # Only to an absolute path written out (taken as the repository root); a relative path or a variable may pick
      # another solution.
      [ "$#" -eq 2 ] || return 1
      case "$2" in *'$'*|*'`'*) return 1 ;; /*|[A-Za-z]:[/\\]*) return 0 ;; esac
      return 1 ;;
  esac
  case "${1##*/}" in
    dotnet|dotnet.exe)
      case "${2:-}" in
        --info|--version|--list-sdks|--list-runtimes) [ "$#" -eq 2 ] ;;
        build|restore) shift 2; _dotnet_scope_invocation_whole "$@" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

dotnet_test_is_partial() {
  local name verb i j k start=0 found=0 seen last_test=-1 solution='' statement_start
  # Fail closed: a command whose quotes do not close cannot be read, so it proves nothing about the whole suite.
  _dotnet_test_scope_words "$1" || return 0
  # Fail closed: every `dotnet test` in the text must be visible as words; one hidden in a quoted string (`bash -c`,
  # a double-quoted substitution) cannot be judged.
  seen=$(grep -oiE 'dotnet(\.exe)?["'"'"']?[[:space:]]+(vs)?test' <<<"$1" | grep -c .)
  local n=${#_DOTNET_SCOPE_WORDS[@]}
  # The last `dotnet test` / `dotnet vstest`: statements after it cannot change what it ran.
  for ((i = 0; i + 1 < n; i++)); do
    name=${_DOTNET_SCOPE_WORDS[i]##*/}; name=${name##*\\}; name=${name,,}; name=${name%.exe}
    verb=${_DOTNET_SCOPE_WORDS[i + 1],,}
    if [ "$name" = dotnet ]; then case "$verb" in test|vstest) last_test=$i ;; esac; fi
  done
  [ "$last_test" -ge 0 ] || return 0   # fail closed: no `dotnet test` found as words
  # Each statement up to the one holding the last run: a `dotnet test` statement is judged as a run, every other one
  # must be harmless. All solutions named (build, restore, test) must be the same one.
  for ((statement_start = 0; statement_start <= last_test; statement_start = j + 1)); do
    for ((j = statement_start; j < n; j++)); do [ "${_DOTNET_SCOPE_WORDS[j]}" = $'\x01' ] && break; done
    [ "$j" -gt "$statement_start" ] || continue
    k=-1
    for ((i = statement_start; i + 1 < j; i++)); do
      name=${_DOTNET_SCOPE_WORDS[i]##*/}; name=${name##*\\}; name=${name,,}; name=${name%.exe}
      verb=${_DOTNET_SCOPE_WORDS[i + 1],,}
      if [ "$name" = dotnet ]; then case "$verb" in test|vstest) k=$i; break ;; esac; fi
    done
    if [ "$k" -ge 0 ]; then
      [ "${_DOTNET_SCOPE_WORDS[k + 1],,}" = vstest ] && return 0
      found=$((found + 1))
      _dotnet_scope_prefix_whole "${_DOTNET_SCOPE_WORDS[@]:statement_start:k-statement_start}" || return 0
      _dotnet_scope_invocation_whole "${_DOTNET_SCOPE_WORDS[@]:k+2:j-k-2}" || return 0
    else
      _dotnet_scope_statement_harmless "${_DOTNET_SCOPE_WORDS[@]:statement_start:j-statement_start}" || return 0
    fi
    if [ -n "$_DOTNET_SCOPE_SOLUTION" ]; then
      [ -z "$solution" ] || [ "$solution" = "$_DOTNET_SCOPE_SOLUTION" ] || return 0
      solution=$_DOTNET_SCOPE_SOLUTION
    fi
  done
  # Fail closed: fewer `dotnet test` runs read as words than the text holds.
  [ "$found" -ge "$seen" ] || return 0
  return 1
}
