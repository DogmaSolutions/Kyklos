#!/usr/bin/env bash
# shell options: inherited from the caller (a sourced-only library; it never runs on its own).
# audience-lint-version-mask.sh - sourced by the audience-lint engine and the cross-repository write guard, so both
# judge the same text. The dotted number of the exact version fields the .NET tools write is replaced by <version>
# before any pattern is applied: the "assemblyVersion" and "fileVersion" keys of a dependency manifest, the
# AssemblyVersion, AssemblyFileVersion and AssemblyInformationalVersion attributes, and the Version= part of an
# assembly-qualified name (", Version=4.0.0.0, Culture="). Such a number can read like an IPv4 address to the
# private-address pattern but is never an internal marker. The number must end at the field's closing quote, so a value
# carrying more (an address with a port) stays judged; a bare address written as such a version value cannot be told
# from a version and is not caught (an unlikely mistake in a field the build tools write). Nothing else is masked: a dotted number after the bare word
# "version" (a server banner, a configuration key, a longer name ending in Version) stays judged, because a real
# private address written there is a plausible mistake. Lines are kept one for one, so a hit still names its own line.

# The dotted number of a version value.
AL_VERSION_NUMBER='[0-9]+(\.[0-9]+){1,3}'
# The dependency-manifest keys, exact and case-sensitive: "assemblyVersion": "1.0.0.0", "fileVersion": "1.0.0.0".
AL_VERSION_MASK_MANIFEST='("(assemblyVersion|fileVersion)"[[:space:]]*:[[:space:]]*")'"${AL_VERSION_NUMBER}"'(([-+][0-9A-Za-z.+-]*)?")'
# The assembly attributes: AssemblyVersion("1.0.0.0"), AssemblyFileVersion(...), AssemblyInformationalVersion(...).
AL_VERSION_MASK_ATTRIBUTE='(Assembly(File|Informational)?Version(Attribute)?[[:space:]]*\([[:space:]]*@?")'"${AL_VERSION_NUMBER}"'(([-+][0-9A-Za-z.+-]*)?")'
# The Version= part of an assembly-qualified name, which is always followed by its Culture= part.
AL_VERSION_MASK_QUALIFIED='(,[[:space:]]*Version=)'"${AL_VERSION_NUMBER}"'([[:space:]]*,[[:space:]]*Culture=)'

# al_mask_versions [FILE] - print FILE (or stdin) with the value of every .NET version field replaced by <version>.
al_mask_versions() {
  sed -E \
    -e "s/${AL_VERSION_MASK_MANIFEST}/\\1<version>\\4/g" \
    -e "s/${AL_VERSION_MASK_ATTRIBUTE}/\\1<version>\\5/g" \
    -e "s/${AL_VERSION_MASK_QUALIFIED}/\\1<version>\\3/g" \
    -- "$@"
}
