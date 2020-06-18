use v6;
unit class IO::Glob:auth<github:zostay>:ver<0.9.0> does Iterable;

=NAME IO::Glob - Glob matching for paths, strings and file listings.

=begin SYNOPSIS

    use IO::Glob;

    # Need a list of files somewhere?
    for glob("src/core/*.pm") -> $file { say ~$file }

    # Or apply the glob to a chosen directory
    with glob("*.log") {
        for .dir("/var/log/error") -> $err-log { ... }
        for .dir("/var/log/access") -> $acc-log { ... }
    }

    # Use a glob to match a string or path
    if "some-string" ~~ glob("some-*") { say "match string!" }
    if "some/path.txt".IO ~~ glob("some/*.txt") { say "match path!" }

    # Use a glob as a test in built-in IO::Path.dir()
    for "/var/log".IO.dir(test => glob("*.err")) -> $err-log { ... }

    # Globs are objects, which you can save, reuse, and pass around
    my $file-match = glob("*.txt");
    my @files := dir("$*HOME/docs", :test($file-match));

    # Want to use SQL globbing with % and _ instead?
    for glob("src/core/%.pm", :sql) -> $file { ... }

    # Or want globbing without all the fancy bits?
    # :simple turns off everything but * and ?
    for glob("src/core/*.pm", :simple) -> $file { ... }

=end SYNOPSIS

=begin DESCRIPTION

Traditionally, globs provide a handy shorthand for describing the files you're
interested in based upon their path. This class provides that shorthand using a
BSD-style glob grammar that is familiar to Perl devs. However, it is more
powerful than its Perl 5 predecessor.

=item Globs are built as C<IO::Glob> objects which encapsulate the pattern. You may create them and pass them around.

=item By using them as an iterator, you can put globs to their traditional use: listing all the files in a directory.

=item Globs can also be smart-matched. It will match against strings or anything that stringifies; it will work against L<IO::Path>s too.

=item Globbing can be done with different grammars. This class ships with three: simple, BSD, and SQL.

=item B<Experimental.> You can use custom grammars for your smart match.

=end DESCRIPTION

class Globber {
    role Term { }
    class Match does Term { has $.smart-match is rw }
    class Expansion does Term { has @.alternatives }

    has @.terms where { .elems > 0 && all($_) ~~ Term };
    has @!matchers;

    method !compile-terms-ind($base, @terms is copy) {
        my $term = @terms.shift;

        my @roots;
        if $term ~~ Match {
            my $match = $term.smart-match;
            @roots = rx/$base$match/;
        }
        elsif $term ~~ Expansion {
            my @alts = $term.alternatives;
            @roots = @alts.map({ rx/$base$^alt/ });
        }
        else {
            die "unknown match term: $term";
        }

        if @terms { @roots.map({ self!compile-terms-ind($^base, @terms).Slip }) }
        else { @roots.Slip }
    }

    method is-ordered() returns Bool { any(@!terms) ~~ Expansion }

    method !compile-terms() {
        return if @!matchers;
        @!matchers = self!compile-terms-ind(rx/<?>/, @.terms).map(-> $rx {rx/^$rx$/});
    }

    multi method ACCEPTS(Str:U $) returns Bool:D { False }
    multi method ACCEPTS(Str:D $candidate) returns Bool:D {
        self!compile-terms;
        $candidate ~~ any(@!matchers);
    }

    method accepts-with-sort(*@candidates) {
        self!compile-terms;

        my @remaining = @candidates;
        my @m = gather for @!matchers.kv -> $i, $matcher {

            my @unused;
            for @candidates -> $candidate {
                if $candidate.basename ~~ $matcher {
                    take ($i, $candidate);
                }
                else {
                    push @unused, $candidate;
                }
            }

            @remaining = @unused;
        }

        @m.sort({ $^a[0] <=> $^b[0] }).map({ .[1] });
    }
}

# Unlike File::Glob in Perl 5, we don't make a bunch of options to turn off each
# kind of feature. Instead, we give callers the option to pick a grammar.
grammar Base {
    token TOP {
        <term>+
        { make $<term>».made }
    }

    token term {
        || <match>
           { make Globber::Match.new(:smart-match($<match>.made)) }
        || <expansion>
           { make Globber::Expansion.new(:alternatives($<expansion>.made)) }
        || <escape>
           { make Globber::Match.new(:smart-match($<escape>.made)) }
        || <char>
           { make Globber::Match.new(:smart-match($<char>.made)) }
    }

    proto token match {*}
    proto token expansion { * }
    proto token escape { * }
    token char { $<char> = . { make $<char>.Str } }
}

grammar SQL is Base {
    method whatever-match { '%' }

    token match:sym<%> { <sym> { make rx/.*?/ } }
    token match:sym<_> { <sym> { make rx/./ } }
}

grammar Simple is Base {
    method whatever-match { '*' }

    token match:sym<*> {
        <!after "\\"> <sym>
        { make rx/.*?/ }
    }
    token match:sym<?> {
        <!after "\\"> <sym>
        { make rx/./ }
    }

    token escape { "\\" <escape-sym> { make $<escape-sym>.Str } }

    proto token escape-sym { * }
    token escape-sym:sym<*> { <sym> }
    token escape-sym:sym<?> { <sym> }
}

grammar BSD is Simple {
    token TOP { <term>+ }

    token match:character-class {
        <!after "\\"> '['
            $<not>   = [ "!"? ]
            $<class> = [ <-[ \] ]>+ ]
        ']'

        {
            my @class = $<class>.Str.comb;
            make $<not> ?? rx{@class} !! rx{<!before @class> .}
        }
    }

    token expansion:alternatives {
        <!after "\\"> '{'
            <list=.comma-list>
        '}'

        { make my @list= ([~] $<list>).split(',') }
    }

    token comma-list {
        [ <-[ , \} ]>+ ]+ % ','
    }

    token expansion:home-dir {
        <!after "\\"> '~' $<user> = [ <-[/]>+ ]?

        { make $<user> ?? [ 'NYI' ]<> !! [ $*HOME ]<> }
    }

    token escape-sym:sym<[> { <sym> }
    token escape-sym:sym<]> { <sym> }
    token escape-sym:sym<{> { <sym> }
    token escape-sym:sym<}> { <sym> }
    token escape-sym:sym<~> { <sym> }
}

=begin pod

=head1 SUBROUTINES

=head2 sub glob

    sub glob(
        Str:D $pattern,
        Bool :$sql,
        Bool :$bsd,
        Bool :$simple,
        :$grammar,
        :$spec = $*SPEC
    ) returns IO::Glob:D

    sub glob(
        Whatever $,
        Bool :$sql,
        Bool :$bsd,
        Bool :$simple,
        :$grammar,
        :$spec = $*SPEC
    ) returns IO::Glob:D

When given a string, that string will be stored in the L<#method
pattern/pattern> attribute and will be parsed according to the L<#method
grammar/grammar>.

When given L<Whatever> (C<*>) as the argument, it's the same as:

    glob('*');

which will match anything. (Note that what whatever matches may be grammar
specific, so C<glob(*, :sql)> is the same as C<glob('%')>.)

If you want to pick from one of the built-in grammars, you may use these options:

=item C<:bsd> is the default specifying this is explicit, but unnecessary. This grammar supports C<*>, C<?>, C<[abc]>, C<[!abc]>, C<~>, and C<{ab,cd,efg}>.

=item C<:sql> uses a SQL-ish grammar that provides C<%> and C<_> matching.

=item C<:simple> is a simplified version of C<:bsd>, but only supports C<*> and C<?>.

The C<:$spec> option allows you to specify the L<IO::Spec> to use when
matching paths. It uses C<$*SPEC>, by default. The IO::Spec is used to split
paths by directory separator when matching paths. (This is ignored when matching
against other kinds of objects.)

An alternative to this is to use the optional C<:$grammar> setting lets you
select a globbing grammar object to use. These are provided:

=item IO::Glob::BSD

=item IO::Glob::SQL

=item IO::Glob::Simple

B<Experimental.> If you want a different grammar, you may create your own as
well, but no documentation of that process has been written yet as of this
writing.

=head1 METHODS

=head2 method pattern

    method pattern() returns Str:D

Returns the pattern set during construction.

=head2 method spec

    method spec() returns IO::Spec:D

Returns the spec set during construction.

=head2 method grammar

    method grammar() returns Any:D

Returns the grammar set during construction.

=end pod

has Str:D $.pattern is required;
has IO::Spec $.spec = $*SPEC;

has $.grammar = BSD.new;
has Globber $!globber;
has Globber @!globbers;
has Bool $!absolute = False;
has Str $!volume;

my sub simplify(@terms) is export(:TESTING) {
    my Globber::Match $prev;
    my @result = gather for @terms {
        when Globber::Match {
            if .smart-match ~~ Str {
                if $prev {
                    $prev.smart-match ~= .smart-match;
                }
                else {
                    $prev = $_;
                }
            }
            else {
                take $prev with $prev;
                take $_;
                $prev = Nil;
            }
        }

        default {
            take $prev with $prev;
            take $_;
            $prev = Nil;
        }
    }

    push @result, $prev if $prev;
    @result;
}

method !compile-glob() {
    $!globber = Globber.new(
        terms => simplify($!grammar.parse($!pattern)<term>.map({.made})),
    );
}

method !compile-globs() {
    ($!volume,) = $.spec.splitpath($.pattern, :nofile);
    my $delim = $.spec.dir-sep;
    my @parts = $.pattern.split(/ $delim + /);

    $!absolute = (@parts[0] eq $!volume);
    shift @parts if $!absolute;

    @!globbers = @parts.map({
        Globber.new(
            terms => simplify($!grammar.parse($^pattern)<term>.map({.made})),
        );
    });
}

method iterator(IO::Glob:D:) { self.dir.iterator }

=begin pod

=head2 method dir

    method dir(Cool $path = '.') returns Seq:D

Returns a list of files matching the glob. This will descend directories if the
pattern contains a L<IO::Spec#dir-sep> using a depth-first search. This method
is called implicitly when you use the object as an iterator. For example, these
two lines are identical:

    for glob('*.*') -> $every-dos-file { ... }
    for glob('*.*').dir -> $every-dos-file { ... }

This is the preferred method for listing files as it will be sure to respect ordering of files by alternates. For example,

    for glob("{bc,ab}*") -> $file { say $file }

This will print all files starting with "bc" before any files starting with ab.

=end pod

method dir(Str() $path = '.') returns Seq:D {
    self!compile-globs;

    my $current = $path.IO;
    return []<> unless $current.d;

    die "Using an absolute glob with a relative search origin is not permitted."
        if $!absolute and !$current.is-absolute;

    my @globbers = @!globbers;
    # Depth-first-search... commence!
    my @open-list = \(:path($current), :@globbers, :origin);
    gather while @open-list {
        my (:$path, :@globbers, :$origin) := @open-list.shift;
        if @globbers {
            my ($globber, @remaining) = @globbers;

            next unless $path ~~ :d;
            next unless $origin || $path.basename ne '..' | '.';

            my @paths = do if $globber.is-ordered {
                $globber.accepts-with-sort($path.dir);
            }
            else {
                $path.dir(test => $globber);
            }

            @open-list.prepend: @paths
                .map({ \(:$^path, :globbers(@remaining)) })
        }
        else {
            take $path;
        }
    }
}

=begin pod

=head2 method ACCEPTS

    method ACCEPTS(Mu:U $) returns Bool:D
    method ACCEPTS(Str:D(Any) $candiate) returns Bool:D
    method ACCEPTS(IO::Path:D $path) returns Bool:D

This implements smart-match. Undefined values never match. Strings are matched
using the whole pattern, without reference to any directory separators in the
string. Paths, however, are matched and carefully respect directory separators.
For most circumstances, this will not make any difference. However, a case like
this will be treated very differently in each case:

    my $glob = glob("hello{x,y/}world");
    say "String" if "helloy/world" ~~ $glob;      # outputs> String
    say "Path"   if "helloy/world".IO ~~ $glob;   # outputs nothing, no match
    say "Path 2" if "helloy{x,y/}world" ~~ $glob; # outputs> Path 2

The reason is that the second and third are matched in parts as follows:

    "helloy" ~~ glob("hello{x,y") && "world" ~~ glob("}world")
    "hello{x,y" ~~ glob("hello{x,y") && "}world" ~~ glob("}world")

=end pod

multi method ACCEPTS(Mu:U $) returns Bool:D { False }
multi method ACCEPTS(Str:D(Any) $candidate) returns Bool:D {
    self!compile-glob;
    $candidate ~~ $!globber
}

multi method ACCEPTS(IO::Path:D $path) returns Bool:D {
    self!compile-globs;
    my ($volume,) = $.spec.splitpath($path, :nofile);
    my @parts = (~$path).split($.spec.dir-sep);
    if $!absolute {
        if @parts[0] eq $volume eq $!volume {
            shift @parts;
        }
#        else {
#            return False;
#        }
    }
    elsif @parts[0] eq $volume {
        shift @parts;
    }

    return False unless @parts.elems == @!globbers.elems;
    [&&] (@parts Z @!globbers).map: -> ($p, $g) { $p ~~ $g };
}

proto glob(|) is export { * }

multi sub glob(
    Str:D $pattern,
    Bool :$sql,
    Bool :$bsd,
    Bool :$simple,
    :grammar($g),
    :$spec = $*SPEC
) returns IO::Glob:D {
    my $grammar = do with $g { $g } elsif $sql { SQL.new } elsif $simple { Simple.new } else { BSD.new };
    IO::Glob.new(:$pattern, :$grammar, :$spec);
}

multi sub glob(
    Whatever $,
    Bool :$sql,
    Bool :$bsd,
    Bool :$simple,
    :grammar($g),
    :$spec = $*SPEC
) returns IO::Glob:D {
    my $grammar = do with $g { $g } elsif $sql { SQL.new } elsif $simple { Simple.new } else { BSD.new };
    IO::Glob.new(:pattern($grammar.whatever-match), :$grammar, :$spec);
}
