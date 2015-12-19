use strict;
use warnings;
use LWP::UserAgent;
use JSON::XS;
use Data::Dumper;
use File::Copy;
use File::Slurp;
use File::Path;

$|++;

my $repo_dir = '/home/jdv/eco_repos';
my $dist_dir = '/home/jdv/cpan6_dists/authors/id';

sub get_eco_repo_list {
    my $resp
      = LWP::UserAgent->new->get('http://ecosystem-api.p6c.org/projects.json');
    if ($resp->is_success) {
        return map {
            #TODO: this may need help for META6.json
            my $uri = $_->{'source-url'} || $_->{'support'}->{'source'};
	    $uri =~ s/\/$/.git/ if $uri =~ /^https/;
            $uri ? $uri : die "URI:" . Dumper($_);
        } grep {
            $_->{'name'} !~ /^(Tardis)$/;
        } @{ decode_json($resp->decoded_content) };
    }
    else { die $resp->status_line; }
}

my @repos = get_eco_repo_list;
my %repos;
for (@repos) { die "DUP REPO:  $_\n" if $repos{$_}++; }

for (@repos) {
    chdir $repo_dir or die;
    my ($base) = $_ =~ /([^\/]+)\.git$/;
    print "REPO:($_,$base)\n";


    if ( -e $base ) {
    	chdir $base or die;
        open(my $up, "git pull --rebase --stat |") or die;
        while (<$up>) { print; }
        close $up or die;
    	chdir '..' or die;
    }
    else {
        open(my $clone, "git clone $_ |") or die;
        while (<$clone>) { print; }
        close $clone or die;
    }

    # TODO
    next if $base =~ /^(lolsql|io-prompt)$/;

    print "NO META.info\n" unless -e 'META.info';

    chdir $base or die;

    print "UNCOMMIT:".`git reset --hard HEAD~1`.":UNCOMMIT\n"
      if `git log HEAD~1.. --oneline` =~ /WIP - add META6.json/;

    my $meta;
    print "CLEAN:".`git clean -dfx`.":CLEAN";
    unlink 'META6.json' if -l 'META6.json';
    unless ( -e 'META6.json' ) {
        copy("META.info", "META6.json") or die "Copy failed: $!";
    }

    	$meta = decode_json(read_file('META6.json'));

	die "NO NAME" unless $meta->{name};
	if ( $meta->{version} eq '*' || ! exists $meta->{version} ) {
		$meta->{version} = 'v1.2.3.4.5';
	}
	elsif ( $meta->{version} =~ /(\d+(?:.\d+)*)/ ) {
		$meta->{version} = 'v' . $1;
	}
	else {
		die "version ($meta->{version}) unhandled";
	}
	write_file(
        'META6.json',
        JSON::XS->new->utf8->pretty(1)->canonical(1)->encode($meta)
    );

	print "ADD:".`git add META6.json`.":ADD";
	print "COMMIT:".`git commit -m 'WIP - add META6.json'`.":COMMIT";

    # TODO: determine pause id or default to JDV
    # TODO: lost some repos in the dists...
    my $tar_base = $meta->{name} =~ s/::/-/gr . '-'
      . $meta->{version} =~ s/^v//r;
    my $tar_file = "$dist_dir/J/JD/JDV/Perl6/$tar_base.tar.gz";
    my $tar_dir = $tar_file =~ s/[^\/]+$//r;
    File::Path::make_path($tar_dir);
    unless ( 0){#-e $tar_file ) {
        #chdir '..' or die;
	my $cmd = 'git archive --format=tar --prefix='
          . "\"$tar_base/\" HEAD | gzip > \"$tar_file\" |";
       open(my $archive, $cmd) or die;
       while (<$archive>) { print; }
       close $archive or die;
        #open(my $tar, "tar czvf $tar_file $base --exclude-vcs 1>/dev/null |")
        #  or die;
        #while (<$tar>) { print; }
        #close $tar or die;
    }
    print "\n";
}
