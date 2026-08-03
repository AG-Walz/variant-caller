#!/usr/bin/env bash
#
# build_bed.sh — combine any number of capture-kit BED files into the ONE target BED that
# sarek scatters its variant calling over.
#
#   usage:  [PAD=30] ./scripts/build_bed.sh [<bed-file|url> ...]
#
# With no arguments it rebuilds the pilot's target from the two Twist Bioscience files the
# sequencing vendor's kit was ordered from. With arguments it does the same for any other
# kit, mixing local paths and URLs freely:
#
#   PAD=50 ./scripts/build_bed.sh mypanel.bed https://vendor.example/exome.bed
#
# WHY THIS IS NOT JUST `cat`: a target BED handed to sarek has three properties it must
# have, and every one of them fails expensively rather than loudly if you get it wrong.
# Each is enforced by one stage of the pipeline below. Read the four-stage comment.

set -euo pipefail          # see setup.sh for what these three do
cd "$(dirname "$0")/.."    # all paths below are relative to the repo root

# --- inputs -----------------------------------------------------------------------------

# Padding, in bases, added to BOTH ends of every target region. Probes do not stop capturing
# at the exact target boundary, so reads spill either side; without padding you lose splice-
# site and near-boundary variants. 30 bp is not a guess: it is the sequencing vendor's own
# DRAGEN setting, and their reported coverage territory matches ours to 0.07 %. Changing it
# ends comparability with their calls, so it is a deliberate choice, not a tuning knob.
# "${PAD:-30}" means "the environment variable PAD, or 30 if it is unset or empty".
PAD="${PAD:-30}"

# The .fai downloaded by setup.sh. It is a plain table of contig name, length and offsets,
# and it is used twice below — once as an ORDER and once as a set of contig LENGTHS.
FAI=references/Homo_sapiens_assembly38.fasta.fai

# The padding travels in the filename. That is on purpose: params/pilot.yaml names the file
# it wants, so the BED on disk and the parameter that selects it cannot drift apart silently
# — a mismatch is a missing path, and nf-schema aborts the run at launch.
OUT="references/target_pad${PAD}.bed"

# Default sources: the exome target plus the mitochondrial panel. chrM is deliberately IN —
# the mito panel was part of the ordered kit and the vendor's own calls include chrM records.
T=https://www.twistbioscience.com/content/dam/twistbioscience/resources
# `[ $# -gt 0 ] ||` = "if the caller passed no arguments, then". `set --` replaces the
# argument list, so the loop below reads either the caller's sources or these two.
[ $# -gt 0 ] || set -- "$T/2019-09/Twist_Exome_RefSeq_targets_hg38.bed" \
                       "$T/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed"

# --- the four stages --------------------------------------------------------------------
#
# concatenate -> sort -faidx -> merge -> slop -> merge, streamed, nothing hits disk until
# the final redirect. What each stage is FOR:
#
# 1. sort -faidx $FAI
#    Sorts the rows into the REFERENCE's contig order, the order the .fai lists them in —
#    NOT alphabetical. This is the single most expensive mistake available here. Plain
#    `sort -k1,1`, and `bedtools sort` WITHOUT -faidx, both put chr19 before chr2 and chrM
#    before chrX. sarek feeds --intervals to GATK in the order given, and GATK's
#    GatherPileupSummaries assumes sequence-dictionary order, so a name-ordered BED runs
#    happily for about 30 minutes and then dies inside CalculateContamination. `sort -V`
#    is not a fix either: it is still name order, just a smarter one.
#
# 2. merge (first pass)
#    Collapses overlapping and book-ended regions. Kit BEDs overlap themselves, and two
#    kits concatenated overlap each other; without this, padding would be applied to
#    regions that are about to be merged anyway, and the region count would be inflated.
#    Note merge also emits exactly THREE columns, which is a requirement in its own right:
#    sarek's create_intervals_bed reads column 5 as a per-region runtime estimate, so a
#    6-column BED produced 107,247 scatter shards instead of 83.
#
# 3. slop -b $PAD -g $FAI
#    Adds PAD bases to both ends. -g gives it the contig LENGTHS from the same .fai, which
#    is what clamps padding at the ends of a contig instead of running off the end into
#    coordinates that do not exist. Dropping -g is silently wrong near every contig end.
#
# 4. merge (second pass)
#    Padding makes previously separate regions touch or overlap — adjacent exons 40 bp
#    apart become one region at PAD=30. Without this second merge the output contains
#    overlapping intervals, and overlapping intervals mean the same variant is called
#    twice in two different shards.
#
# The result is a FIXED POINT: re-running sort|merge|slop -b 0 over the output reproduces
# it byte for byte. That property is the sanity check documented in the README.
for src in "$@"; do
    # A source is either a URL to stream or a file on disk to read. -sL = silent, and
    # follow redirects (the vendor's links redirect). Everything is concatenated into
    # one stream by the pipe on the `done` line.
    case "$src" in
        http*) curl -sL "$src" ;;
        *)     cat "$src" ;;
    esac
done | bedtools sort -faidx "$FAI" \
     | bedtools merge -i - \
     | bedtools slop -i - -g "$FAI" -b "$PAD" \
     | bedtools merge -i - > "$OUT"

# --- report -----------------------------------------------------------------------------
#
# Region count and total territory, so a bad build is obvious immediately: $3-$2 is each
# region's length, NR is the number of rows awk has seen when it reaches END.
awk -v f="$OUT" '{s += $3 - $2} END {print f": "NR" regions, "s" bp"}' "$OUT"

# The md5 is the real check. The pilot's canonical target, from the two default sources at
# PAD=30, is 214,494 regions / 49,633,134 bp / 69ed88c5131c8613efe5e20e66954e74. If you
# rebuilt the default and got a different digest, the vendor changed a file — stop and find
# out why before calling variants against it.
md5sum "$OUT"

echo "point intervals: in params/pilot.yaml at $OUT"
