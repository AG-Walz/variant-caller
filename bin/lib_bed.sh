#!/usr/bin/env bash
#
# lib_bed.sh — shared BED ordering + validation for the target-BED builders.
#
# WHY THIS EXISTS (2026-07-27, pilot blocker):
# `sort -k1,1` orders contig NAMES as strings, which puts chr19 before chr2 and
# chrM before chrX. sarek reads --intervals rows IN THE ORDER GIVEN and GATK's
# GatherPileupSummaries assumes the resulting shards are in sequence-dictionary
# order, so a lexicographically sorted BED produces a gathered pileup table whose
# records run backwards and CalculateContamination dies with:
#     Invalid interval. Contig:chr22 start:42062823 end:40827186
# The only safe contig order is the one in the reference .fai. Note that
# `sort -V` is NOT a fix: it still places chrM before chrX.
#
# Source this file; do not execute it.
#
# Pure awk + coreutils, per the dependency-light rule in CLAUDE.md.

# Order BED rows by the reference's contig order (.fai row order), then by
# numeric start. Reads stdin, writes stdout. Fails if a contig is not in the .fai.
bed_sort_by_fai() {
    local fai="$1"
    awk -F'\t' -v OFS='\t' '
        NR==FNR { rank[$1]=FNR; next }
        !($1 in rank) {
            printf "ERROR: BED contig %s is not in the reference .fai\n", $1 > "/dev/stderr"
            exit 1
        }
        { print rank[$1], $0 }
    ' "$fai" - \
        | LC_ALL=C sort -k1,1n -k3,3n \
        | cut -f2-
}

# Hard gate: a BED that passes this cannot trip the scatter-gather bug.
# Asserts exactly 3 columns, known contigs, 0 <= start < end <= contig length,
# non-decreasing .fai order, and no overlapping/adjacent (unmerged) regions.
bed_assert_fai_sorted() {
    local fai="$1" bed="$2"
    awk -F'\t' '
        NR==FNR { rank[$1]=FNR; len[$1]=$2+0; next }
        {
            if (NF != 3) {
                printf "line %d: %d columns, must be exactly 3 (sarek reads col 5 as a runtime estimate)\n", FNR, NF > "/dev/stderr"
                bad=1; next
            }
            c=$1; s=$2+0; e=$3+0
            if (!(c in rank)) {
                printf "line %d: contig %s is not in the reference .fai\n", FNR, c > "/dev/stderr"
                bad=1; next
            }
            if (s < 0 || e <= s || e > len[c]) {
                printf "line %d: %s:%d-%d is out of bounds (contig length %d)\n", FNR, c, s, e, len[c] > "/dev/stderr"
                bad=1
            }
            r=rank[c]
            if (seen && (r < pr || (r == pr && s < ps))) {
                printf "line %d: contig order goes backwards: %s:%d follows %s:%d\n", FNR, c, s, pc, ps > "/dev/stderr"
                bad=1
            }
            if (seen && r == pr && s <= pe) {
                printf "line %d: unmerged overlap: %s:%d-%d follows %s:%d-%d\n", FNR, c, s, e, pc, ps, pe > "/dev/stderr"
                bad=1
            }
            seen=1; pr=r; ps=s; pe=e; pc=c
        }
        END { if (bad) exit 1 }
    ' "$fai" "$bed" || {
        printf 'ERROR: %s is not a valid sarek --intervals BED (see above).\n' "$bed" >&2
        return 1
    }
}
