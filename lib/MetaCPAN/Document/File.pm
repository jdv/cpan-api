package MetaCPAN::Document::File;

use strict;
use warnings;
use utf8;

use Moose;
use ElasticSearchX::Model::Document;

use Encode;
use List::AllUtils qw( any );
use List::MoreUtils qw(any uniq);
use MetaCPAN::Document::Module;
use MetaCPAN::Types qw(:all);
use MetaCPAN::Util;
use MooseX::Types::Moose qw(ArrayRef);
use Plack::MIME;
use Pod::Text;
use Try::Tiny;
use URI::Escape ();

Plack::MIME->add_type( ".t"   => "text/x-script.perl" );
Plack::MIME->add_type( ".pod" => "text/x-pod" );
Plack::MIME->add_type( ".xs"  => "text/x-c" );

my @NOT_PERL_FILES = qw(SIGNATURE);

=head1 PROPERTIES

=head2 abstract

Abstract of the documentation (if any). This is built by parsing the
C<NAME> section. It also sets L</documentation> if it succeeds.

=cut

has abstract => (
    is         => 'ro',
    required   => 1,
    lazy_build => 1,
    index      => 'analyzed',
);

sub _build_abstract {
    my $self = shift;
    return undef unless ( $self->is_perl_file );
    my $text = ${ $self->content };
    my ( $documentation, $abstract );
    my $section = MetaCPAN::Util::extract_section( $text, 'NAME' );

    # if it's a POD file without a name section, let's try to generate
    # an abstract and name based on filename
    if ( !$section && $self->path =~ /\.pod$/ ) {
        $section = $self->path;
        $section =~ s{^(lib|pod|docs)/}{};
        $section =~ s{\.pod$}{};
        $section =~ s{/}{::}g;
    }

    return undef unless ($section);
    $section =~ s/^=\w+.*$//mg;
    $section =~ s/X<.*?>//mg;

    if ( $section =~ /^\s*(\S+)((\h+-+\h+(.+))|(\r?\n\h*\r?\n\h*(.+)))?/ms ) {
        chomp( $abstract = $4 || $6 ) if ( $4 || $6 );
        my $name = MetaCPAN::Util::strip_pod($1);
        $documentation = $name if ( $name =~ /^[\w\.:\-_']+$/ );
    }
    if ($abstract) {
        $abstract =~ s/^=\w+.*$//xms;
        $abstract =~ s{\r?\n\h*\r?\n\h*.*$}{}xms;
        $abstract =~ s{\n}{ }gxms;
        $abstract =~ s{\s+$}{}gxms;
        $abstract =~ s{(\s)+}{$1}gxms;
        $abstract = MetaCPAN::Util::strip_pod($abstract);
    }
    if ($documentation) {
        $self->documentation( MetaCPAN::Util::strip_pod($documentation) );
    }
    return $abstract;
}

=head2 id

Unique identifier of the release.
Consists of the L</author>'s pauseid, the release L</name>,
and the file path.
See L<ElasticSearchX::Model::Util/digest>.

=cut

has id => (
    is => 'ro',
    id => [qw(author release path)],
);

=head2 module

An ArrayRef of L<MetaCPAN::Document::Module> objects, that represent
modules defined in that class (i.e. package declarations).

=cut

has module => (
    required        => 0,
    is              => 'rw',
    isa             => Module,
    type            => 'nested',
    include_in_root => 1,
    coerce          => 1,
    clearer         => 'clear_module',
    lazy            => 1,
    default         => sub { [] },
);

=head2 date

B<Required>

Release date (i.e. C<mtime> of the archive file).

=cut

has date => (
    is       => 'ro',
    required => 1,
    isa      => 'DateTime',
);

=head2 description

Contains the C<DESCRIPTION> section of the POD if any. Will be stripped from
whitespaces and POD commands.

=cut

has description => (
    is         => 'ro',
    required   => 1,
    lazy_build => 1,
    index      => 'analyzed',
);

sub _build_description {
    my $self = shift;
    return undef unless ( $self->is_perl_file );
    my $section = MetaCPAN::Util::extract_section( ${ $self->content },
        'DESCRIPTION' );
    return undef unless ($section);
    my $parser = Pod::Text->new;
    my $text   = "";
    $parser->output_string( \$text );

    try {
        $parser->parse_string_document("=pod\n\n$section");
    }
    catch {
        warn $_[0];
    };

    $text =~ s/\s+/ /g;
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return $text;
}

=head2 distribution

=head2 distribution.analyzed

=head2 distribution.camelcase

Name of the distribution (e.g. C<Some-Module>).

=head2 author

PAUSE ID of the author.

=head2 status

Valid values are C<latest>, C<cpan>, and C<backpan>. The most recent upload
of a distribution is tagged as C<latest> as long as it's not a developer
release, unless there are only developer releases. Everything else is
tagged C<cpan>. Once a release is deleted from PAUSE it is tagged as
C<backpan>.

=cut

has status => ( is => 'ro', required => 1, default => 'cpan' );

=head2 binary

File is binary or not.

=cut

has binary => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);

=head2 authorized

See L</set_authorized>.

=cut

has authorized => (
    required => 1,
    is       => 'rw',
    isa      => 'Bool',
    default  => 1,
);

=head2 maturity

Maturity of the release. This can either be C<released> or C<developer>.
See L<CPAN::DistnameInfo>.

=cut

has maturity => (
    is       => 'ro',
    required => 1,
    default  => 'released',
);

=head2 directory

Return true if this object represents a directory.

=cut

has directory => (
    is       => 'ro',
    required => 1,
    isa      => 'Bool',
    default  => 0,
);

=head2 documentation

Holds the name for the documentation in this file.

If the file L<is a pod file|/is_pod_file>, the name is derived from the
C<NAME> section. If the file L<is a perl file|/is_perl_file> and the
name from the C<NAME> section matches one of the modules in L</module>,
it returns the name. Otherwise it returns the name of the first module
in L</module>. If there are no modules in the file the documentation is
set to C<undef>.

=cut

has documentation => (
    required   => 1,
    is         => 'rw',
    lazy_build => 1,
    index      => 'analyzed',
    predicate  => 'has_documentation',
    analyzer   => [qw(standard camelcase lowercase)],
    clearer    => 'clear_documentation',
);

sub _build_documentation {
    my $self = shift;
    $self->_build_abstract;
    my $documentation = $self->documentation if ( $self->has_documentation );
    return undef unless ( ${ $self->pod } );
    my @indexed = grep { $_->indexed } @{ $self->module || [] };
    if ( $documentation && $self->is_pod_file ) {
        return $documentation;
    }
    elsif ( $documentation && grep { $_->name eq $documentation } @indexed ) {
        return $documentation;
    }
    elsif (@indexed) {
        return $indexed[0]->name;
    }
    elsif ( !@{ $self->module || [] } ) {
        return $documentation;
    }
    else {
        return undef;
    }
}

=head2 indexed

B<Default 0>

Indicates whether the file should be included in the search index or
not. See L</set_indexed> for a more verbose explanation.

=cut

has indexed => (
    required => 1,
    is       => 'rw',
    isa      => 'Bool',
    lazy     => 1,
    default  => sub {
        my ($self) = @_;
        return 0 if $self->is_in_other_files;
        return 0 if !$self->metadata->should_index_file( $self->path );
        return 1;
    },
);

=head2 level

Level of this file in the directory tree of the release (i.e. C<META.yml>
has a level of C<0>).

=cut

has level => (
    is         => 'ro',
    required   => 1,
    isa        => 'Int',
    lazy_build => 1,
);

sub _build_level {
    my $self = shift;
    my @level = split( /\//, $self->path );
    return @level - 1;
}

=head2 pod

Pure text format of the pod (see L</Pod::Text>). Consecutive whitespaces
are removed to save space and for better snippet previews.

=cut

has pod => (
    is           => 'ro',
    required     => 1,
    isa          => 'ScalarRef',
    lazy_build   => 1,
    index        => 'analyzed',
    not_analyzed => 0,
    store        => 'no',
    term_vector  => 'with_positions_offsets',
);

sub _build_pod {
    my $self = shift;
    return \'' unless ( $self->is_perl_file );

    if ( $ENV{METACPAN_IS_PERL6} ) {
        my $pod = q{};
        my ( $fh, $filename ) = File::Temp::tempfile(UNLINK => 1);
        print $fh ${ $self->content };
        close $fh or die $!;
        my ( $stdout, $stderr, $exit ) = Capture::Tiny::capture {
            system( 'perl6', '--doc', "$filename" );
        };
        warn "pod6 to text error (" . $self->full_path . "):  $stderr\n"
          if $stderr || $exit >> 8 != 0;
        $pod = $stdout if $stdout && $exit >> 8 == 0;

        return \$pod;
    }

    my $parser = Pod::Text->new( sentence => 0, width => 78 );

    # We don't need to index pod errors.
    $parser->no_errata_section(1);

    my $content = ${ $self->content };

    # The pod parser is very liberal and will "start" a pod document when it
    # sees /^=[a-zA-Z]/ even though it might be binary like /^=F\0?\{/.
    # So munge any lines that might match but are not usual pod directives
    # that people would use (we don't need to index non-regular pod).
    # Also see the test and comments in t/document/file.t for how
    # bizarre constructs are handled.

    $content =~ s/
        # Pod::Simple::parse_string_document() "supports \r, \n ,\r\n"...
        (?:
            \A|\r|\r\n|\n)     # beginning of line
        \K                     # (keep those characters)

        (
        =[a-zA-Z][a-zA-Z0-9]*  # looks like pod
        (?!                    # but followed by something that isn't pod:
              [a-zA-Z0-9]      # more pod chars (the star won't be greedy enough)
            | \s               # whitespace ("=head1 NAME\n", "=item\n")
            | \Z               # end of line or end of doc
        )
        )

    # Prefix (to hide from Pod parser) instead of removing.
    /\0$1/gx;

    my $text = "";
    $parser->output_string( \$text );

    try {
        $parser->parse_string_document($content);
    }
    catch {
        warn $_[0];
    };

    $text =~ s/\s+/ /g;
    $text =~ s/ \z//;

    # Remove any markers we put in the text.
    # Should we remove other non-regular bytes that may come from the source?
    $text =~ s/\0//g;

    return \$text;
}

=head2 pod_lines

ArrayRef of ArrayRefs of offset and length of pod blocks. Example:

 # Two blocks of pod, starting at line 1 and line 15 with length
 # of 10 lines each
 [[1,10], [15,10]]

=cut

has pod_lines => (
    is         => 'ro',
    required   => 1,
    isa        => 'ArrayRef',
    type       => 'integer',
    lazy_build => 1,
    index      => 'no',
);

sub _build_pod_lines {
    my $self = shift;
    return [] unless ( $self->is_perl_file );
    my ( $lines, $slop ) = MetaCPAN::Util::pod_lines( ${ $self->content } );
    $self->slop( $slop || 0 );
    return $lines;
}

=head2 sloc

Source Lines of Code. Strips empty lines, pod and C<END> section from
L</content> and returns the number of lines.

=cut

has sloc => (
    is         => 'ro',
    required   => 1,
    isa        => 'Int',
    lazy_build => 1,
);

# Metrics from Perl::Metrics2::Plugin::Core.
sub _build_sloc {
    my $self = shift;
    return 0 unless ( $self->is_perl_file );

    my @content = split( "\n", ${ $self->content } );
    my $pods = 0;

    # Use pod_lines data to remove pod content from string.
    map {
        splice( @content, $_->[0], $_->[1], map {''} 1 .. $_->[1] )
    } @{ $self->pod_lines };

    my $sloc = 0;
    while (@content) {
        my $line = shift @content;
        last if ( $line =~ /^\s*__(DATA|END)__/s );
        $sloc++ if ( $line !~ /^\s*#/ && $line =~ /\S/ );
    }
    return $sloc;
}

=head2 slop

Source Lines of Pod. Returns the number of pod lines using L</pod_lines>.

=cut

has slop => (
    is         => 'ro',
    required   => 1,
    isa        => 'Int',
    is         => 'rw',
    lazy_build => 1,
);

sub _build_slop {
    my $self = shift;
    return 0 unless ( $self->is_perl_file );
    $self->_build_pod_lines;
    return $self->slop;
}

=head2 stat

L<File::stat> info of the archive file. Contains C<mode>, C<uid>,
C<gid>, C<size> and C<mtime>.

=cut

has stat => (
    is       => 'ro',
    isa      => Stat,
    required => 0,
    dynamic  => 1,
);

=head2 version

Contains the raw version string.

=cut

has version => (
    is       => 'ro',
    required => 0,
);

=head2 version_numified

B<Required>, B<Lazy Build>

Numeric representation of L</version>. Contains 0 if there is no version or the
version could not be parsed.

=cut

has version_numified => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
    required   => 1,
);

sub _build_version_numified {
    my $self = shift;
    return 0 unless ( $self->version );
    return MetaCPAN::Util::numify_version( $self->version );
}

=head2 mime

MIME type of file. Derived using L<Plack::MIME> (for speed).

=cut

has mime => (
    is         => 'ro',
    required   => 1,
    lazy_build => 1,
);

sub _build_mime {
    my $self = shift;
    if (  !$self->directory
        && $self->name !~ /\./
        && grep { $self->name ne $_ } @NOT_PERL_FILES )
    {
        my $content = ${ $self->content };
        return "text/x-script.perl" if ( $content =~ /^#!.*?perl/ );
    }
    else {
        return Plack::MIME->mime_type( $self->name ) || 'text/plain';
    }
}

has [qw(path author name)] => ( is => 'ro', required => 1 );

sub _build_path {
    my $self = shift;
    return join( '/', $self->release->name, $self->name );
}

has [qw(release distribution)] => (
    is       => 'ro',
    required => 1,
    analyzer => [qw(standard camelcase lowercase)],
);

=head1 ATTRIBUTES

These attributes are not stored.

=head2 content

A scalar reference to the content of the file.
Built by calling L</content_cb>.

=cut

has content => (
    is         => 'ro',
    isa        => 'ScalarRef',
    lazy_build => 1,
    property   => 0,
    required   => 0,
);

sub _build_content {
    my $self = shift;

    # NOTE: We used to remove the __DATA__ section "for performance reasons"
    # however removing lines from the content will throw off pod_lines.
    return $self->content_cb->();
}

=head2 content_cb

Callback that returns the content of the file as a ScalarRef.

=cut

has content_cb => (
    is       => 'ro',
    property => 0,
    required => 0,
    default  => sub {
        sub { \'' }
    },
);

=head2 local_path

This attribute holds the path to the file on the local filesystem.

=cut

has local_path => (
    is       => 'ro',
    property => 0,
);

=head2 metadata

Reference to the L<CPAN::Meta> object of the release.

=cut

has metadata => (
    is       => "ro",
    lazy     => 1,
    default  => sub { die "meta attribute missing" },
    isa      => "CPAN::Meta",
    property => 0,
);

=head1 METHODS

=head2 is_perl_file

Return true if the file extension is one of C<pl>, C<pm>, C<pod>, C<t>
or if the file has no extension, is not a binary file and its size is less
than 131072 bytes. This is an arbitrary limit but it keeps the pod parser
happy and the indexer fast.

=cut

sub is_perl_file {
    my $self = shift;
    return 0 if ( $self->directory );
    return 1 if ( $self->name =~ /\.(pl|pm|pod|t)$/i );
    return 1 if $ENV{METACPAN_IS_PERL6}
      && ( $self->name =~ /\.(pl|pm|pod|t)6?$/i );
    return 1 if ( $self->mime eq "text/x-script.perl" );
    return 1
        if ( $self->name !~ /\./
        && !( grep { $self->name eq $_ } @NOT_PERL_FILES )
        && !$self->binary
        && $self->stat->{size} < 2**17 );
    return 0;
}

=head2 is_pod_file

Returns true if the file extension is C<pod>.

=cut

sub is_pod_file {
    shift->name =~ /\.pod$/i;
}

=head2 add_module

Requires at least one parameter which can be either a HashRef or
an instance of L<MetaCPAN::Document::Module>.

=cut

sub add_module {
    my ( $self, @modules ) = @_;
    $_ = MetaCPAN::Document::Module->new($_)
        for ( grep { ref $_ eq 'HASH' } @modules );
    $self->module( [ @{ $self->module }, @modules ] );
}

=head2 is_in_other_files

Returns true if the file is one from the list below.

=cut

sub is_in_other_files {
    my $self  = shift;
    my @other = qw(
        AUTHORS
        Build.PL
        Changelog
        ChangeLog
        CHANGELOG
        Changes
        CHANGES
        CONTRIBUTING
        CONTRIBUTING.md
        CONTRIBUTING.pod
        Copying
        COPYRIGHT
        cpanfile
        CREDITS
        dist.ini
        FAQ
        INSTALL
        INSTALL.md
        INSTALL.pod
        LICENSE
        Makefile.PL
        MANIFEST
        META.json
        META.yml
        META6.json
        NEWS
        README
        README.md
        README.pod
        THANKS
        Todo
        ToDo
        TODO
    );

    return any { $self->path eq $_ } @other;
}

=head2 set_indexed

Expects a C<$meta> parameter which is an instance of L<CPAN::Meta>.

For each package (L</module>) in the file and based on L<CPAN::Meta/should_index_package>
it is decided, whether the module should have a true L</indexed> attribute.
If there are any packages with leading underscores, the module gets a false 
L</indexed> attribute, because PAUSE doesn't allow this kind of name for packages
(https://github.com/andk/pause/blob/master/lib/PAUSE/pmfile.pm#L249).

If L<CPAN::Meta/should_index_package> returns true but the package declaration
uses the I<hide from PAUSE> hack, the L</indexed> property is set to false.

 package # hide from PAUSE
   MyTest::Module;
 # will result in indexed => 0

Once that is done, the L</indexed> property of the file is determined by searching
the list of L<modules|/module> for a module that matches the value of L</documentation>.
If there is no such module, the L</indexed> property is set to false. If the file
does not include any modules, the L</indexed> property is true.

=cut

sub set_indexed {
    my ( $self, $meta ) = @_;

    #files listed under 'other files' are not shown in a search
    if ( $self->is_in_other_files() ) {
        foreach my $mod ( @{ $self->module } ) {
            $mod->indexed(0);
        }
        $self->indexed(0);
        return;
    }

    foreach my $mod ( @{ $self->module } ) {
        if ( $mod->name !~ /^[A-Za-z]/ ) {
            $mod->indexed(0);
            next;
        }
        $mod->indexed(
              $meta->should_index_package( $mod->name )
            ? $mod->hide_from_pause( ${ $self->content }, $self->name )
                    ? 0
                    : 1
            : 0
        ) unless ( $mod->indexed );
    }
    $self->indexed(

        # .pm file with no package declaration but pod should be indexed
        !@{ $self->module } ||

           # don't index if the documentation doesn't match any of its modules
            !!grep { $self->documentation eq $_->name } @{ $self->module }
    ) if ( $self->documentation );
}

=head2 set_authorized

Expects a C<$perms> parameter which is a HashRef. The key is the module name
and the value an ArrayRef of author names who are allowed to release
that module.

The method returns a list of unauthorized, but indexed modules.

Unauthorized modules are modules that were uploaded in the name of a
different author than stated in the C<06perms.txt.gz> file. One problem
with this file is, that it doesn't record historical data. It may very
well be that an author was authorized to upload a module at the time.
But then his co-maintainer rights might have been revoked, making consecutive
uploads of that release unauthorized. However, since this script runs
with the latest version of C<06perms.txt.gz>, the former upload will
be flagged as unauthorized as well. Same holds the other way round,
a previously unauthorized release would be flagged authorized if the
co-maintainership was added later on.

If a release contains unauthorized modules, the whole release is marked
as unauthorized as well.

=cut

sub set_authorized {
    my ( $self, $perms ) = @_;

    # only authorized perl distributions make it into the CPAN
    return () if ( $self->distribution eq 'perl' );
    foreach my $module ( @{ $self->module } ) {
        $module->authorized(0)
            if ( $perms->{ $module->name } && !grep { $_ eq $self->author }
            @{ $perms->{ $module->name } } );
    }
    $self->authorized(0)
        if ( $self->authorized
        && $self->documentation
        && $perms->{ $self->documentation }
        && !grep { $_ eq $self->author }
        @{ $perms->{ $self->documentation } } );
    return grep { !$_->authorized && $_->indexed } @{ $self->module };
}

=head2 full_path

Concatenate L</author>, L</release> and L</path>.

=cut

sub full_path {
    my $self = shift;
    return join( "/", $self->author, $self->release, $self->path );
}

__PACKAGE__->meta->make_immutable;

package MetaCPAN::Document::File::Set;
use Moose;
extends 'ElasticSearchX::Model::Document::Set';

my @ROGUE_DISTRIBUTIONS
    = qw(kurila perl_debug perl-5.005_02+apache1.3.3+modperl pod2texi perlbench spodcxx Bundle-Everything);

sub find {
    my ( $self, $module ) = @_;
    my @candidates = $self->index->type("file")->filter(
        {
            and => [
                {
                    or => [
                        { term => { 'file.module.name'   => $module } },
                        { term => { 'file.documentation' => $module } },
                    ]
                },
                { term => { 'file.indexed' => \1, } },
                { term => { status         => 'latest', } },
                {
                    not =>
                        { filter => { term => { 'file.authorized' => \0 } } }
                },
            ]
        }
        )->sort(
        [
            { 'date' => { order => "desc" } },
            'mime',
            { 'stat.mtime' => { order => 'desc' } }
        ]
        )->size(100)->all;

    my ($file) = grep {
        grep { $_->indexed && $_->authorized && $_->name eq $module }
            @{ $_->module || [] }
        } grep { !$_->documentation || $_->documentation eq $module }
        @candidates;

    $file ||= shift @candidates;
    return $file ? $self->get( $file->id ) : undef;
}

sub find_pod {
    my ( $self, $name ) = @_;
    my $file = $self->find($name);
    return $file unless ($file);
    my ($module)
        = grep { $_->indexed && $_->authorized && $_->name eq $name }
        @{ $file->module || [] };
    if ( $module && ( my $pod = $module->associated_pod ) ) {
        my ( $author, $release, @path ) = split( /\//, $pod );
        return $self->get(
            {
                author  => $author,
                release => $release,
                path    => join( "/", @path ),
            }
        );
    }
    else {
        return $file;
    }
}

# return files that contain modules that match the given dist
# NOTE: these still need to be filtered by authorized/indexed
# TODO: test that we are getting the correct version (latest)
sub find_provided_by {
    my ( $self, $release ) = @_;
    return $self->filter(
        {
            and => [
                { term => { 'release' => $release->{name} } },
                { term => { 'author'  => $release->{author} } },
                { term => { 'file.module.authorized' => 1 } },
                { term => { 'file.module.indexed'    => 1 } },
            ]
        }
    )->size(999)->all;
}

# filter find_provided_by results for indexed/authorized modules
# and return a list of package names
sub find_module_names_provided_by {
    my ( $self, $release ) = @_;
    my $mods = $self->inflate(0)->find_provided_by($release);
    return (
        map { $_->{name} }
        grep { $_->{indexed} && $_->{authorized} }
        map { @{ $_->{_source}->{module} } } @{ $mods->{hits}->{hits} }
    );
}

# TODO: figure out what uses this and write tests for it
sub prefix {
    my ( $self, $prefix ) = @_;
    my @query = split( /\s+/, $prefix );
    my $should = [
        map {
            { field     => { 'documentation.analyzed'  => "$_*" } },
                { field => { 'documentation.camelcase' => "$_*" } }
        } grep {$_} @query
    ];
    return $self->query(
        {
            filtered => {
                query => {
                    custom_score => {
                        query => { bool => { should => $should } },

                        #metacpan_script => 'prefer_shorter_module_names_100',
                        script =>
                            "_score - doc['documentation'].value.length()/100"
                    },
                },
                filter => {
                    and => [
                        {
                            not => {
                                filter => {
                                    or => [
                                        map {
                                            +{
                                                term => {
                                                    'file.distribution' => $_
                                                }
                                                }
                                            } @ROGUE_DISTRIBUTIONS

                                    ]
                                }
                            }
                        },
                        { exists => { field          => 'documentation' } },
                        { term   => { 'file.indexed' => \1 } },
                        { term   => { 'file.status'  => 'latest' } },
                        {
                            not => {
                                filter =>
                                    { term => { 'file.authorized' => \0 } }
                            }
                        }
                    ]
                }
            }
        }
    );
}

=head2 history

Find the history of a given module/documentation.

=cut

sub history {
    my ( $self, $type, $module, @path ) = @_;
    my $search
        = $type eq "module" ? $self->filter(
        {
            nested => {
                path  => "module",
                query => {
                    constant_score => {
                        filter => {
                            and => [
                                { term => { "module.authorized" => \1 } },
                                { term => { "module.indexed"    => \1 } },
                                { term => { "module.name" => $module } },
                            ]
                        }
                    }
                }
            }
        }
        )
        : $type eq "file" ? $self->filter(
        {
            and => [
                { term => { "file.path"         => join( "/", @path ) } },
                { term => { "file.distribution" => $module } },
            ]
        }
        )
        : $self->filter(
        {
            and => [
                { term => { "file.documentation" => $module } },
                { term => { "file.indexed"       => \1 } },
                { term => { "file.authorized"    => \1 } },
            ]
        }
        );
    return $search->sort( [ { "file.date" => "desc" } ] );
}

sub _not_rogue {
    my @rogue_dists = map { { term => { 'file.distribution' => $_ } } }
        @ROGUE_DISTRIBUTIONS;
    return { not => { filter => { or => \@rogue_dists } } };
}

sub autocomplete {
    my ( $self, @terms ) = @_;
    my $query = join( " ", @terms );
    return $self unless $query;
    $query =~ s/::/ /g;
    my @query = split( /\s+/, $query );
    my $should = [
        map {
            { field     => { 'documentation.analyzed'  => "$_*" } },
                { field => { 'documentation.camelcase' => "$_*" } }
        } grep {$_} @query
    ];

    # TODO: custom_score is deprecated in 0.90.4 in favor of function_score.
    # As of 2013-10-27 we are still using 0.20.2 in production.
    return $self->query(
        {
            custom_score => {
                query => { bool => { should => $should } },
                script => "_score - doc['documentation'].value.length()/100",
            }
        }
        )->filter(
        {
            and => [
                $self->_not_rogue,
                { exists => { field             => 'documentation' } },
                { term   => { 'file.indexed'    => \1 } },
                { term   => { 'file.authorized' => \1 } },
                { term   => { 'file.status'     => 'latest' } },
            ]
        }
        )->sort( [ '_score', 'documentation' ] );
}

__PACKAGE__->meta->make_immutable;
1;
