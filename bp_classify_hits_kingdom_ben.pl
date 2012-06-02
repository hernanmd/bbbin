#!/usr/bin/perl 

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

=head1 NAME

classify_hits_kingdom - classify BLAST hits by taxonomic kingdom

=head2 USAGE

classify_hits_kingdom [-i tab_file] [-i second_BLAST_file] [-e evalue_cutoff]
                      [-t dir_where_TAXONOMY_files_are] [-g gi2taxid] 
                      [-z PATH_TO_zcat] [-v]

=head2 DESCRIPTION

Will print out the taxonomic distribution (at the kingdom level) for a
set of hits against the NR database.  This script assumes you've done
a search against the protein database, you'll have to make minor
changes in the gi_taxid part to point to the gi_taxid_nuc.dump file.
The gi_taxid files and nodes.dmp (part of taxdump.tar.gz) can be 
downloaded from ftp://ftp.ncbi.nlm.nih.gov/pub/taxonomy/.

This expects BLAST files in tabbed -m9 or -m8 format.  Output with -m
8 or use blast2table.pl to convert (or fastam9_to_table.PLS if using
FASTA).

  Input values:
   -t/--taxonomy  directory where the taxonomy .dmp files are (from NCBI)
   -g/--gi        Location of gi_taxid_prot.dmp (or gi_taxid_nucl.dmp if 
                  the search was against a NT db)
   -i/--in        The name of the tab delimited -m8/-m9 output files to 
                  process.

    -e/--evalue   Provide an E-value cutoff for hits to be considered
    -z/--zcat     Path to the 'zcat' executable, can also be 'gunzip -c'
                  if no zcat on your system.
   Flags
    -v/--verbose  To turn on verbose messages
    -h/--help     Display this helpful information

This is intended to be useful starting script, but users may want to
customize the output and parameters.  Note that I am summarizing the
kingdoms here and Eukaryota not falling into Metazoa, Viridiplantae,
or Fungi gets grouped into the general superkingdom Eukaryota. for
simplicity.  There are comments in the code directing you to where
changes can be made if you wanted to display hits by phylum for
example.  Note that you must wipe out the cache file 'gi2class' that
is craeed in your directory after making these changes.

=head2 AUTHOR

Jason Stajich jason_at_bioperl_dot_org

=cut

use strict;
use Bio::DB::Taxonomy;
use DBI;
use Env;
use File::Spec;
use vars qw($SEP);
my $DEBUG = 0;
use Getopt::Long;
$SEP = '_';

my $evalue_filter = 1e-3;
my @files;
my $zcat = 'zcat'; # or gunzip -c 
my $prefix = File::Spec->catfile($HOME,'taxonomy');
my $gi2taxidfile = undef;
my $force = 0; # don't use the cached gi2taxid file
my $print_individuals = 0; # print out what each BLAST hit hits
my $top_level_ids_string = ''; # comma separated list of extra IDs to look for, other than kingdom and superkingdom.
my $index_directory = undef;

GetOptions(
	   'v|verbose|debug' => \$DEBUG,
	   'force!'          => \$force,
	   'z|zcat:s'    => \$zcat,
	   'i|in:s'      => \@files,
	   'e|evalue:f'  => \$evalue_filter,
	   't|taxonomy:s' => \$prefix,
	   'g|gi|gi2taxid:s' => \$gi2taxidfile,
	   'h|help'      => sub { system('perldoc', $0);
				  exit },
           'n|individuals'     => \$print_individuals,
           'l|top_level_ids:s'  => \$top_level_ids_string,
           'x|index:s'  => \$index_directory,
	   );

# comma separated to list of IDs
my @top_level_ids_array = split ',', $top_level_ids_string;
my %top_level_ids_hash = map { $_ => 1 } @top_level_ids_array;

# Use default values unless the variables have already been defined
$prefix = File::Spec->catfile($HOME,'taxonomy') unless (defined($prefix));
$gi2taxidfile = "$prefix/gi_taxid_prot.dmp.gz" unless (defined($gi2taxidfile));
$index_directory = File::Spec->catfile($prefix,'idx') unless (defined($index_directory));

# Ensure idx location is created
warn "Using index directory $index_directory\n" if $DEBUG;
mkdir $index_directory unless -d $index_directory;

# these files came from ftp://ftp.ncbi.nih.gov/pub/taxonomy
warn "Attempting to use nodes.dmp and names.dmp in $prefix, creating index in $index_directory\n" if $DEBUG;

my $taxdb = Bio::DB::Taxonomy->new
    (-source => 'flatfile',
     -directory => $index_directory, 
     -nodesfile => File::Spec->catfile($prefix,'nodes.dmp'),
     -namesfile => File::Spec->catfile($prefix,'names.dmp')
     );
my %query;

warn "Using ben's script version 5\n";

# Create an sqlite database to hold taxonomy information in a more
# useful format.
my (%taxid4gi,%gi2node);
my $dbh = tie(%gi2node, 'DB_File', 'gi2class');
my $giidxfile = File::Spec->catfile($index_directory,'gi2taxid');
my $done = -e $giidxfile;
$done = 0 if $force;
my $dbh2 = my $dbh = DBI->connect("dbi:SQLite:dbname=$giidxfile","","");
if( ! $done ) {
   $dbh2->do("CREATE TABLE gi2taxid ( gi integer PRIMARY KEY,
				      taxid integer NOT NULL)");
   $dbh2->{AutoCommit} = 0;
    my $fh;
    # this file came from ftp://ftp.ncbi.nih.gov/pub/taxonomy
    # I'm interested in protein hits therefore the _prot file.
    warn "Using gi to taxonomy ID database file `$gi2taxidfile'\n";
    if( $gi2taxidfile =~ /\.gz$/ ) {
	open($fh, "$zcat $gi2taxidfile |" ) || die "$zcat $gi2taxidfile: $!";
    } else {
	open($fh, $gi2taxidfile ) || die $!;
    }
    my $i = 0;
   my $sth = $dbh2->prepare("INSERT INTO gi2taxid (gi,taxid) VALUES (?,?)");

    while(<$fh>) {
	my ($gi,$taxid) = split;
	$sth->execute($gi,$taxid);
	$i++;
	if( $i % 500000 == 0 ) {
		$dbh->commit;
		warn("$i\n") if $DEBUG;
	} 
    }
    $dbh->commit;
    $sth->finish;
}
print "Finished SQlite database.\n";

# Run through each of the BLAST output files provided.
for my $file ( @files ) {
    warn("Now classifying `$file' ...\n");
    my $gz;
    if( $file =~ /\.gz$/) {
	$gz = 1;
    }
    my ($spname) = split(/\./,$file); 
    my ($fh,$i);
    if( $gz ) {
	open($fh, "$zcat $file |")  || die "$zcat $file: $!";
    } else {
	open($fh, $file) || die "$file: $!";
    }
    my $sth = $dbh->prepare("SELECT taxid from gi2taxid WHERE gi=?");
    while(<$fh>) {
        next if /^\#/;
	my ($qname,$hname,$pid,$qaln,$mismatch,$gaps,
	    $qstart,$qend,$hstart,$hend,
	    $evalue,$bits,$score) = split(/\t/,$_);	
	next if( $evalue > $evalue_filter );
	if( ! exists $query{$spname}->{$qname} ) {
	    $query{$spname}->{$qname} = {};
	}
	
	if( $hname =~ /gi\|(\d+)/) {		
	    my $gi = $1;	    
	    if( ! $gi2node{$gi} ){ # see if we cached the results from before
		$sth->execute($gi);
		my $taxid;
		$sth->bind_columns(\$taxid);
		if( ! $sth->fetch ) {
		    warn("no taxid for $gi\n");
		    next;
		}
		my $node = $taxdb->get_Taxonomy_Node($taxid);
		if( ! $node ) {
		    warn("cannot find node for gi=$gi ($hname) (taxid=$taxid)\n");
		    next;
		}
		my $parent = $taxdb->get_Taxonomy_Node($node->parent_id);

		# THIS IS WHERE THE KINGDOM DECISION IS MADE
		# DON'T FORGET TO WIPE OUT YOUR CACHE FILE
		# gi2class after you make changes here
		while( defined $parent && $parent->node_name ne 'root' ) { 
		    # this is walking up the taxonomy hierarchy
		    # can be a little slow, but works...
		    #warn( "\t",$parent->rank, " ", $parent->node_name, "\n");
		    # deal with Eubacteria, Archea separate from 
		    # Metazoa, Fungi, Viriplantae differently
		    # (everything else Eukaryotic goes in Eukaryota)
		    if( $parent->rank eq 'kingdom') {
			# caching in ... 
			($gi2node{$gi}) = $parent->node_name;
			last;
		    } elsif( $parent->rank eq 'superkingdom' ) {
			# caching in ... 
			($gi2node{$gi}) = $parent->node_name;
			$gi2node{$gi} =~ s/ \<(bacteria|archaea)\>//g;
			last;
		    } elsif (exists($top_level_ids_hash{$parent->id})) { #user-specified taxonomy ceiling found?
			($gi2node{$gi}) = $parent->node_name;
			last;
		    }
		    $parent = $taxdb->get_Taxonomy_Node($parent->parent_id);
		}		
	    } 
	    my ($kingdom) = $gi2node{$gi};
            print($qname."\t".$hname."\t".$gi2node{$gi}."\n") if ($print_individuals);
	    unless( defined $kingdom && length($kingdom) ) {
		    warn("no kingdom for $hname\n");
	    } else {
		$query{$spname}->{$qname}->{$kingdom}++;		
	    }	
	} else {
	    warn("no GI in $hname\n");
	}
    }
    last if ( $DEBUG && $i++ > 10000);
    $sth->finish;
}

# print out the taxonomic distribution
while( my ($sp,$d) = each %query ) {
    my $total = scalar keys %$d;
    print "$sp total=$total\n";
    my %seen;
    for my $v ( values %$d ) {
	my $tag = join(",",sort keys %$v );
	$seen{$tag}++;
    }
    for my $t ( sort { $seen{$a} <=> $seen{$b} } keys %seen ) {
	printf " %-20s\t%d\t%.2f%%\n",
	$t,$seen{$t}, 100 * $seen{$t} / $total;
    }
    print "\n\n";
}