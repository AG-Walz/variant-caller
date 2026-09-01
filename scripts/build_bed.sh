#!/usr/bin/env bash
# Build a single BED file from multiple capture kit BED files.
# Requires bedtools.

BEDS="references/kit1.bed references/kit2.bed"      # one or more, from your capture kit vendor
FAI=references/Homo_sapiens_assembly38.fasta.fai    # index reference genome from which to call against
PADDING=30                                          # bases added to either side of every region
OUTPUT=references/target_pad30.bed                  # output file for the merged and padded regions
                                                    # point --intervals in run.sh at this file

cat ${BEDS} | # Concatenate bed files
  # Sort into the reference's own contig order (index-mapped)
  bedtools sort -faidx ${FAI} |
  # fuse overlapping regions between kits, and emits a 3 column bed file
  bedtools merge |
  # -g clamps padding to contig ends
  bedtools slop -g ${FAI} -b ${PADDING} |
  # re-collapse whatever padding pushed together
  bedtools merge > ${OUTPUT}

# Print the number of regions and total base pairs in the output file
awk '{n++; s+=$3-$2} END {print FILENAME": "n" regions, "s" bp"}' ${OUTPUT}
