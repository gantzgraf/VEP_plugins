=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2018] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 CONTACT

 Ensembl <http://www.ensembl.org/info/about/contact/index.html>
    
=cut

=head1 NAME

 MaxEntScan

=head1 SYNOPSIS

 mv MaxEntScan.pm ~/.vep/Plugins
 ./vep -i variants.vcf --plugin MaxEntScan,/path/to/maxentscan/fordownload
 ./vep -i variants.vcf --plugin MaxEntScan,/path/to/maxentscan/fordownload,SWA,NCSS

=head1 DESCRIPTION

 This is a plugin for the Ensembl Variant Effect Predictor (VEP) that
 runs MaxEntScan (http://genes.mit.edu/burgelab/maxent/Xmaxentscan_scoreseq.html)
 to get splice site predictions.

 The plugin copies most of the code verbatim from the score5.pl and score3.pl
 scripts provided in the MaxEntScan download. To run the plugin you must get and
 unpack the archive from http://genes.mit.edu/burgelab/maxent/download/; the path
 to this unpacked directory is then the param you pass to the --plugin flag.

 The plugin executes the logic from one of the scripts depending on which
 splice region the variant overlaps:

 score5.pl : last 3 bases of exon    --> first 6 bases of intron
 score3.pl : last 20 bases of intron --> first 3 bases of exon

 The plugin reports the reference, alternate and difference (REF - ALT) maximum
 entropy scores.

 If 'SWA' is specified as a command-line argument, a sliding window algorithm
 is applied to subsequences containing the reference and alternate alleles to
 identify k-mers with the highest donor and acceptor splice site scores. To assess
 the impact of variants, reference comparison scores are also provided. For SNVs,
 the comparison scores are derived from sequence in the same frame as the highest
 scoring k-mers containing the alternate allele. For all other variants, the
 comparison scores are derived from the highest scoring k-mers containing the
 reference allele. The difference between the reference comparison and alternate
 scores (SWA_REF_COMP - SWA_ALT) are also provided.

 If 'NCSS' is specified as a command-line argument, scores for the nearest
 upstream and downstream canonical splice sites are also included.

 By default, only scores are reported. Add 'verbose' to the list of command-
 line arguments to include the sequence output associated with those scores.

=cut

package MaxEntScan;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);

use Bio::EnsEMBL::Utils::Sequence qw(reverse_comp);
use Bio::EnsEMBL::Variation::Utils::VariationEffect qw(overlap);

use Bio::EnsEMBL::Variation::Utils::BaseVepPlugin;
use base qw(Bio::EnsEMBL::Variation::Utils::BaseVepPlugin);

# how many seq/score pairs to cache in memory
our $CACHE_SIZE = 50;

sub new {
  my $class = shift;

  my $self = $class->SUPER::new(@_);
  
  # we need sequence, so no offline mode unless we have FASTA
  die("ERROR: cannot function in offline mode without a FASTA file\n") if $self->{config}->{offline} && !$self->{config}->{fasta};

  my $params = $self->params;

  my $dir = shift @$params;
  die("ERROR: MaxEntScan directory not specified\n") unless $dir;
  die("ERROR: MaxEntScan directory not found\n") unless -d $dir;
  $self->{_dir} = $dir;

  ## setup from score5.pl
  $self->{'score5_me2x5'} = $self->score5_makescorematrix($dir.'/me2x5');
  $self->{'score5_seq'}   = $self->score5_makesequencematrix($dir.'/splicemodels/splice5sequences');

  ## setup from score3.pl
  $self->{'score3_metables'} = $self->score3_makemaxentscores;

  my %opts = map { $_ => undef } @$params;

  $self->{'run_SWA'} = 1 if exists $opts{'SWA'};
  $self->{'run_NCSS'} = 1 if exists $opts{'NCSS'};

  $self->{'scores_only'} = 1 unless exists $opts{'verbose'};

  return $self;
}

sub feature_types {
  return ['Transcript'];
}

sub get_header_info {
  my $self = shift;

  my $headers = $self->get_MES_header_info();

  if ($self->{'scores_only'}) {
    my @seqs = grep { /_seq$/ } keys %$headers;
    delete @{$headers}{@seqs};
  }

  if ($self->{'run_SWA'}) {
    my $swa_headers = $self->get_SWA_header_info();

    if ($self->{'scores_only'}) {
      my @swa_keys = grep { !/_score$/ && !/_diff$/ } keys %$swa_headers;
      delete @{$swa_headers}{@swa_keys};
    }

    $headers = {%$headers, %$swa_headers};
  }

  if ($self->{'run_NCSS'}) {
    my $ncss_headers = $self->get_NCSS_header_info();

    if ($self->{'scores_only'}) {
      my @ncss_keys = grep { !/_score$/ } keys %$ncss_headers;
      delete @{$ncss_headers}{@ncss_keys};
    }

    $headers = {%$headers, %$ncss_headers};
  }

  return $headers;
}

sub get_MES_header_info {
  return {
    MaxEntScan_ref => "MaxEntScan reference sequence score",
    MaxEntScan_ref_seq => "MaxEntScan reference sequence",
    MaxEntScan_alt => "MaxEntScan alternate sequence score",
    MaxEntScan_alt_seq => "MaxEntScan alternate sequence",
    MaxEntScan_diff => "MaxEntScan score difference",
  };
}

sub get_SWA_header_info {
  return {

    # donor values

    "MES-SWA_donor_alt_subseq" =>
      "Splice donor subsequence containing the alternate allele",
    "MES-SWA_donor_alt_kmer" =>
      "Substring (k-mer) with the highest splice donor score containing the alternate allele",
    "MES-SWA_donor_alt_frame" =>
      "Position of the k-mer with the highest splice donor score containing the alternate allele",
    "MES-SWA_donor_alt_score" =>
       "Score of the k-mer with the highest splice donor score containing the alternate allele",

    "MES-SWA_donor_diff" =>
      "Difference between the donor reference comparison score and donor alternate score",

    "MES-SWA_donor_ref_comp_seq" =>
      "Selected donor reference comparison sequence (SNVs: Donor ALT frame, non-SNVs: Donor REF frame)",
    "MES-SWA_donor_ref_comp_score" =>
      "Selected donor reference comparison score (SNVs: SWA Donor ALT frame, non-SNVs: Donor REF frame)",

    "MES-SWA_donor_ref_subseq" =>
      "Splice donor subsequence containing the reference allele",
    "MES-SWA_donor_ref_kmer" =>
      "Substring (k-mer) with the highest splice donor score containing the reference allele",
    "MES-SWA_donor_ref_frame" =>
      "Position of the k-mer with the highest splice donor score containing the reference allele",
    "MES-SWA_donor_ref_score" =>
      "Score of the k-mer with the highest splice donor score containing the reference allele",

    # acceptor values

    "MES-SWA_acceptor_alt_subseq" =>
      "Splice acceptor subsequence containing the alternate allele",
    "MES-SWA_acceptor_alt_kmer" =>
      "Substring (k-mer) with the highest splice acceptor score containing the alternate allele",
    "MES-SWA_acceptor_alt_frame" =>
      "Position of the k-mer with the highest splice acceptor score containing the alternate allele",
    "MES-SWA_acceptor_alt_score" =>
      "Score of the k-mer with the highest splice acceptor score containing the alternate allele",

    "MES-SWA_acceptor_diff" =>
      "Difference between the acceptor reference comparison score and acceptor alternate score",

    "MES-SWA_acceptor_ref_comp_seq" =>
      "Selected acceptor reference comparison sequence (SNVs: Donor ALT frame, non-SNVs: Donor REF frame)",
    "MES-SWA_acceptor_ref_comp_score" =>
      "Selected acceptor reference comparison score (SNVs: SWA Donor ALT frame, non-SNVs: Donor REF frame)",

    "MES-SWA_acceptor_ref_subseq" =>
      "Splice acceptor subsequence containing the reference allele",
    "MES-SWA_acceptor_ref_kmer" =>
      "Substring (k-mer) with the highest splice acceptor score containing the reference allele",
    "MES-SWA_acceptor_ref_frame" =>
      "Position of the k-mer with the highest splice acceptor score containing the reference allele",
    "MES-SWA_acceptor_ref_score" =>
      "Score of the k-mer with the highest splice acceptor score containing the reference allele",
  };
}

sub get_NCSS_header_info {
  return {
    "MES-NCSS_upstream_donor_seq" => "Nearest upstream canonical splice donor sequence",
    "MES-NCSS_upstream_donor_score" => "Nearest upstream canonical splice donor score",
    "MES-NCSS_downstream_donor_seq" => "Nearest downstream canonical splice donor sequence",
    "MES-NCSS_downstream_donor_score" => "Nearest downstream canonical splice donor score",

    "MES-NCSS_upstream_acceptor_seq" => "Nearest upstream canonical splice acceptor sequence",
    "MES-NCSS_upstream_acceptor_score" => "Nearest upstream canonical splice acceptor score",
    "MES-NCSS_downstream_acceptor_seq" => "Nearest downstream canonical splice acceptor sequence",
    "MES-NCSS_downstream_acceptor_score" => "Nearest downstream canonical splice acceptor score",
  };
}

sub run {
  my ($self, $tva) = @_;

  my $results = $self->run_MES($tva);

  if ($self->{'run_SWA'}) {
    my $swa_results = $self->run_SWA($tva);
    $results = {%$results, %$swa_results};
  }

  if ($self->{'run_NCSS'}) {
    my $ncss_results = $self->run_NCSS($tva);
    $results = {%$results, %$ncss_results};
  }

  return $results;
}

sub run_MES {
  my ($self, $tva) = @_;

  my $vf = $tva->variation_feature;
  return {} unless $vf->{start} == $vf->{end} && $tva->feature_seq =~ /^[ACGT]$/;

  my $tv = $tva->transcript_variation;
  my $tr = $tva->transcript;
  my $tr_strand = $tr->strand;
  my ($vf_start, $vf_end) = ($vf->start, $vf->end);

  # use _overlapped_introns() method from BaseTranscriptVariation
  # this will use an interval tree if available for superfast lookup of overlapping introns
  # we have to expand the search space around $vf because we're looking for the splice region not the intron per se
  foreach my $intron(@{$tv->_overlapped_introns($vf_start - 21, $vf_end + 21)}) {
    
    # get coords depending on strand
    # MaxEntScan does different predictions for 5 and 3 prime
    # and we need to feed it different bits of sequence for each
    #
    # 5prime, 3 bases of exon, 6 bases of intron:
    # ===------
    #
    # 3prime, 20 bases of intron, 3 bases of exon
    # --------------------===

    my ($five_start, $five_end, $three_start, $three_end);

    if($tr_strand > 0) {
      ($five_start, $five_end)   = ($intron->start - 3, $intron->start + 5);
      ($three_start, $three_end) = ($intron->end - 19, $intron->end + 3);
    }

    else {
      ($five_start, $five_end)   = ($intron->end - 5, $intron->end + 3);
      ($three_start, $three_end) = ($intron->start - 3, $intron->start + 19);
    }

    if(overlap($vf->start, $vf->end, $five_start, $five_end)) {
      my ($ref_seq, $alt_seq) = @{$self->get_seqs($tva, $five_start, $five_end)};

      return {} unless defined($ref_seq) && $ref_seq =~ /^[ACGT]+$/;
      return {} unless defined($alt_seq) && $alt_seq =~ /^[ACGT]+$/;

      my $ref_score = $self->score5($ref_seq);
      my $alt_score = $self->score5($alt_seq);

      return {
        MaxEntScan_ref => $ref_score,
        MaxEntScan_ref_seq => $ref_seq,
        MaxEntScan_alt => $alt_score,
        MaxEntScan_alt_seq => $alt_seq,
        MaxEntScan_diff => $ref_score - $alt_score,
      }
    }

    if(overlap($vf->start, $vf->end, $three_start, $three_end)) {
      my ($ref_seq, $alt_seq) = @{$self->get_seqs($tva, $three_start, $three_end)};

      return {} unless defined($ref_seq) && $ref_seq =~ /^[ACGT]+$/;
      return {} unless defined($alt_seq) && $alt_seq =~ /^[ACGT]+$/;

      my $ref_score = $self->score3($ref_seq);
      my $alt_score = $self->score3($alt_seq);

      return {
        MaxEntScan_ref => $ref_score,
        MaxEntScan_ref_seq => $ref_seq,
        MaxEntScan_alt => $alt_score,
        MaxEntScan_alt_seq => $alt_seq,
        MaxEntScan_diff => $ref_score - $alt_score,
      }
    }
  }

  return {};
}

sub run_SWA {
  my ($self, $tva) = @_;

  my $vf = $tva->variation_feature;

  my ($vf_start, $vf_end) = ($vf->start, $vf->end);

  # for score5.pl, the splice donor needs a window of 9 bases
  my ($donor_ref_subseq, $donor_alt_subseq) =
    @{$self->get_seqs($tva, $vf_start - 8, $vf_end + 8)};

  my ($donor_alt_kmer, $donor_alt_frame, $donor_alt_score);
  my ($donor_ref_kmer, $donor_ref_frame, $donor_ref_score);

  my ($donor_ref_comp_seq, $donor_ref_comp_score);

  my $donor_diff;

  if (defined($donor_alt_subseq) && $donor_alt_subseq =~ /^[ACGT]+$/) {

    ($donor_alt_kmer, $donor_alt_frame, $donor_alt_score) =
      @{$self->get_max_donor_score($donor_alt_subseq)};

    ($donor_ref_kmer, $donor_ref_frame, $donor_ref_score) =
      @{$self->get_max_donor_score($donor_ref_subseq)};

    $donor_ref_comp_seq = $donor_ref_kmer;
    $donor_ref_comp_score = $donor_ref_score;

    if ($vf->{start} == $vf->{end} && $tva->feature_seq =~ /^[ACGT]$/) {
      $donor_ref_comp_seq = substr($donor_ref_subseq, $donor_alt_frame - 1, 9);
      $donor_ref_comp_score = $self->score5($donor_ref_comp_seq);
    }

    $donor_diff = $donor_ref_comp_score - $donor_alt_score;
  }

  # for score3.pl, the splice acceptor needs a window of 23 bases
  my ($acceptor_ref_subseq, $acceptor_alt_subseq) =
    @{$self->get_seqs($tva, $vf_start - 22, $vf_end + 22)};

  my ($acceptor_alt_kmer, $acceptor_alt_frame, $acceptor_alt_score);
  my ($acceptor_ref_kmer, $acceptor_ref_frame, $acceptor_ref_score);

  my ($acceptor_ref_comp_seq, $acceptor_ref_comp_score);

  my $acceptor_diff;

  if (defined($acceptor_alt_subseq) && $acceptor_alt_subseq =~ /^[ACGT]+$/) {

    ($acceptor_alt_kmer, $acceptor_alt_frame, $acceptor_alt_score) =
      @{$self->get_max_acceptor_score($acceptor_alt_subseq)};

    ($acceptor_ref_kmer, $acceptor_ref_frame, $acceptor_ref_score) =
      @{$self->get_max_acceptor_score($acceptor_ref_subseq)};

    $acceptor_ref_comp_seq = $acceptor_ref_kmer;
    $acceptor_ref_comp_score = $acceptor_ref_score;

    if ($vf->{start} == $vf->{end} && $tva->feature_seq =~ /^[ACGT]$/) {
      $acceptor_ref_comp_seq = substr($acceptor_ref_subseq, $acceptor_alt_frame - 1, 23);
      $acceptor_ref_comp_score = $self->score3($acceptor_ref_comp_seq);
    }

    $acceptor_diff = $acceptor_ref_comp_score - $acceptor_alt_score;
  }

  return {

    # donor values

    "MES-SWA_donor_alt_subseq" => $donor_alt_subseq,
    "MES-SWA_donor_alt_kmer" => $donor_alt_kmer,
    "MES-SWA_donor_alt_frame" => $donor_alt_frame,
    "MES-SWA_donor_alt_score" => $donor_alt_score,

    "MES-SWA_donor_ref_comp_seq" => $donor_ref_comp_seq,
    "MES-SWA_donor_ref_comp_score" => $donor_ref_comp_score,

    "MES-SWA_donor_ref_subseq" => $donor_ref_subseq,
    "MES-SWA_donor_ref_kmer" => $donor_ref_kmer,
    "MES-SWA_donor_ref_frame" => $donor_ref_frame,
    "MES-SWA_donor_ref_score" => $donor_ref_score,

    "MES-SWA_donor_diff" => $donor_diff,

    # acceptor values

    "MES-SWA_acceptor_alt_subseq" => $acceptor_alt_subseq,
    "MES-SWA_acceptor_alt_kmer" => $acceptor_alt_kmer,
    "MES-SWA_acceptor_alt_frame" => $acceptor_alt_frame,
    "MES-SWA_acceptor_alt_score" => $acceptor_alt_score,

    "MES-SWA_acceptor_ref_comp_seq" => $acceptor_ref_comp_seq,
    "MES-SWA_acceptor_ref_comp_score" => $acceptor_ref_comp_score,

    "MES-SWA_acceptor_ref_subseq" => $acceptor_ref_subseq,
    "MES-SWA_acceptor_ref_kmer" => $acceptor_ref_kmer,
    "MES-SWA_acceptor_ref_frame" => $acceptor_ref_frame,
    "MES-SWA_acceptor_ref_score" => $acceptor_ref_score,

    "MES-SWA_acceptor_diff" => $acceptor_diff,
  };
}

sub run_NCSS {
  my ($self, $tva) = @_;

  my $tv = $tva->transcript_variation;
  my $tr = $tva->transcript;

  my ($upstream_donor_seq, $upstream_donor_score);
  my ($upstream_acceptor_seq, $upstream_acceptor_score);

  my ($downstream_donor_seq, $downstream_donor_score);
  my ($downstream_acceptor_seq, $downstream_acceptor_score);

  if ($tv->exon_number && !$tv->intron_number) {

    my ($exon_numbers, $total_exons) = split(/\//, $tv->exon_number);
    my $exon_number = (split(/-/, $exon_numbers))[0];

    my $exons = $tr->get_all_Exons;

    my $exon_idx = $exon_number - 1;
    my $exon = $exons->[$exon_idx];

    # don't calculate upstream scores if the exon is the first in the transcript
    unless ($exon_number == 1) {

      my $upstream_exon = $exons->[$exon_idx - 1];

      my $upstream_donor = $self->slice_donor_site_from_exon($upstream_exon);
      my $upstream_acceptor = $self->slice_acceptor_site_from_exon($exon);

      if (defined($upstream_donor)) {
        $upstream_donor_seq = $upstream_donor->seq();
        $upstream_donor_score = $self->get_donor_score($upstream_donor);
      }
      if (defined($upstream_acceptor)) {
        $upstream_acceptor_seq = $upstream_acceptor->seq();
        $upstream_acceptor_score = $self->get_acceptor_score($upstream_acceptor);
      }
    }

    # don't calculate downstream scores if the exon is the last exon in the transcript
    unless ($exon_number == $total_exons) {

      my $downstream_exon = $exons->[$exon_idx + 1];

      my $downstream_donor = $self->slice_donor_site_from_exon($exon);
      my $downstream_acceptor = $self->slice_acceptor_site_from_exon($downstream_exon);

      if (defined($downstream_donor)) {
        $downstream_donor_seq = $downstream_donor->seq();
        $downstream_donor_score = $self->get_donor_score($downstream_donor);
      }
      if (defined($downstream_acceptor)) {
        $downstream_acceptor_seq = $downstream_acceptor->seq();
        $downstream_acceptor_score = $self->get_acceptor_score($downstream_acceptor);
      }
    }
  }

  if ($tv->intron_number) {

    my ($intron_numbers, $total_introns) = split(/\//, $tv->intron_number);
    my $intron_number = (split(/-/, $intron_numbers))[0];

    my $introns = $tr->get_all_Introns;

    my $intron_idx = $intron_number - 1;
    my $intron = $introns->[$intron_idx];

    my $upstream_donor = $self->slice_donor_site_from_intron($intron);
    my $downstream_acceptor = $self->slice_acceptor_site_from_intron($intron);

    if (defined($upstream_donor)) {
      $upstream_donor_seq = $upstream_donor->seq();
      $upstream_donor_score = $self->get_donor_score($upstream_donor);
    }
    if (defined($downstream_acceptor)) {
      $downstream_acceptor_seq = $downstream_acceptor->seq();
      $downstream_acceptor_score = $self->get_acceptor_score($downstream_acceptor);
    }

    # don't calculate an upstream acceptor score if the intron is the first in the transcript
    unless ($intron_number == 1) {

      my $upstream_intron = $introns->[$intron_idx - 1];
      my $upstream_acceptor = $self->slice_acceptor_site_from_intron($upstream_intron);

      if (defined($upstream_acceptor)) {
        $upstream_acceptor_seq = $upstream_acceptor->seq();
        $upstream_acceptor_score = $self->get_acceptor_score($upstream_acceptor);
      }
    }

    # don't calculate a downstream donor score if the intron is the last in the transcript
    unless ($intron_number == $total_introns) {

      my $downstream_intron = $introns->[$intron_idx + 1];
      my $downstream_donor = $self->slice_donor_site_from_intron($downstream_intron);

      if (defined($downstream_donor)) {
        $downstream_donor_seq = $downstream_donor->seq();
        $downstream_donor_score = $self->get_donor_score($downstream_donor);
      }
    }
  }

  return {
    "MES-NCSS_upstream_donor_seq" => $upstream_donor_seq,
    "MES-NCSS_upstream_donor_score" => $upstream_donor_score,
    "MES-NCSS_downstream_donor_seq" => $downstream_donor_seq,
    "MES-NCSS_downstream_donor_score" => $downstream_donor_score,

    "MES-NCSS_upstream_acceptor_seq" => $upstream_acceptor_seq,
    "MES-NCSS_upstream_acceptor_score" => $upstream_acceptor_score,
    "MES-NCSS_downstream_acceptor_seq" => $downstream_acceptor_seq,
    "MES-NCSS_downstream_acceptor_score" => $downstream_acceptor_score,
  };
}


## Sliding window approach methods
##################################

sub get_max_donor_score {
  my ($self, $donor_sequence) = @_;

  my ($donor_kmer, $donor_frame, $donor_score);
  my @kmers = @{$self->sliding_window($donor_sequence, 9)};

  for my $i (0 .. $#kmers) {
    my $kmer = $kmers[$i];
    my $score = $self->score5($kmer);
    if(!$donor_score || $score > $donor_score) {
      $donor_kmer = $kmer;
      $donor_frame = $i + 1;
      $donor_score = $score;
    }
  }
  return [$donor_kmer, $donor_frame, $donor_score];
}

sub get_max_acceptor_score {
  my ($self, $acceptor_sequence) = @_;

  my ($acceptor_kmer, $acceptor_frame, $acceptor_score);
  my @kmers = @{$self->sliding_window($acceptor_sequence, 23)};

  for my $i (0 .. $#kmers) {
    my $kmer = $kmers[$i];
    my $score = $self->score3($kmer);
    if(!$acceptor_score || $score > $acceptor_score) {
      $acceptor_kmer = $kmer;
      $acceptor_frame = $i + 1;
      $acceptor_score = $score;
    }
  }
  return [$acceptor_kmer, $acceptor_frame, $acceptor_score];
}

sub sliding_window {
  my ($self, $sequence, $winsize) = @_;
  my @seqs;
  for (my $i = 1; $i <= length($sequence) - $winsize + 1; $i++) {
    push @seqs, substr($sequence, $i - 1, $winsize);
  }
  return \@seqs;
}


## Nearest canonical splice site methods
########################################

sub slice_donor_site_from_exon {
  my ($self, $exon) = @_;

  my ($start, $end);

  if ($exon->strand > 0) {
    ($start, $end) = ($exon->end - 2, $exon->end + 6);
  }
  else {
    ($start, $end) = ($exon->start - 6, $exon->start + 2);
  }

  return $exon->slice()->sub_Slice($start, $end, $exon->strand);
}

sub slice_acceptor_site_from_exon {
  my ($self, $exon) = @_;

  my ($start, $end);

  if ($exon->strand > 0) {
    ($start, $end) = ($exon->start - 20, $exon->start + 2);
  }
  else {
    ($start, $end) = ($exon->end - 2, $exon->end + 20);
  }

  return $exon->slice()->sub_Slice($start, $end, $exon->strand);
}

sub slice_donor_site_from_intron {
  my ($self, $intron) = @_;

  my ($start, $end);

  if ($intron->strand > 0) {
    ($start, $end) = ($intron->start - 3, $intron->start + 5);
  }
  else {
    ($start, $end) = ($intron->end - 5, $intron->end + 3);
  }

  return $intron->slice()->sub_Slice($start, $end, $intron->strand);
}

sub slice_acceptor_site_from_intron {
  my ($self, $intron) = @_;

  my ($start, $end);

  if ($intron->strand > 0) {
    ($start, $end) = ($intron->end - 19, $intron->end + 3);
  }
  else {
    ($start, $end) = ($intron->start - 3, $intron->start + 19);
  }

  return $intron->slice()->sub_Slice($start, $end, $intron->strand);
}

sub get_donor_score {
  my ($self, $slice) = @_;

  my $seq = $slice->seq();
  my $score = $self->score5($seq) if $seq =~ /^[ACGT]+$/;

  return $score;
}

sub get_acceptor_score {
  my ($self, $slice) = @_;

  my $seq = $slice->seq();
  my $score = $self->score3($seq) if $seq =~ /^[ACGT]+$/;

  return $score;
}


## Common methods
#################

sub get_seqs {
  my ($self, $tva, $start, $end) = @_;
  my $vf = $tva->variation_feature;

  my $tr_strand = $tva->transcript->strand;

  my $ref_slice = $vf->{slice}->sub_Slice($start, $end, $tr_strand);

  my ($ref_seq, $alt_seq);

  if (defined $ref_slice) {

    $ref_seq = $alt_seq = $ref_slice->seq();

    my $substr_start = $tr_strand > 0 ? $vf->{start} - $start : $end - $vf->{end};
    my $feature_seq = $tva->seq_length > 0 ? $tva->feature_seq : '';

    substr($alt_seq, $substr_start, ($vf->{end} - $vf->{start}) + 1) = $feature_seq;
  }

  return [$ref_seq, $alt_seq];
}

sub score5 {
  my $self = shift;
  my $seq = shift;
  my $hex = md5_hex($seq);

  # check cache
  if($self->{cache}) {
    my ($res) = grep {$_->{hex} eq $hex} @{$self->{cache}->{score5}};

    return $res->{score} if $res; 
  }

  my $a = $self->score5_scoreconsensus($seq);
  die("ERROR: No score5_scoreconsensus\n") unless defined($a);

  my $b = $self->score5_getrest($seq);
  die("ERROR: No score5_getrest\n") unless defined($b);

  my $c = $self->{'score5_seq'}->{$b};
  die("ERROR: No score5_seq for $b\n") unless defined($c);

  my $d = $self->{'score5_me2x5'}->{$c};
  die("ERROR: No score5_me2x5 for $c\n") unless defined($d);

  my $score = $self->log2($a * $d);

  # cache it
  push @{$self->{cache}->{score5}}, { hex => $hex, score => $score };
  shift @{$self->{cache}->{score5}} while scalar @{$self->{cache}->{score5}} > $CACHE_SIZE;

  return $score;
}

sub score3 {
  my $self = shift;
  my $seq = shift;
  my $hex = md5_hex($seq);

  # check cache
  if($self->{cache}) {
    my ($res) = grep {$_->{hex} eq $hex} @{$self->{cache}->{score3}};

    return $res->{score} if $res; 
  }

  my $a = $self->score3_scoreconsensus($seq);
  die("ERROR: No score3_scoreconsensus\n") unless defined($a);

  my $b = $self->score3_getrest($seq);
  die("ERROR: No score3_getrest\n") unless defined($b);

  my $c = $self->score3_maxentscore($b, $self->{'score3_metables'});
  die("ERROR: No score3_maxentscore for $b\n") unless defined($c);

  my $score = $self->log2($a * $c);

  # cache it
  push @{$self->{cache}->{score3}}, { hex => $hex, score => $score };
  shift @{$self->{cache}->{score3}} while scalar @{$self->{cache}->{score3}} > $CACHE_SIZE;

  return $score;
}


## methods copied from score5.pl
################################

sub score5_makesequencematrix {
  my $self = shift;
  my $file = shift;
  my %matrix;
  my $n=0;
  open(SCOREF, $file) || die "Can't open $file!\n";
  while(<SCOREF>) { 
    chomp;
    $_=~ s/\s//;
    $matrix{$_} = $n;
    $n++;
  }
  close(SCOREF);
  return \%matrix;
}

sub score5_makescorematrix {
  my $self = shift;
  my $file = shift;
  my %matrix;
  my $n=0;
  open(SCOREF, $file) || die "Can't open $file!\n";
  while(<SCOREF>) { 
    chomp;
    $_=~ s/\s//;
    $matrix{$n} = $_;
    $n++;
  }
  close(SCOREF);
  return \%matrix;
}

sub score5_getrest {
  my $self = shift;
  my $seq = shift;
  my @seqa = split(//,uc($seq));
  return $seqa[0].$seqa[1].$seqa[2].$seqa[5].$seqa[6].$seqa[7].$seqa[8];
}

sub score5_scoreconsensus {
  my $self = shift;
  my $seq = shift;
  my @seqa = split(//,uc($seq));
  my %bgd; 
  $bgd{'A'} = 0.27; 
  $bgd{'C'} = 0.23; 
  $bgd{'G'} = 0.23; 
  $bgd{'T'} = 0.27;  
  my %cons1;
  $cons1{'A'} = 0.004;
  $cons1{'C'} = 0.0032;
  $cons1{'G'} = 0.9896;
  $cons1{'T'} = 0.0032;
  my %cons2;
  $cons2{'A'} = 0.0034; 
  $cons2{'C'} = 0.0039; 
  $cons2{'G'} = 0.0042; 
  $cons2{'T'} = 0.9884;
  my $addscore = $cons1{$seqa[3]}*$cons2{$seqa[4]}/($bgd{$seqa[3]}*$bgd{$seqa[4]}); 
  return $addscore;
}

sub log2 {
  my ($self, $val) = @_;
  return log($val)/log(2);
}


## methods copied from score3.pl
################################

sub score3_hashseq {
  #returns hash of sequence in base 4
  # $self->score3_hashseq('CAGAAGT') returns 4619
  my $self = shift;
  my $seq = shift;
  $seq = uc($seq);
  $seq =~ tr/ACGT/0123/;
  my @seqa = split(//,$seq);
  my $sum = 0;
  my $len = length($seq);
  my @four = (1,4,16,64,256,1024,4096,16384);
  my $i=0;
  while ($i<$len) {
    $sum+= $seqa[$i] * $four[$len - $i -1] ;
    $i++;
  }
  return $sum;
}

sub score3_makemaxentscores {
  my $self = shift;
  my $dir = $self->{'_dir'}."/splicemodels/";
  my @list = ('me2x3acc1','me2x3acc2','me2x3acc3','me2x3acc4',
    'me2x3acc5','me2x3acc6','me2x3acc7','me2x3acc8','me2x3acc9');
  my @metables;
  my $num = 0 ;
  foreach my $file (@list) {
    my $n = 0;
    open (SCOREF,"<".$dir.$file) || die "Can't open $file!\n";
    while(<SCOREF>) {
      chomp;
      $_=~ s/\s//;
      $metables[$num]{$n} = $_;
      $n++;
    }
    close(SCOREF);
    #print STDERR $file."\t".$num."\t".$n."\n";
    $num++;
  }
  return \@metables;
}

sub score3_maxentscore {
  my $self = shift;
  my $seq = shift;
  my $table_ref = shift;
  my @metables = @$table_ref;
  my @sc;
  $sc[0] = $metables[0]{$self->score3_hashseq(substr($seq,0,7))};
  $sc[1] = $metables[1]{$self->score3_hashseq(substr($seq,7,7))};
  $sc[2] = $metables[2]{$self->score3_hashseq(substr($seq,14,7))};
  $sc[3] = $metables[3]{$self->score3_hashseq(substr($seq,4,7))};
  $sc[4] = $metables[4]{$self->score3_hashseq(substr($seq,11,7))};
  $sc[5] = $metables[5]{$self->score3_hashseq(substr($seq,4,3))};
  $sc[6] = $metables[6]{$self->score3_hashseq(substr($seq,7,4))};
  $sc[7] = $metables[7]{$self->score3_hashseq(substr($seq,11,3))};
  $sc[8] = $metables[8]{$self->score3_hashseq(substr($seq,14,4))};
  my $finalscore = $sc[0] * $sc[1] * $sc[2] * $sc[3] * $sc[4] / ($sc[5] * $sc[6] * $sc[7] * $sc[8]);
  return $finalscore;
}

sub score3_getrest {
  my $self = shift;
  my $seq = shift;
  my $seq_noconsensus = substr($seq,0,18).substr($seq,20,3);
  return $seq_noconsensus;
}

sub score3_scoreconsensus {
  my $self = shift;
  my $seq = shift;
  my @seqa = split(//,uc($seq));
  my %bgd; 
  $bgd{'A'} = 0.27; 
  $bgd{'C'} = 0.23; 
  $bgd{'G'} = 0.23; 
  $bgd{'T'} = 0.27;  
  my %cons1;
  $cons1{'A'} = 0.9903;
  $cons1{'C'} = 0.0032;
  $cons1{'G'} = 0.0034;
  $cons1{'T'} = 0.0030;
  my %cons2;
  $cons2{'A'} = 0.0027; 
  $cons2{'C'} = 0.0037; 
  $cons2{'G'} = 0.9905; 
  $cons2{'T'} = 0.0030;
  my $addscore = $cons1{$seqa[18]} * $cons2{$seqa[19]}/ ($bgd{$seqa[18]} * $bgd{$seqa[19]}); 
  return $addscore;
}

1;

