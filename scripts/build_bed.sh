#!/usr/bin/env bash
#
# build_bed.sh — combine capture-kit BED files into the ONE target BED that sarek scatters
# its variant calling over.
#
#   usage: build_bed.sh <reference.fai> <padding-bp> <output.bed> <source> [<source> ...]
#
# A <source> is a path to a BED file or a URL to one; mix them freely, in any number. Nothing
# is hardcoded and nothing is assumed: you say which kit files, which reference, how much
# padding and where the result goes. Two examples, one local and one from a vendor's site:
#
#   ./scripts/build_bed.sh refs/hg38.fa.fai 30 refs/target.bed exome.bed mito.bed
#   ./scripts/build_bed.sh refs/hg38.fa.fai 30 refs/target.bed https://vendor/a.bed https://vendor/b.bed
#
# WHY THIS IS NOT JUST `cat`: a target BED handed to sarek has three properties it must have,
# and every one of them fails expensively rather than loudly if you get it wrong. Each is
# established by one stage of the pipeline below — read the four-stage comment.

# Long-form names for what `set -euo pipefail` means, because the short flags are unreadable:
#   errexit   stop at the first failing command, instead of carrying on with a half-built BED
#   nounset   a misspelled variable is an error, not a silently empty string
#   pipefail  a failure ANYWHERE in a | pipeline fails the whole pipeline. Without this, a
#             curl that 404s still leaves you with a plausible-looking BED built from the
#             other sources, which is exactly the kind of wrong that reaches a variant call.
set -o errexit -o nounset -o pipefail

# --- arguments --------------------------------------------------------------------------
#
# No defaults anywhere. $# is the number of arguments; four is the minimum (reference,
# padding, output, and at least one source).
if [ $# -lt 4 ]; then
    echo "usage: $0 <reference.fai> <padding-bp> <output.bed> <source> [<source> ...]" >&2
    echo "  <source> is a path to a BED file or a URL to one" >&2
    exit 1
fi

# The .fai of the reference FASTA — a table of contig name, length and offsets. It is used
# twice below, once as an ORDER and once as a set of contig LENGTHS, and it must be the .fai
# of the exact FASTA you will call against.
FAI=$1

# Padding, in bases, added to BOTH ends of every target region. Probes do not stop capturing
# at the exact target boundary, so reads spill either side; without padding you lose
# splice-site and near-boundary variants. For this cohort it is 30, because that is the
# sequencing vendor's own DRAGEN setting and their reported coverage territory then matches
# ours to 0.07 % — changing it ends comparability with their calls.
PAD=$2

# Where to write. Put the padding in the name (target_pad30.bed): params/pilot.yaml names the
# file it wants, so a BED built at a different padding cannot be picked up silently — it is a
# missing path, and nf-schema aborts the run at launch.
OUT=$3

# `shift 3` drops those three, leaving "$@" as exactly the list of sources.
shift 3

# --- the four stages --------------------------------------------------------------------
#
# concatenate -> sort -faidx -> merge -> slop -> merge, streamed: nothing touches disk until
# the final redirect. What each stage is FOR:
#
# 1. sort -faidx "$FAI"
#    Sorts the rows into the REFERENCE's contig order — the order the .fai lists them in, NOT
#    alphabetical. This is the single most expensive mistake available here. Plain `sort
#    -k1,1`, and `bedtools sort` WITHOUT -faidx, both put chr19 before chr2 and chrM before
#    chrX. sarek feeds --intervals to GATK in the order given, and GATK's
#    GatherPileupSummaries assumes sequence-dictionary order, so a name-ordered BED runs
#    happily for about 30 minutes and then dies inside CalculateContamination. `sort -V` is
#    not a fix either: it is still name order, just a smarter one.
#
# 2. merge (first pass)
#    Collapses overlapping and book-ended regions. Kit BEDs overlap themselves, and two kits
#    concatenated overlap each other; without this, padding would be applied to regions that
#    are about to be merged anyway. merge also emits exactly THREE columns, which is a
#    requirement in its own right: sarek's create_intervals_bed reads column 5 as a
#    per-region runtime estimate, so a 6-column BED produced 107,247 scatter shards
#    instead of 83.
#
# 3. slop -b "$PAD" -g "$FAI"
#    Adds PAD bases to both ends. -g gives it the contig LENGTHS from the same .fai, which is
#    what clamps padding at the end of a contig instead of running off into coordinates that
#    do not exist. Dropping -g is silently wrong near every contig end.
#
# 4. merge (second pass)
#    Padding makes previously separate regions touch — adjacent exons 40 bp apart become one
#    region at PAD=30. Without this second merge the output contains overlapping intervals,
#    and overlapping intervals mean the same variant is called twice in two different shards.
#
# The result is a FIXED POINT: re-running sort|merge|slop -b 0 over the output reproduces it
# byte for byte. That property is the sanity check documented in the README.
for src in "$@"; do
    # A source is either a URL to stream or a file to read. -sL = silent, and follow
    # redirects. Everything is concatenated into one stream by the pipe on the `done` line.
    case "$src" in
        http://*|https://*) curl -sSL --fail "$src" ;;
        *)                  cat "$src" ;;
    esac
done | bedtools sort -faidx "$FAI" \
     | bedtools merge -i - \
     | bedtools slop -i - -g "$FAI" -b "$PAD" \
     | bedtools merge -i - > "$OUT"

# --- report -------------------------------------------------------------------------------
#
# Region count and total territory, so a bad build is obvious immediately: $3-$2 is each
# region's length, and NR is the number of rows awk has seen when it reaches END.
awk -v f="$OUT" '{s += $3 - $2} END {print f": "NR" regions, "s" bp"}' "$OUT"

# The md5 is the real check — compare it against the one your last good run used. This
# cohort's target, from the two Twist kit files at padding 30, is 214,494 regions /
# 49,633,134 bp / 69ed88c5131c8613efe5e20e66954e74. A changed digest on unchanged inputs
# means a vendor edited a file: find out why before calling variants against it.
md5sum "$OUT"
