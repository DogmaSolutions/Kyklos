#!/usr/bin/perl
# free-text-blank.pl -- read a shell command on stdin, print it with the VALUE of each free-text option emptied: a
# title, goal, search text or commit message (--title, --goal, --search, --message, -m). Such a value may describe an
# API call without making one, so a guard that inspects the command for a raw write must not read it.
#
# The command is walked as the shell reads it (single and double quotes, backslashes, comments), so only a flag that is
# a word of its own, outside any quote and comment, counts. Only a value that cannot run anything is emptied, and only
# when it is a whole word: a single-quoted string, a double-quoted string with no command substitution (no "$(" and no
# backtick), or a "$(cat <<'TAG' ... TAG)" message whose heredoc tag is quoted (its body is literal text for cat).
# Anything this walk cannot follow for certain - an unbalanced quote, an ANSI $'...' string, a command substitution
# inside double quotes - stops the emptying: the rest of the command is printed as it is, so the guard sees more, never
# less.
use strict;
use warnings;

local $/;
my $text = <STDIN>;
$text = '' unless defined $text;

my $FLAG = qr/(--title|--goal|--search|--message|-m)(=|[ \t]+)/;
my $WORD_END = qr/(?:[ \t\n;&|)]|\z)/;

# double_quoted_end($pos) -> the index of the closing quote of the double-quoted string opening at $pos, or -1.
sub double_quoted_end {
    my ($pos) = @_;
    my $j = $pos + 1;
    while ($j < length $text) {
        my $c = substr($text, $j, 1);
        if ($c eq '\\') { $j += 2; next; }
        return $j if $c eq '"';
        $j++;
    }
    return -1;
}

# value_length($pos) -> the length of an emptiable free-text value starting at $pos, or 0.
sub value_length {
    my ($pos) = @_;
    my $rest = substr($text, $pos);
    if ($rest =~ /\A"\$\(cat[ \t]+<<-?[ \t]*(['"])(\w+)\1[ \t]*\n/) {
        my ($tag, $head) = ($2, $+[0]);
        my $body = substr($rest, $head);
        # The heredoc ends at the FIRST line that is the tag, as the shell ends it; only ")" and the quote may follow.
        return 0 unless $body =~ /^[ \t]*\Q$tag\E[ \t]*\n/m;
        my $after = $head + $+[0];
        return 0 unless substr($rest, $after) =~ /\A\s*\)"(?=$WORD_END)/;
        return $after + $+[0];
    }
    if ($rest =~ /\A'[^']*'(?=$WORD_END)/) { return $+[0]; }
    if (substr($rest, 0, 1) eq '"') {
        my $end = double_quoted_end($pos);
        return 0 if $end < 0;
        my $inner = substr($text, $pos + 1, $end - $pos - 1);
        return 0 if $inner =~ /\$\(|`/;
        return 0 unless substr($text, $end + 1) =~ /\A$WORD_END/;
        return $end - $pos + 1;
    }
    return 0;
}

my ($out, $i, $at_word) = ('', 0, 1);
my $n = length $text;
while ($i < $n) {
    my $c = substr($text, $i, 1);
    if ($c eq "'") {
        my $j = index($text, "'", $i + 1);
        last if $j < 0;
        $out .= substr($text, $i, $j - $i + 1); $i = $j + 1; $at_word = 0; next;
    }
    if ($c eq '"') {
        my $j = double_quoted_end($i);
        last if $j < 0;
        last if substr($text, $i + 1, $j - $i - 1) =~ /\$\(|`/;
        $out .= substr($text, $i, $j - $i + 1); $i = $j + 1; $at_word = 0; next;
    }
    last if $c eq '$' && substr($text, $i + 1, 1) eq "'";
    if ($c eq '\\') { $out .= substr($text, $i, 2); $i += 2; $at_word = 0; next; }
    if ($c eq '#' && $at_word) {
        my $j = index($text, "\n", $i);
        $j = $n if $j < 0;
        $out .= substr($text, $i, $j - $i); $i = $j; next;
    }
    if ($c =~ /[ \t\n;&|()<>]/) { $out .= $c; $i++; $at_word = 1; next; }
    if ($at_word && substr($text, $i) =~ /\A$FLAG/) {
        my $flag = $&;
        my $len = value_length($i + length $flag);
        if ($len > 0) { $out .= $flag . "''"; $i += length($flag) + $len; $at_word = 0; next; }
    }
    $out .= $c; $i++; $at_word = 0;
}
$out .= substr($text, $i) if $i < $n;
print $out;
