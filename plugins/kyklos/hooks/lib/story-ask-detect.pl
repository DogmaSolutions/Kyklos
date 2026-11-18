#!/usr/bin/perl
# story-ask-detect.pl -- read the agent's closing message on stdin and print the stories and issues it asks the owner
# about, one line each:
#   ask <iid>      a question addressed to the owner names this story or issue
#   linked <iid>   the message links a note on this story or issue (an issue web link ending in "#note_<n>")
#
# A question addressed to the owner is a sentence that ends with a question mark and carries an owner tell (you, your,
# "should I", "may we", "ok to", approve, agree, confirm, decide, prefer, which, whether), or the owner-blocker form (a
# block that starts "Blocked on you:" and holds a question mark). The story or issue must be named IN THE QUESTION
# SENTENCE ITSELF (or in a parenthesis right after its question mark, "Should I close it? (story 42)"), so a status line
# before a question that is about something else ("Story 42 closed. Do you want me to continue?") asks nothing; for the
# owner-blocker form it may be named anywhere in its block up to the question mark. A reference is "story <n>",
# "stories <n> and <m>", "issue <n>", the upper-case story key with a dash and the number, "#<n>",
# "<group>/<project>#<n>" or an issue web link. A bare number ("Should I continue with 812?") is deliberately NOT a
# reference: only the forms the project itself writes for its items count, because reading every number in a question
# as an item would refuse questions about versions, counts and pipeline numbers. "#<n>" right after "pipeline", "job",
# "run", "note", "MR" or "merge request" names no issue.
#
# Never an ask: a generic closing or continuation question ("anything else?", "Do you want me to continue?", "Shall I
# proceed?"), and a question the message answers itself: a question whose only tell is "which" or "whether" (not put
# to the owner directly) followed in the same paragraph by a statement that is not a recommendation ("Which change
# broke story 5? It was the cache.").
#
# Text the owner does not read as the agent's own question is ignored: fenced code blocks, quoted lines ("> ...") and
# code spans. Links are reduced to "issue <iid>" (or dropped), so a question mark inside a link never ends a sentence.
use strict;
use warnings;

local $/;
my $text = <STDIN>;
$text = '' unless defined $text;
$text =~ s/\r//g;

# Fenced code blocks and quoted lines.
my @kept;
my $fenced = 0;
for my $line (split /\n/, $text, -1) {
    if ($line =~ /^\s*(```|~~~)/) { $fenced = !$fenced; push @kept, ''; next; }
    if ($fenced || $line =~ /^\s*>/) { push @kept, ''; next; }
    push @kept, $line;
}
$text = join("\n", @kept);
$text =~ s/`[^`\n]*`/ /g;

my %linked;
while ($text =~ m{https?://\S*?/-/issues/(\d+)#note_\d+}g) { $linked{$1 + 0} = 1; }
$text =~ s{https?://\S*?/-/issues/(\d+)\S*}{ issue $1 }g;
$text =~ s{https?://\S+}{ link }g;

my $KEY = 'story' . '-0*';
sub refs_in {
    my ($s) = @_;
    my %found;
    while ($s =~ /(?<![\w\/.-])$KEY(\d+)\b/gi) { $found{$1 + 0} = 1; }
    while ($s =~ /\b(?:stor(?:y|ies)|issues?)\s+(#?\d+(?:\s*(?:,|and|or|&)\s*#?\d+)*)\b/gi) {
        my $list = $1;
        $found{$_ + 0} = 1 for ($list =~ /(\d+)/g);
    }
    while ($s =~ /(?<![&\w])((?:[\w.-]+(?:\/[\w.-]+)*)?)#(\d+)\b/g) {
        my ($path, $n, $at) = ($1, $2, $-[0]);
        my $before = lc substr($s, $at < 30 ? 0 : $at - 30, $at < 30 ? $at : 30);
        next if $path eq '' && $before =~ /(pipeline|job|run|note|mr|merge request|step|case|item)\s*$/;
        $found{$n + 0} = 1;
    }
    return keys %found;
}

my $DIRECT = qr/\b(you|your|yours)\b|\b(should|shall|may|can|could) (i|we)\b|\b(ok|okay|fine|alright) (to|if|with)\b|\bapprov|\bagree|\bconfirm|\bdecid|\bdecision|\bprefer/i;
my $WEAK = qr/\bwhich\b|\bwhether\b/i;
my $GENERIC = qr/\banything else\b|\bany (other|more|further) questions\b/i;
# A continuation question on its own: the whole sentence asks only whether to go on.
my $CONTINUE = qr/^\W*(?:(?:do|would) you (?:want|like) me to|(?:should|shall|may|can) (?:i|we)|(?:want|ok|okay) (?:me )?to|ok if i)?\s*(?:continue|proceed|go on|keep going|carry on|go ahead|move on)(?:\s+(?:now|then|with (?:the )?next(?: one| item| step)?|with the rest))?\s*\?["')*_\]]*\s*$/i;
my $RECOMMEND = qr/\b(recommend|suggest|propose|i'd|i would|my pick|my choice)\b/i;
# Blocks: paragraphs (split on blank lines), and every list item starts a block of its own.
my @blocks;
my $cur = '';
for my $line (split /\n/, $text, -1) {
    if ($line =~ /^\s*$/) { push @blocks, $cur if $cur ne ''; $cur = ''; next; }
    if ($line =~ /^\s*([-*+]|\d+[.)])\s+/) { push @blocks, $cur if $cur ne ''; $cur = $line; next; }
    $cur = $cur eq '' ? $line : "$cur $line";
}
push @blocks, $cur if $cur ne '';

my %asked;
for my $block (@blocks) {
    if ($block =~ /^\s*(?:[-*+]\s+)?(?:\*\*|__)?blocked on you:(.*)$/i) {
        my $rest = $1;
        my $q = index($rest, '?');
        if ($q >= 0) { $asked{$_} = 1 for refs_in(substr($rest, 0, $q)); }
    }
    my @sentences = split /(?<=[.!?])\s+/, $block;
    for my $i (0 .. $#sentences) {
        my $s = $sentences[$i];
        next unless $s =~ /\?["')*_\]]*\s*$/;
        next if $s =~ $GENERIC || $s =~ $CONTINUE;
        my $direct = $s =~ $DIRECT;
        next unless $direct || $s =~ $WEAK;
        my $next = $i < $#sentences ? $sentences[$i + 1] : '';
        # A parenthesis right after the question mark belongs to the question: "Should I close it? (story 42)".
        my $trailer = $next =~ /^\(([^()]*)\)/ ? $1 : '';
        # Answered by the message itself: an indirect question followed by a statement that is not a recommendation.
        next if !$direct && $trailer eq '' && $next ne '' && $next !~ /\?["')*_\]]*\s*$/ && $next !~ $RECOMMEND;
        $asked{$_} = 1 for refs_in($s), ($trailer ne '' ? refs_in($trailer) : ());
    }
}

print "ask $_\n" for sort { $a <=> $b } keys %asked;
print "linked $_\n" for sort { $a <=> $b } keys %linked;
