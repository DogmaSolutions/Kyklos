#!/usr/bin/env bash
# public-sign-local.sh (Kyklos / running-tests) - build a strong-name InternalsVisibleTo project LOCALLY without
# the private signing key, using the PUBLIC key already embedded in the project.
#
# THE PROBLEM: a project that declares `<InternalsVisibleTo Include="X" Key="<public key hex>"/>` compiles fine in CI
# (which signs with the real private key from a CI variable) but FAILS locally with CS0281 - "the public key of the
# output assembly ('') does not match ... InternalsVisibleTo" - because the local build is unsigned and there is no
# key file in the repo. An agent building locally (or the KyklosBridge on a dev host) hits this on every build.
#
# THE FIX (secret-free): the compiler's PublicSign mode marks the output as strong-name-signed using ONLY the PUBLIC
# key - no signature, no private key. The public key is already in the csproj (the InternalsVisibleTo `Key=` hex), so
# we extract it, write it as a public-key-only .snk, and hand it to the build via PublicSign. Both the analyzer and
# its test assembly then carry the same org public key -> the friend-access check passes. NOTHING secret is involved.
# [CySec] Prevents CWE-798 hardcoded-credential misuse: uses the PUBLIC key only; a private/secret key never touches
# the dev host or the container.
#
# USAGE:
#   public-sign-local.sh <csproj-with-InternalsVisibleTo> [--out <snk>]            # extract key -> .snk, PRINT the flags
#   public-sign-local.sh <csproj> --build <sln-or-csproj> [-- <extra dotnet args>] # ...and run `dotnet build` signed
#   public-sign-local.sh <csproj> --test  <sln-or-csproj> [-- <extra dotnet args>] # ...and run `dotnet test`  signed
#
# The emitted flags (reuse them with any dotnet verb):
#   -p:SignAssembly=true -p:PublicSign=true -p:DelaySign=false -p:AssemblyOriginatorKeyFile=<snk>
set -euo pipefail

die() { printf 'public-sign-local: %s\n' "$1" >&2; exit 1; }

[ $# -ge 1 ] || die "need a csproj that declares <InternalsVisibleTo ... Key=\"...\">. See the header for usage."
CSPROJ="$1"; shift
[ -f "$CSPROJ" ] || die "csproj not found: $CSPROJ"

OUT=""; VERB=""; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT="${2:-}"; shift 2 || die "missing value after $1" ;;
    --build) VERB="build"; TARGET="${2:-}"; shift 2 || die "missing value after $1" ;;
    --test)  VERB="test";  TARGET="${2:-}"; shift 2 || die "missing value after $1" ;;
    --)      shift; break ;;
    *)       die "unknown arg: $1" ;;
  esac
done
EXTRA=("$@")   # anything after `--` is passed through to dotnet

# Extract the FIRST InternalsVisibleTo public-key hex (Key="..." OR PublicKey="..."). One physical or multi-line tag.
HEX="$(tr -d '\n\r' < "$CSPROJ" \
  | grep -oiE '<InternalsVisibleTo[^>]*(Key|PublicKey)[[:space:]]*=[[:space:]]*"[0-9a-fA-F]+"' \
  | grep -oiE '"[0-9a-fA-F]+"' | head -1 | tr -d '"' | tr 'A-F' 'a-f' || true)"
[ -n "$HEX" ] || die "no <InternalsVisibleTo ... Key=\"<hex>\"> found in $CSPROJ - nothing to public-sign (is the project actually strong-named?)."
# a real public-key blob is >= 160 bytes (320 hex chars); a bare 16-hex token is NOT a usable key file.
[ "${#HEX}" -ge 320 ] || die "the InternalsVisibleTo value looks like a public-key TOKEN (${#HEX} hex chars), not a full PUBLIC KEY. PublicSign needs the full key - put the full public key in the Key= attribute."

[ -n "$OUT" ] || OUT="$(mktemp -t kyklos-publicsign.XXXXXX.snk)"
python3 -c 'import sys,binascii; open(sys.argv[1],"wb").write(binascii.unhexlify(sys.argv[2]))' "$OUT" "$HEX" \
  || die "could not write the public-key .snk (odd-length or non-hex Key?)."
printf 'public-sign-local: wrote public-key-only .snk -> %s (%s bytes, from %s)\n' "$OUT" "$(wc -c < "$OUT" | tr -d ' ')" "$CSPROJ" >&2

FLAGS=(-p:SignAssembly=true -p:PublicSign=true -p:DelaySign=false "-p:AssemblyOriginatorKeyFile=$OUT")

if [ -z "$VERB" ]; then
  # PRINT mode: emit the flags on stdout so a caller can `eval`/append them.
  printf '%s ' "${FLAGS[@]}"; printf '\n'
  exit 0
fi

[ -n "$TARGET" ] || die "--$VERB needs a solution or project to build."
command -v dotnet >/dev/null 2>&1 || die "dotnet not on PATH."
set -x
dotnet "$VERB" "$TARGET" -c Release "${FLAGS[@]}" "${EXTRA[@]}"
