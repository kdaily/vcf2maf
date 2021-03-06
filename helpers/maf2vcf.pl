#!/usr/bin/env perl

# maf2vcf - Parse out variant loci and alleles from a MAF to create generic VCF files per TN-pair

use strict;
use warnings;
use IO::File;
use Getopt::Long qw( GetOptions );
use Pod::Usage qw( pod2usage );

# Set any default paths and constants
my $ref_fasta = "~/.vep/homo_sapiens/75/Homo_sapiens.GRCh37.75.dna.primary_assembly.fa";
my ( $tum_depth_col, $tum_rad_col, $tum_vad_col ) = qw( t_depth t_ref_count t_alt_count );
my ( $nrm_depth_col, $nrm_rad_col, $nrm_vad_col ) = qw( n_depth n_ref_count n_alt_count );

# Find out where samtools is installed, and warn the user if it's not
my $samtools = ( -e "/opt/bin/samtools" ? "/opt/bin/samtools" : "/usr/bin/samtools" );
$samtools = `which samtools` unless( -e $samtools );
chomp( $samtools );
( $samtools and -e $samtools ) or die "Please install samtools, and make sure it's in your PATH\n";

# Check for missing or crappy arguments
unless( @ARGV and $ARGV[0]=~m/^-/ ) {
    pod2usage( -verbose => 0, -message => "$0: Missing or invalid arguments!\n", -exitval => 2 );
}

# Parse options and print usage syntax on a syntax error, or if help was explicitly requested
my ( $man, $help ) = ( 0, 0 );
my ( $input_maf, $output_dir );
GetOptions(
    'help!'           => \$help,
    'man!'            => \$man,
    'input-maf=s'     => \$input_maf,
    'output-dir=s'    => \$output_dir,
    'ref-fasta=s'     => \$ref_fasta,
    'tum-depth-col=s' => \$tum_depth_col,
    'tum-rad-col=s'   => \$tum_rad_col,
    'tum-vad-col=s'   => \$tum_vad_col,
    'nrm-depth-col=s' => \$nrm_depth_col,
    'nrm-rad-col=s'   => \$nrm_rad_col,
    'nrm-vad-col=s'   => \$nrm_vad_col
) or pod2usage( -verbose => 1, -input => \*DATA, -exitval => 2 );
pod2usage( -verbose => 1, -input => \*DATA, -exitval => 0 ) if( $help );
pod2usage( -verbose => 2, -input => \*DATA, -exitval => 0 ) if( $man );

# Fetch all tumor-normal paired IDs from the MAF
my @tn_pair = map{s/^\s+|\s+$|\r|\n//g; $_}`egrep -v "^#|^Hugo_Symbol" $input_maf | cut -f 16,17 | sort -u`;

# For each TN-pair, initialize blank VCFs with proper VCF headers in user-specified output directory
unless( -e $output_dir ) { mkdir $output_dir or die "Couldn't create directory $output_dir! $!"; }
foreach my $pair ( @tn_pair ) {
    my ( $t_id, $n_id ) = split( /\t/, $pair );
    my $vcf_file = "$output_dir/$t_id\_vs_$n_id.vcf";
    my $vcf_fh = IO::File->new( $vcf_file, ">" );
    $vcf_fh->print( "##fileformat=VCFv4.2\n" );
    $vcf_fh->print( "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\"\n" );
    $vcf_fh->print( "##FORMAT=<ID=AD,Number=G,Type=Integer,Description=\"Allelic Depths of REF and ALT(s) in the order listed\">\n" );
    $vcf_fh->print( "##FORMAT=<ID=DP,Number=1,Type=Integer,Description=\"Read Depth\">\n" );
    $vcf_fh->print( "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\t$t_id\t$n_id\n" );
    $vcf_fh->close;
}

# Parse through each variant in the MAF, and fill up the respective VCFs
my $maf_fh = IO::File->new( $input_maf );
my %col_idx = (); # Hash to map column names to column indexes
while( my $line = $maf_fh->getline ) {

    # Skip comment lines
    next if( $line =~ m/^#/ );

    # Instead of a chomp, do a thorough removal of carriage returns, line feeds, and prefixed/suffixed whitespace
    my @cols = map{s/^\s+|\s+$|\r|\n//g; $_} split( /\t/, $line );

    # Parse the header line to map column names to their indexes
    if( $line =~ m/^Hugo_Symbol/ ) {
        my $idx = 0;
        map{ $col_idx{$_} = $idx; ++$idx; } @cols;
        next;
    }

    # Parse out the bare minimum data needed for a VCF
    my ( $chr, $pos, $type, $ref, $alt1, $alt2, $t_id, $n_id ) = @cols[4,5,9..12,15,16];

    # Parse out read counts for ref/var alleles, if available
    my ( $t_dp, $t_rad, $t_vad ) = map{( $col_idx{$_} ? $cols[$col_idx{$_}] : '.' )} ( $tum_depth_col, $tum_rad_col, $tum_vad_col );
    my ( $n_dp, $n_rad, $n_vad ) = map{( $col_idx{$_} ? $cols[$col_idx{$_}] : '.' )} ( $nrm_depth_col, $nrm_rad_col, $nrm_vad_col );

    # Figure out genotypes and construct FORMATted genotype fields
    my $t_gt = ( $alt1 eq $alt2 ? "1/1" : "0/1" );
    $ref =~ s/^(\?|-|0)$//; $alt1 =~ s/^(\?|-|0)$//; $alt2 =~ s/^(\?|-|0)$//;
    my $var = ( $alt1 ne $ref ? $alt1 : $alt2 );
    my $t_fmt = "$t_gt:$t_rad,$t_vad:$t_dp";
    my $n_fmt = "0/0:$n_rad,$n_vad:$n_dp"; # We'll assume homozygous reference in normal tissue

    # To represent indels in VCF format, we'll need to fetch the preceding bp from a reference FASTA
    my ( $ref_length, $var_length ) = ( length( $ref ), length( $var ));
    if( $type eq "DEL" or $type eq "INS" ) {
        --$pos if( $type eq "DEL" );
        my $prefix_bp = `$samtools faidx $ref_fasta $chr:$pos-$pos | grep -v ^\\>`;
        chomp( $prefix_bp );
        $prefix_bp or die "Couldn't get samtools to run!\n";
        $ref =~ s/^/$prefix_bp/;
        $var =~ s/^/$prefix_bp/;
    }
    # SNPs, MNPs, and other complex substitutions don't need any conversion for the VCF
    elsif( $type !~ m/^(SNP|DNP|TNP|ONP)$/ ) {
        die "Cannot handle this variant type: $type\n";
    }

    # Contruct a VCF formatted line and append it to the respective VCF
    my $vcf_file = "$output_dir/$t_id\_vs_$n_id.vcf";
    my $vcf_line = join( "\t", $chr, $pos, ".", $ref, $var, qw( . . . ), "GT:AD:DP", $t_fmt, $n_fmt );
    my $vcf_fh = IO::File->new( $vcf_file, ">>" );
    $vcf_fh->print( "$vcf_line\n" );
    $vcf_fh->close;
}
$maf_fh->close;

__DATA__

=head1 NAME

 maf2vcf.pl - Reformat variants in a given MAF, into a generic VCF format with GT:AD:DP if available

=head1 SYNOPSIS

 perl maf2vcf.pl --help
 perl maf2vcf.pl --input-maf test.maf --output-dir vcfs

=head1 OPTIONS

 --input-maf      Path to input file in MAF format
 --output-dir     Path to output directory where VCFs will be stored, one per TN-pair
 --ref-fasta      Path to reference Fasta file [~/.vep/homo_sapiens/75/Homo_sapiens.GRCh37.75.dna.primary_assembly.fa]
 --tum-depth-col  Name of MAF column for read depth in tumor BAM [t_depth]
 --tum-rad-col    Name of MAF column for reference allele depth in tumor BAM [t_ref_count]
 --tum-vad-col    Name of MAF column for variant allele depth in tumor BAM [t_alt_count]
 --nrm-depth-col  Name of MAF column for read depth in normal BAM [n_depth]
 --nrm-rad-col    Name of MAF column for reference allele depth in normal BAM [n_ref_count]
 --nrm-vad-col    Name of MAF column for variant allele depth in normal BAM [n_alt_count]
 --help           Print a brief help message and quit
 --man            Print the detailed manual

=head1 DESCRIPTION

This script breaks down variants in a MAF into VCFs for each tumor-normal pair, ready for annotation with Ensembl's VEP or snpEff.

=head2 Relevant links:

 Homepage: https://github.com/ckandoth/vcf2maf
 VCF format: http://samtools.github.io/hts-specs/
 MAF format: https://wiki.nci.nih.gov/x/eJaPAQ

=head1 AUTHORS

 Cyriac Kandoth (ckandoth@gmail.com)

=head1 LICENSE

 LGPLv3, Memorial Sloan Kettering Cancer Center, New York, NY 10065, USA

=cut
