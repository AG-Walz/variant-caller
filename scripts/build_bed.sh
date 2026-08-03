#!/usr/bin/env bash
# Download your capture kit's BED files, list them in BEDS, edit the rest, run it. Needs bedtools.

BEDS="references/Twist_Exome_RefSeq_targets_hg38.bed references/Twist_MitoPanel_chrM_all_hg38_target.bed"
FAI=references/Homo_sapiens_assembly38.fasta.fai   # of the genome you will call against
PADDING=30                                         # bases added either side of every region
OUTPUT=references/target_pad30.bed                 # point --intervals in run.sh at this

# sort -faidx puts the regions in the reference's contig order — lexicographic order runs for
# ~30 minutes and then dies in GATK's CalculateContamination. merge collapses the overlaps two
# kits share, and emits the 3 columns sarek requires. slop -g clamps padding to contig ends.
# The second merge re-collapses whatever padding pushed together.
cat ${BEDS} \
  | bedtools sort -faidx ${FAI} \
  | bedtools merge \
  | bedtools slop -g ${FAI} -b ${PADDING} \
  | bedtools merge \
  > ${OUTPUT}

awk '{n++; s+=$3-$2} END {print FILENAME": "n" regions, "s" bp"}' ${OUTPUT}
