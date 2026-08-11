#!/usr/bin/env sh
set -eu

# Rewrite private place bridge calls to the legacy source forms accepted by a
# published seed. This only runs over the disposable bootstrap source mirror.
# The embedded parser understands strings, character literals, comments,
# nested lists, and quote prefixes; a regular expression cannot safely find
# the end of an arbitrary projection target.

if [ "$#" -lt 1 ]; then
    echo "usage: $0 root [root ...]" >&2
    exit 2
fi

if ! command -v perl >/dev/null 2>&1; then
    echo "private place seed bridge requires perl" >&2
    exit 1
fi

exec perl - "$@" <<'PERL'
use strict;
use warnings;

use Encode qw(encode_utf8);
use File::Find qw(find);
use JSON::PP qw(decode_json);

my %private_names = map { $_ => 1 } qw(
    __tl-project-field
    __tl-project-set-field
    __tl-project-field-name
    __tl-project-set-field-name
    __tl-box-place
);
my $lexical_event = qr{
    [";']
    | __tl-project-(?:set-)?field(?:-name)?
    | __tl-box-place
}x;
my $source_path = '<unknown>';

sub fail {
    my ($message) = @_;
    die "$source_path: $message\n";
}

sub char_literal_end {
    my ($text_ref, $pos) = @_;
    my $length = length $$text_ref;
    return undef
        if $pos >= $length || substr($$text_ref, $pos, 1) ne "'";
    my $second = substr($$text_ref, $pos + 1, 1);
    return $pos + 3
        if $pos + 2 < $length
        && $second ne '\\'
        && substr($$text_ref, $pos + 2, 1) eq "'";
    return $pos + 4
        if $pos + 3 < $length
        && $second eq '\\'
        && substr($$text_ref, $pos + 3, 1) eq "'";
    return undef;
}

sub string_end {
    my ($text_ref, $pos) = @_;
    my $start = $pos;
    pos($$text_ref) = $pos + 1;
    if ($$text_ref =~ /\G(?:[^"\\]|\\.)*"/gcs) {
        return pos($$text_ref);
    }
    fail("unterminated string literal at offset $start");
}

sub skip_trivia {
    my ($text_ref, $pos) = @_;
    my $length = length $$text_ref;
    while ($pos < $length) {
        my $ch = substr($$text_ref, $pos, 1);
        if ($ch =~ /\s/) {
            $pos += 1;
        } elsif ($ch eq ';') {
            my $newline = index($$text_ref, "\n", $pos);
            return $length if $newline < 0;
            $pos = $newline + 1;
        } else {
            return $pos;
        }
    }
    return $pos;
}

sub expression_end {
    my ($text_ref, $pos) = @_;
    $pos = skip_trivia($text_ref, $pos);
    my $length = length $$text_ref;
    fail('missing expression') if $pos >= $length;
    my $ch = substr($$text_ref, $pos, 1);
    return string_end($text_ref, $pos) if $ch eq '"';
    my $literal_end = char_literal_end($text_ref, $pos);
    return $literal_end if defined $literal_end;

    if ($ch eq '(' || $ch eq '[') {
        my $close = $ch eq '(' ? ')' : ']';
        my $depth = 1;
        my $cursor = $pos + 1;
        while ($cursor < $length) {
            my $nested_literal_end = char_literal_end($text_ref, $cursor);
            if (defined $nested_literal_end) {
                $cursor = $nested_literal_end;
                next;
            }
            my $nested = substr($$text_ref, $cursor, 1);
            if ($nested eq '"') {
                $cursor = string_end($text_ref, $cursor);
            } elsif ($nested eq ';') {
                my $newline = index($$text_ref, "\n", $cursor);
                $cursor = $newline < 0 ? $length : $newline + 1;
            } elsif ($nested eq $ch) {
                $depth += 1;
                $cursor += 1;
            } elsif ($nested eq $close) {
                $depth -= 1;
                $cursor += 1;
                return $cursor if $depth == 0;
            } elsif ($nested eq '(' || $nested eq '[') {
                $cursor = expression_end($text_ref, $cursor);
            } else {
                $cursor += 1;
            }
        }
        fail("unterminated $ch expression at offset $pos");
    }

    return expression_end($text_ref, $pos + 1) if $ch eq "'" || $ch eq '`';
    if ($ch eq ',') {
        my $prefix = substr($$text_ref, $pos, 2) eq ',@' ? 2 : 1;
        return expression_end($text_ref, $pos + $prefix);
    }

    my $cursor = $pos;
    while ($cursor < $length) {
        $ch = substr($$text_ref, $cursor, 1);
        last if $ch =~ /\s/ || index('()[];', $ch) >= 0;
        $cursor += 1;
    }
    fail("invalid expression at offset $pos") if $cursor == $pos;
    return $cursor;
}

sub call_start_before_head {
    my ($text_ref, $head_start) = @_;
    return undef if $head_start == 0;
    my $open = rindex($$text_ref, '(', $head_start - 1);
    while ($open >= 0) {
        # If the nearest opening parenthesis is inside a trivia comment, retry
        # before that comment. Strings are not valid list-head trivia.
        my $line_break = $open > 0
            ? rindex($$text_ref, "\n", $open - 1) : -1;
        my $line_start = $line_break + 1;
        my $semicolon = index($$text_ref, ';', $line_start);
        if ($semicolon >= 0 && $semicolon < $open) {
            $open = $semicolon > 0
                ? rindex($$text_ref, '(', $semicolon - 1) : -1;
            next;
        }
        my $between = substr(
            $$text_ref,
            $open + 1,
            $head_start - $open - 1,
        );
        if ($between =~ /\A(?:[[:space:]]|;[^\n]*(?:\n|\z))*\z/) {
            return $open;
        }
        return undef;
    }
    return undef;
}

sub find_calls {
    my ($text_ref) = @_;
    my $scan = $$text_ref;
    my $scan_ref = \$scan;
    my @calls;
    my $length = length $scan;
    my $pos = 0;
    while ($pos < $length) {
        pos($scan) = $pos;
        last if $scan !~ /$lexical_event/g;
        $pos = $-[0];
        my $event_end = $+[0];

        my $literal_end = char_literal_end($scan_ref, $pos);
        if (defined $literal_end) {
            $pos = $literal_end;
            next;
        }
        my $ch = substr($scan, $pos, 1);
        if ($ch eq '"') {
            $pos = string_end($scan_ref, $pos);
            next;
        }
        if ($ch eq ';') {
            my $newline = index($scan, "\n", $pos);
            $pos = $newline < 0 ? $length : $newline + 1;
            next;
        }
        if ($ch eq "'") {
            $pos += 1;
            next;
        }

        my $name = substr($scan, $pos, $event_end - $pos);
        my $following = $event_end < $length
            ? substr($scan, $event_end, 1) : '';
        if ($following ne ''
                && $following !~ /[[:space:]()\[\];]/) {
            $pos = $event_end;
            next;
        }
        my $call_start = call_start_before_head($scan_ref, $pos);
        if (!defined $call_start || !$private_names{$name}) {
            $pos = $event_end;
            next;
        }

        my $expected = $name eq '__tl-box-place' ? 1
            : index($name, 'set-field') >= 0 ? 3 : 2;
        my @args;
        my $cursor = $event_end;
        for (1 .. $expected) {
            my $start = skip_trivia($scan_ref, $cursor);
            my $end = expression_end($scan_ref, $start);
            push @args, [$start, $end];
            $cursor = $end;
        }
        $cursor = skip_trivia($scan_ref, $cursor);
        fail("$name has unexpected arity at offset $call_start")
            if $cursor >= $length || substr($scan, $cursor, 1) ne ')';
        push @calls, {
            start => $call_start,
            end => $cursor + 1,
            name => $name,
            args => \@args,
        };
        $pos = $event_end;
    }
    return @calls;
}

sub field_text {
    my ($raw, $string_name) = @_;
    return $raw if !$string_name;

    my $value;
    my $ok = eval {
        $value = decode_json(encode_utf8($raw));
        1;
    };
    fail("invalid field string $raw") if !$ok || ref $value;
    fail("field string is not a source identifier: $raw")
        if $value eq '' || $value =~ /[\s()\[\]{}"';`,\\]/;
    return $value;
}

sub render_segment;

sub replacement {
    my ($text, $call, $calls) = @_;
    my @args;
    for my $span (@{$call->{args}}) {
        my @children = grep {
            $calls->[$_]->{start} >= $span->[0]
                && $calls->[$_]->{end} <= $span->[1]
        } @{$call->{children}};
        push @args, render_segment(
            $text,
            $span->[0],
            $span->[1],
            \@children,
            $calls,
        );
    }
    return "(box-get $args[0])" if $call->{name} eq '__tl-box-place';

    my $field = field_text(
        $args[1],
        $call->{name} =~ /-field-name\z/,
    );
    return "(set! (struct-get $args[0] $field) $args[2])"
        if index($call->{name}, 'set-field') >= 0;
    return "(struct-get $args[0] $field)";
}

sub render_segment {
    my ($text, $start, $end, $child_indices, $calls) = @_;
    my @parts;
    my $cursor = $start;
    for my $index (@{$child_indices}) {
        my $child = $calls->[$index];
        fail('overlapping private place bridge calls')
            if $child->{start} < $cursor || $child->{end} > $end;
        push @parts, substr($text, $cursor, $child->{start} - $cursor);
        push @parts, replacement($text, $child, $calls);
        $cursor = $child->{end};
    }
    push @parts, substr($text, $cursor, $end - $cursor);
    return join '', @parts;
}

sub rewrite_source {
    my ($text) = @_;
    my @calls = find_calls(\$text);
    return ($text, 0) if !@calls;

    my @top_level;
    my @stack;
    for my $index (0 .. $#calls) {
        $calls[$index]->{children} = [];
        while (@stack
                && $calls[$index]->{start} >= $calls[$stack[-1]]->{end}) {
            pop @stack;
        }
        if (@stack) {
            my $parent = $stack[-1];
            fail('overlapping private place bridge calls')
                if $calls[$index]->{end} > $calls[$parent]->{end};
            push @{$calls[$parent]->{children}}, $index;
        } else {
            push @top_level, $index;
        }
        push @stack, $index;
    }

    my $rewritten = render_segment(
        $text,
        0,
        length($text),
        \@top_level,
        \@calls,
    );
    return ($rewritten, scalar @calls);
}

my %seen;
my @paths;
for my $root (@ARGV) {
    die "private place seed bridge root is not a directory: $root\n" if !-d $root;
    find(
        {
            no_chdir => 1,
            wanted => sub {
                return if -l $_ || !-f $_ || $_ !~ /\.tl\z/;
                my $path = $File::Find::name;
                push @paths, $path if !$seen{$path}++;
            },
        },
        $root,
    );
}

my $total = 0;
for my $path (sort @paths) {
    my $normalized = $path;
    $normalized =~ tr{\\}{/};
    next if $normalized =~ m{/stdlib/core_macros\.tl\z};
    $source_path = $path;

    open my $input, '<:encoding(UTF-8)', $path
        or die "$path: cannot read: $!\n";
    local $/;
    my $text = <$input>;
    close $input or die "$path: cannot close after reading: $!\n";
    $text = '' if !defined $text;

    my ($rewritten, $count) = rewrite_source($text);
    next if !$count;
    open my $output, '>:encoding(UTF-8)', $path
        or die "$path: cannot write: $!\n";
    print {$output} $rewritten
        or die "$path: cannot write: $!\n";
    close $output or die "$path: cannot close after writing: $!\n";
    $total += $count;
}

print "private place seed bridge rewrote $total call(s)\n";
if (!$total) {
    warn "private place seed bridge found no calls\n";
    exit 1;
}
PERL
