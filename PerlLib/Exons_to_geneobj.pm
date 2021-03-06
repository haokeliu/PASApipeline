package main;
our $SEE;

package Exons_to_geneobj;

use strict;
use Longest_orf;
use Gene_obj;
use Carp;
use Data::Dumper;

## No reason to instantiate.  Use methods, fully qualified.
## allow for partial ORFS (missing start or stop codon in longest ORF)

###################
## Public method ##
###################

sub create_gene_obj {
    my ($exons_href, $sequence_ref, $partial_info_href) = @_;
    unless (ref $sequence_ref) {
        die "Error, need reference to sequence as input parameter.\n";
    }
    unless (ref $partial_info_href) {
        $partial_info_href = {};
    }
    
    ## exons_ref should be end5's keyed to end3's for all exons.
    my ($gene_struct_mod, $cdna_seq)  = &get_cdna_seq ($exons_href, $sequence_ref);
    
    
    
    my $cdna_seq_length = length $cdna_seq;
    my $long_orf_obj = new Longest_orf();
    
    #print STDERR "CDNA_SEQ: [$cdna_seq], length: $cdna_seq_length\n";

    # establish long orf finding parameters.
    $long_orf_obj->forward_strand_only();
    if ($partial_info_href->{"5prime"}) {
        print "Exons_to_geneobj: Allowing 5' partials\n" if $SEE;
        $long_orf_obj->allow_5prime_partials();
    }
    if ($partial_info_href->{"3prime"}) {
        $long_orf_obj->allow_3prime_partials();
    }
    
    $long_orf_obj->get_longest_orf($cdna_seq);
    my ($end5, $end3) = $long_orf_obj->get_end5_end3(); 
    
    #print STDERR "***   CDS: $end5, $end3\n";# if $SEE;
    my $gene_obj = &create_gene ($gene_struct_mod, $end5, $end3);
    
    #print STDERR $gene_obj->toString();
    
    $gene_obj->create_all_sequence_types($sequence_ref);
    my $protein = $gene_obj->get_protein_sequence();
    my $recons_cds = $gene_obj->get_CDS_sequence();
    #print STDERR "reconsCDS: $recons_cds\n";

    ## check partiality
    if ($protein) { # it is possible that we won't have any cds structure
        if ($protein !~ /^M/) {
            # this would require that we allowed for 5prime partials
            unless ($partial_info_href->{"5prime"}) {
                confess "Error, have 5' partial protein when 5prime partials weren't allowed!\n$protein\n$cdna_seq\n";
            }
        }
        if ($protein !~ /\*$/) {
            # this would require that we allowed for 3prime partials
            unless ($partial_info_href->{"3prime"}) {
                confess "Error, have 3' partial protein when 3prime partials weren't allowed!\n$protein\n$cdna_seq\n";
            }
        }
   
        ## set partiality attributes and set CDS phases
        $gene_obj->set_CDS_phases($sequence_ref);
        
    }
    
    return ($gene_obj);
}


########################
## Private methods #####
########################

####
sub get_cdna_seq {
    my ($gene_struct, $assembly_seq_ref) = @_;
    
    my $seq_length = length($$assembly_seq_ref);

    my (@end5s) = sort {$a<=>$b} keys %$gene_struct;
    my $strand = "?";
    foreach my $end5 (@end5s) {
        my $end3 = $gene_struct->{$end5};
        if ($end5 == $end3) { next;}
        $strand = ($end5 < $end3) ? '+':'-';
        last;
    }
    if ($strand eq "?") {
        print Dumper ($gene_struct);
        confess "ERROR: I can't determine what orientation the cDNA is in!\n";
    }
    print NOTES "strand: $strand\n";
    my $cdna_seq;
    my $gene_struct_mod = {strand=>$strand,
                           exons=>[]}; #ordered lend->rend coordinate listing.
    foreach my $end5 (@end5s) {
        #print $end5;
        my $end3 = $gene_struct->{$end5};
        
        if ($end5 > $seq_length || $end3 > $seq_length) {
            confess "Error, coords are out of bounds of sequence length: $seq_length:\n" . Dumper(\$gene_struct);
        }
        
        my ($coord1, $coord2) = sort {$a<=>$b} ($end5, $end3);
        my $exon_seq = substr ($$assembly_seq_ref, $coord1 - 1, ($coord2 - $coord1 + 1));
        $cdna_seq .= $exon_seq;
        push (@{$gene_struct_mod->{exons}}, [$coord1, $coord2]);
    }
    if ($strand eq '-') {
        $cdna_seq = reverse_complement ($cdna_seq);
    }
    return ($gene_struct_mod, $cdna_seq);
}


####
sub create_gene {
    my ($gene_struct_mod, $cds_pointer_lend, $cds_pointer_rend) = @_;
    
    #use Data::Dumper;
    #print STDERR Dumper($gene_struct_mod) . "CDS: $cds_pointer_lend, $cds_pointer_rend\n";
        
    my $strand = $gene_struct_mod->{strand};
    my @exons = sort {$a->[0]<=>$b->[0]} @{$gene_struct_mod->{exons}};
    if ($strand eq '-') {
        @exons = reverse (@exons);
    }
    my $mRNA_pointer_lend = 1;
    my $mRNA_pointer_rend = 0;
    my $gene_obj = new Gene_obj();
    foreach my $coordset_ref (@exons) {
        my ($coord1, $coord2) = sort {$a<=>$b} @$coordset_ref;
        my ($end5, $end3) = ($strand eq '+') ? ($coord1, $coord2) : ($coord2, $coord1);
        my $exon_obj = new mRNA_exon_obj($end5, $end3);
        my $exon_length = ($coord2 - $coord1 + 1);
        $mRNA_pointer_rend = $mRNA_pointer_lend + $exon_length - 1;
        ## see if cds is within current cDNA range.
        #print STDERR "mRNA coords: $mRNA_pointer_lend-$mRNA_pointer_rend\n";
        if ( $cds_pointer_rend >= $mRNA_pointer_lend && $cds_pointer_lend <= $mRNA_pointer_rend) { #overlap
            my $diff = $cds_pointer_lend - $mRNA_pointer_lend;
            my $delta_lend = ($diff >0) ? $diff : 0;
            $diff = $mRNA_pointer_rend - $cds_pointer_rend;
            my $delta_rend = ($diff > 0) ? $diff : 0;
            if ($strand eq '+') {
                $exon_obj->add_CDS_exon_obj($end5 + $delta_lend, $end3 - $delta_rend);
            } else {
                $exon_obj->add_CDS_exon_obj($end5 - $delta_lend, $end3 + $delta_rend);
            }
        }
        $gene_obj->add_mRNA_exon_obj($exon_obj);
        $mRNA_pointer_lend = $mRNA_pointer_rend + 1;
    }
    $gene_obj->refine_gene_object();
    #$gene_obj->{strand} = $strand;
    print $gene_obj->toString() if $SEE;
    return ($gene_obj);
}


sub reverse_complement { 
    my($s) = @_;
     my ($rc);
    $rc = reverse ($s);
    $rc =~tr/ACGTacgtyrkmYRKM/TGCAtgcarymkRYMK/;
    return($rc);
}



1; #EOM
