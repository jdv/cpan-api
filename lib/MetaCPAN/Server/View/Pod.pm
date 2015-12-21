package MetaCPAN::Server::View::Pod;

use strict;
use warnings;

use Capture::Tiny ();
use File::Temp    ();
use MetaCPAN::Pod::Renderer;
use Moose;

extends 'Catalyst::View';

sub process {
    my ( $self, $c ) = @_;

    my $renderer = MetaCPAN::Pod::Renderer->new;

    my $content = $c->res->body || $c->stash->{source};
    my $link_mappings = $c->stash->{link_mappings};
    $content = eval { join( q{}, $content->getlines ) };

    my ( $body, $content_type );
    my $accept = eval { $c->req->preferred_content_type } || 'text/html';
    my $show_errors = $c->req->params->{show_errors};

    my $x_codes = $c->req->params->{x_codes};
    $x_codes = $c->config->{pod_html_x_codes} unless defined $x_codes;

    if ( $accept eq 'text/plain' ) {
        $body         = $self->_factory->to_text($content);
        $content_type = 'text/plain';
    }
    elsif ( $accept eq 'text/x-pod' ) {
        $body         = $self->_factory->to_pod($content);
        $content_type = 'text/plain';
    }
    elsif ( $accept eq 'text/x-markdown' ) {
        $body         = $self->_factory->to_markdown($content);
        $content_type = 'text/plain';
    }
    else {
        $body = $self->build_pod_html( $content, $show_errors, $x_codes,
            $link_mappings, $c );
        $content_type = 'text/html';
    }

    $c->res->content_type($content_type);
    $c->res->body($body);
}

sub build_pod_html {
    my ( $self, $source, $show_errors, $x_codes, $link_mappings, $c ) = @_;

    if ( $ENV{METACPAN_IS_PERL6} ) {
        my $path = Path::Class::File->new(
            do { my @d = $c->stash->{path}->dir->dir_list;
              $d[2] = 'html_doc'; @d; },
            $c->stash->{path}->basename,
        );
        $path->dir->mkpath unless $path->dir->stat;
        my $html = q{};
        unless ( $path->stat && ( $html = $path->slurp ) ) {
            my ( $fh, $filename ) = File::Temp::tempfile(UNLINK => 1);
            print $fh $source;
            close $fh or die $!;
            my ( $stdout, $stderr, $exit ) = Capture::Tiny::capture {
                system( 'perl6', '--doc=HTML', "$filename" );
            };
            die "pod6 to html error:  $stderr"
            if $stderr || $exit >> 8 != 0;
            $html = $stdout if $stdout && $exit >> 8 == 0;
            $html =~ s/\#___top/\#___pod/g;

            # TODO: why is this needed?
            $html = ' ' unless $html;
            $path->spew($html);
        }

        return $html;
    }

    my $renderer = $self->_factory->html_renderer;
    $renderer->nix_X_codes( !$x_codes );
    $renderer->no_errata_section( !$show_errors );
    $renderer->link_mappings($link_mappings);

    my $html = q{};
    $renderer->output_string( \$html );
    $renderer->parse_string_document($source);
    return $html;
}

sub _factory {
    my $self = shift;
    return MetaCPAN::Pod::Renderer->new;
}

1;
