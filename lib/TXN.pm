use v6;
use Config::TOML;
use File::Presence;
use TXN::Parser;
use TXN::Parser::Types;
use TXN::Remarshal;
unit module TXN;

constant $PROGRAM = 'mktxn';
constant $VERSION = v0.0.6;

# TXN::Package {{{

my class TXN::Package
{
    # --- attributes {{{

    # e.g. "mktxn v0.0.2 2016-05-10T10:22:44.054586-07:00"
    has Str $!compiler is required;

    # accounting ledger AST
    has TXN::Parser::AST::Entry @!entry is required;

    # number of entries in @!entry
    has UInt $!count is required;

    # entities seen in @!entry
    has VarName @!entities-seen is required;

    # package info
    has Str $!pkgname is required;
    has Version $!pkgver is required;
    has UInt $!pkgrel is required;
    has Str $!pkgdesc;

    # --- end attributes }}}

    # --- submethod BUILD {{{

    submethod BUILD(
        Str :$!compiler!,
        TXN::Parser::AST::Entry :@!entry!,
        UInt :$!count!,
        # XXX C<@entities-seen> param is typed Str to make compiler happy
        Str :@!entities-seen!,
        Str :$!pkgname!,
        Version :$!pkgver!,
        UInt :$!pkgrel!,
        Str :$pkgdesc
    )
    {
        $!pkgdesc = $pkgdesc if $pkgdesc;
    }

    # --- end submethod BUILD }}}
    # --- method new {{{

    method new(
        # whether C<$cf> is content of a file, or is a file path
        #
        # if file path, we pass as arg C<:file> to C<from-txn> to get
        # proper include directive handling
        Str $content-or-file where /CONTENT|FILE/,

        # the content of a file, or file path
        Str $cf,

        # whether to print console progress messages
        Bool :$verbose = False,

        *%opts (
            Str :pkgname($),
            Str :pkgver($),
            UInt :pkgrel($),
            Str :pkgdesc($),
            Int :date-local-offset($),
            Str :txn-dir($),
            Str :template($)
        )
    )
    {
        my %bless;

        my %prepare = prepare(|%opts);

        my Str $pkgname = %prepare<pkgname>;
        my Version $pkgver .= new(%prepare<pkgver>);
        my UInt $pkgrel = %prepare<pkgrel>;
        my Str $pkgdesc = %prepare<pkgdesc> if %prepare<pkgdesc>;

        my DateTime $dt = now.DateTime;

        say "Making txn pkg: $pkgname $pkgver-$pkgrel ($dt)" if $verbose;

        my Str $compiler = "$PROGRAM v$VERSION $dt";

        # parse the accounting ledger
        my %h;
        %h<date-local-offset> =
            %prepare<date-local-offset> if %prepare<date-local-offset>;
        %h<txn-dir> = %prepare<txn-dir> if %prepare<txn-dir>;
        my TXN::Parser::AST::Entry @entry = do given $content-or-file
        {
            when 'CONTENT' { from-txn($cf, |%h) }
            when 'FILE' { from-txn(:file($cf), |%h) }
        }

        # compute basic stats about the accounting ledger
        my UInt $count = @entry.elems;
        my VarName @entities-seen = get-entities-seen(@entry);

        %bless<compiler> = $compiler;
        %bless<entry> = @entry;
        %bless<count> = $count;
        %bless<entities-seen> = @entities-seen;
        %bless<pkgname> = $pkgname;
        %bless<pkgver> = $pkgver;
        %bless<pkgrel> = $pkgrel;
        %bless<pkgdesc> = $pkgdesc if $pkgdesc;

        self.bless(|%bless);
    }

    # --- end method new }}}

    # --- method hash {{{

    method hash(::?CLASS:D:) returns Hash
    {
        %(
            :@!entry,
            :txn-info(%(
                :$!compiler,
                :$!count,
                :@!entities-seen,
                :$!pkgdesc,
                :$!pkgname,
                :$!pkgrel,
                :$!pkgver
            ))
        );
    }

    # --- end method hash }}}

    # --- sub get-entities-seen {{{

    sub get-entities-seen(TXN::Parser::AST::Entry @entry) returns Array
    {
        my VarName @entities-seen = @entry.flatmap({
            .posting.map({ .account.entity })
        });
        @entities-seen .= unique;
        @entities-seen .= sort;
    }

    # --- end sub get-entities-seen }}}
    # --- sub has-pkgname-pkgver-pkgrel {{{

    sub pkgname-pkgver-pkgrel(%txn-info) returns Array[Bool]
    {
        my Bool @p =
            %txn-info<pkgname>:exists,
            %txn-info<pkgver>:exists,
            %txn-info<pkgrel>:exists;
    }

    sub has-pkgname-pkgver-pkgrel(%txn-info) returns Bool
    {
        given pkgname-pkgver-pkgrel(%txn-info)
        {
            when .grep(*.so).elems == .elems
            {
                True;
            }
            default
            {
                my Str $message = 'Sorry, ';
                my Str @missing;
                push @missing, 'pkgname' if $_[0].not;
                push @missing, 'pkgver' if $_[1].not;
                push @missing, 'pkgrel' if $_[2].not;
                $message ~= @missing.join(', ');
                $message ~= ' missing from %txn-info. Got:' ~ "\n";
                $message ~= %txn-info.perl;
                die $message;
            }
        }
    }

    # --- end sub has-pkgname-pkgver-pkgrel }}}
    # --- sub prepare {{{

    # merge build settings from TOML template if one is provided
    sub prepare(
        Str :$pkgname,
        Str :$pkgver,
        UInt :$pkgrel,
        Str :$pkgdesc,
        Int :$date-local-offset,
        Str :$txn-dir,
        Str :$template
    )
    {
        my %prepare;

        if $template
        {
            my %h;
            %h<date-local-offset> = $date-local-offset if $date-local-offset;
            my %template = from-toml(:file($template), |%h);

            %prepare<pkgname> = %template<pkgname> if %template<pkgname>;
            %prepare<pkgver> = %template<pkgver> if %template<pkgver>;
            %prepare<pkgrel> = Int(%template<pkgrel>) if %template<pkgrel>;
            %prepare<pkgdesc> = %template<pkgdesc> if %template<pkgdesc>;
            if %template<txn-dir>
            {
                %prepare<txn-dir> = %template<txn-dir>.IO.is-relative
                    # resolve txn-dir path relative to template file
                    ??
                        ~join(
                            '/',
                            $template.IO.dirname,
                            %template<txn-dir>
                        ).IO.resolve
                    # absolute txn-dir path given, use it directly
                    !! %template<txn-dir>;
            }
            %prepare<date-local-offset> = Int(%template<date-local-offset>)
                if %template<date-local-offset>;
        }

        # overwrite template options if conflicts arise
        %prepare<pkgname> = $pkgname if $pkgname;
        %prepare<pkgver> = $pkgver if $pkgver;
        %prepare<pkgrel> = $pkgrel if $pkgrel;
        %prepare<pkgdesc> = $pkgdesc if $pkgdesc;
        %prepare<date-local-offset> = $date-local-offset if $date-local-offset;
        %prepare<txn-dir> = ~$txn-dir.IO.resolve if $txn-dir;

        # check for existence of pkgname, pkgver, and pkgrel
        die unless has-pkgname-pkgver-pkgrel(%prepare);

        %prepare;
    }

    # --- end sub prepare }}}
}

# end TXN::Package }}}

# sub mktxn {{{

multi sub mktxn(
    Str :$file!,
    Bool :$release! where *.so,
    *%opts (
        Str :$pkgname,
        Str :$pkgver,
        UInt :$pkgrel,
        Str :$pkgdesc,
        Str :$txn-dir,
        Int :$date-local-offset,
        Str :$template
    )
) is export
{
    my Str $f = resolve-txn-file-path($file);
    my %txn-package = TXN::Package.new('FILE', $f, :verbose, |%opts).hash;
    package(%txn-package);
}

multi sub mktxn(
    Str $content,
    Bool :$release! where *.so,
    *%opts (
        Str :$pkgname,
        Str :$pkgver,
        UInt :$pkgrel,
        Str :$pkgdesc,
        Str :$txn-dir,
        Int :$date-local-offset,
        Str :$template
    )
) is export
{
    my %txn-package =
        TXN::Package.new('CONTENT', $content, :verbose, |%opts).hash;
    package(%txn-package);
}

multi sub mktxn(
    Str :$file!,
    *%opts (
        Str :$pkgname,
        Str :$pkgver,
        UInt :$pkgrel,
        Str :$pkgdesc,
        Str :$txn-dir,
        Int :$date-local-offset,
        Str :$template
    )
) is export returns Hash
{
    TXN::Package.new('FILE', $file, |%opts).hash;
}

multi sub mktxn(
    Str $content,
    *%opts (
        Str :$pkgname,
        Str :$pkgver,
        UInt :$pkgrel,
        Str :$pkgdesc,
        Str :$txn-dir,
        Int :$date-local-offset,
        Str :$template
    )
) is export returns Hash
{
    TXN::Package.new('CONTENT', $content, |%opts).hash;
}

# end sub mktxn }}}
# sub package {{{

# serialize to JSON files on disk
sub package(%txn-package (TXN::Parser::AST::Entry :@entry!, :%txn-info!))
{
    say "Creating txn pkg \"%txn-info<pkgname>\"…";

    # make build directory
    my Str $build-dir = $*CWD ~ '/build';
    my Str $txn-info-file = "$build-dir/.TXNINFO";
    my Str $txn-json-file = "$build-dir/txn.json";
    mkdir $build-dir;

    # serialize .TXNINFO to JSON
    spurt $txn-info-file, Rakudo::Internals::JSON.to-json(%txn-info) ~ "\n";

    # serialize ledger AST to JSON
    spurt $txn-json-file, Rakudo::Internals::JSON.to-json(@entry».hash) ~ "\n";

    # compress
    my Str $tarball =
        "%txn-info<pkgname>-%txn-info<pkgver>-%txn-info<pkgrel>\.txn.tar.xz";
    shell "tar \\
             -C $build-dir \\
             --xz \\
             -cvf $tarball \\
             {$txn-info-file.IO.basename} {$txn-json-file.IO.basename}";

    my Str $dt = %txn-info<compiler>.split(' ')[*-1];
    say "Finished making: %txn-info<pkgname> ",
        "%txn-info<pkgver>-%txn-info<pkgrel> ($dt)";

    # clean up build directory
    say "Cleaning up…";
    dir($build-dir)».unlink;
    rmdir $build-dir;
}

# end sub package }}}
# sub resolve-txn-file-path {{{

multi sub resolve-txn-file-path(
    Str $file where *.IO.extension eq 'txn'
) returns Str
{
    die unless exists-readable-file($file);
    $file;
}

multi sub resolve-txn-file-path(Str $file) returns Str
{
    die unless exists-readable-file("$file.txn");
    "$file.txn";
}

# end sub resolve-txn-file-path }}}

# vim: set filetype=perl6 foldmethod=marker foldlevel=0:
