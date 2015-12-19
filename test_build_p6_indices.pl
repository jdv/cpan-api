use strict;
use warnings;
use JSON::XS;
use Data::Dumper;

$|++;

my $authors_dir = glob( '/home/jdv/CPAN/authors/id/' );
my $data = {
    p6dists => {},
    p6provides => {},
};

for ( glob( $authors_dir . '*/*/*/Perl6/*gz' ) ) {
    next if /-Elo-|CheckSocket-|Data-Selector-1.00|File-Temp|JSON-Faster|Linenoise/;

    my $dist_name = $_ =~ s/$authors_dir//r;
    my $meta = eval {decode_json(
        `tar --to-stdout --wildcards -xzvf "$_" '*/META6.json' 2> /dev/null`
    )};
    if ( my $e = $@ ) {
        warn "meta decode failure($_):  $e";
        next;
    }
    $data->{p6dists}->{$dist_name} = {
        name => $meta->{name},
        auth => (split( /\//, $dist_name ))[2],
        ver => $meta->{version},
    };
    push( @{ $data->{p6provides}->{$_} }, $dist_name )
      for keys %{ $meta->{provides} };
}

my $indices_dir = $authors_dir =~ s/id\/$//r;
for ( qw( p6dists p6provides ) ) {
    unlink "$indices_dir$_.json.gz" or die $!;
    open( my $fh, '>', "$indices_dir$_.json" ) or die $!;
    print $fh JSON::XS->new->utf8->pretty->canonical->encode($data->{$_});
    close $fh or die $!;
    `gzip $indices_dir$_.json`;
}
