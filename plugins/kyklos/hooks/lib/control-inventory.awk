# control-inventory.awk - derive the plugin's control switches from the code that reads them. Read by
# control-inventory.sh; one or more shell files on the command line.
#
# A control switch is a variable whose value reaches the one control-switch reader, kyklos_control_off. Read as:
#   * directly, `kyklos_control_off "${NAME:-...}"` or `kyklos_control_off "$NAME"`, NAME in upper case;
#   * through a command that reads the setting, `kyklos_control_off "$(read_setting "$f" NAME)"`;
#   * through a variable of the same file that is assigned from the switch, `v="${NAME:-x}"`, `v="$NAME"` or
#     `v="$(any_reader "$f" NAME)"` (the last word an upper-case NAME), then `kyklos_control_off "$v"`.
# Output, one line per switch read: "control<TAB>NAME". For every `${NAME:-default}` with a non-empty default in the
# same files: "default<TAB>NAME<TAB>default", so a value equal to the code's own default reads as "on".
# Comment lines are skipped: a switch named only in a comment is not read by the code.
function flush_file(   v, n, i, parts) {
    for (v in called) {
        if (v in assigned) {
            n = split(assigned[v], parts, " ")
            for (i = 1; i <= n; i++) if (parts[i] != "") print "control\t" parts[i]
        } else if (v ~ /^[A-Z][A-Z0-9_]*$/) {
            print "control\t" v
        }
    }
    delete called; delete assigned
}
FNR == 1 && NR > 1 { flush_file() }
/^[[:space:]]*#/ { next }
{
    line = $0
    # a call to the reader: the variable whose value it judges
    rest = line
    while (match(rest, /kyklos_control_off[[:space:]]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
        call = substr(rest, RSTART, RLENGTH)
        sub(/^kyklos_control_off[[:space:]]+"?\$\{?/, "", call)
        called[call] = 1
        rest = substr(rest, RSTART + RLENGTH)
    }
    # a call that reads the switch through a command: kyklos_control_off "$(read_setting "$f" NAME)"
    rest = line
    while (match(rest, /kyklos_control_off[[:space:]]+"?\$\([^)]*[[:space:]]"?[A-Z][A-Z0-9]*_[A-Z0-9_]*"?\)/)) {
        call = substr(rest, RSTART, RLENGTH)
        sub(/"?\)$/, "", call); sub(/.*[[:space:]]"?/, "", call)
        print "control\t" call
        rest = substr(rest, RSTART + RLENGTH)
    }
    # an assignment of a variable from a switch
    rest = line
    while (match(rest, /(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*="?(\$\{[A-Z][A-Z0-9_]*|\$[A-Z][A-Z0-9]*_[A-Z0-9_]*|\$\([A-Za-z_][A-Za-z0-9_]*[^)]*[[:space:]]"?[A-Z][A-Z0-9]*_[A-Z0-9_]*"?\))/)) {
        asg = substr(rest, RSTART, RLENGTH)
        sub(/^[^A-Za-z_]/, "", asg)
        var = asg; sub(/=.*/, "", var)
        name = asg; sub(/^[^=]*="?/, "", name)
        if (name ~ /^\$\{/) { sub(/^\$\{/, "", name) }
        else if (name ~ /^\$[A-Z]/) { sub(/^\$/, "", name) }
        else { sub(/"?\)$/, "", name); sub(/.*[[:space:]]"?/, "", name) }
        if (index(" " assigned[var] " ", " " name " ") == 0) assigned[var] = assigned[var] " " name
        rest = substr(rest, RSTART + RLENGTH)
    }
    # a default the code gives a switch
    rest = line
    while (match(rest, /\$\{[A-Z][A-Z0-9_]*:-[A-Za-z0-9_.-]+\}/)) {
        d = substr(rest, RSTART + 2, RLENGTH - 3)
        name = d; sub(/:-.*/, "", name)
        val = d; sub(/^[^:]*:-/, "", val)
        print "default\t" name "\t" val
        rest = substr(rest, RSTART + RLENGTH)
    }
}
END { flush_file() }
