package CPAN6::Packages;

use IO::Uncompress::Gunzip qw($GunzipError);
use JSON::XS ();
use parent 'Parse::CPAN::Packages::Fast';
use strict;
use warnings;

sub new {
    my ( $class, $dir, ) = @_;

    my $obj = {
        _p6dists => "$dir/p6dists.json.gz",
        _p6provides => "$dir/p6provides.json.gz",
    };

    for ( values %{ $obj } ) {
        my $buffer;
        IO::Uncompress::Gunzip::gunzip $_ => \$buffer
          or die "gunzip failed: $GunzipError\n";
        $_ = JSON::XS::decode_json( $buffer );
    }

    for my $pkg_name ( keys %{ $obj->{_p6provides} } ) {
        for my $dist_path ( @{ $obj->{_p6provides}->{$pkg_name} } ) {
            my $dist_info = $obj->{_p6dists}->{$dist_path};
            $obj->{pkg_ver}->{$pkg_name} = $dist_info->{ver} =~ s/^v//r;
            $obj->{pkg_to_dist}->{$pkg_name} = $dist_path;
            push( @{ $obj->{dist_to_pkgs}->{$dist_path} }, $pkg_name );
        }
    }

    return bless( $obj, $class );
}

1;
