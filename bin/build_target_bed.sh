#!/usr/bin/env bash
#
# build_target_bed.sh — target-BED pre-flight tool for variant-caller v1.
#
# Turns a DRAGEN *.target.counts.gc-corrected.gz file into the 3-column,
# padded, merged interval BED that sarek consumes via --intervals.
#
# Why 3 columns EXACTLY: sarek's create_intervals_bed reads column 5 of the
# --intervals file as a per-region RUNTIME-SECONDS estimate. Any extra column
# silently corrupts the scatter, so we emit contig/start/stop and nothing else.
#
# Pure awk + coreutils. No bedtools (not installed on the target box).
#
# Usage:
#   build_target_bed.sh <counts.gc-corrected.gz> <output.bed> --fai <ref.fai> [--pad N]
#     --fai F   REQUIRED. reference .fai; defines the output's contig ORDER.
#     --pad N   symmetric slop applied to each region, in bp (default 30)
#
# Algorithm (verified to reproduce the DRAGEN target set exactly):
#   1. zcat the counts file, drop the 5 header lines (tail -n +6), keep cols 1-3.
#   2. sort by the REFERENCE's contig order (from the .fai), then numeric start.
#      NOT lexicographic: `sort -k1,1` puts chr19 before chr2 and chrM before
#      chrX, and sarek/GATK read --intervals in the order given -- see
#      bin/lib_bed.sh for the failure this caused. (`sort -V` is not a fix.)
#   3. MERGE: group by exact contig; extend the running end; a new region
#      starts only when the contig changes or start > current end (so
#      position-adjacent intervals, start == end, merge).  -> "no-slop" target.
#   4. Apply +pad slop each side (clamp start at 0), re-sort, RE-MERGE.
#   5. Emit exactly 3 columns, then assert order/bounds before writing.
#
# For --pad 30 the region/bp checksums are asserted and a mismatch is a hard
# error (guards against a changed/wrong input file). For any other pad the
# assert is skipped but counts are still printed.

set -euo pipefail

# Deterministic sort/collation regardless of the caller's locale.
export LC_ALL=C

# shellcheck source=bin/lib_bed.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_bed.sh"

# --- expected checksums for the canonical pad=30 pre-flight -----------------
EXP_NOSLOP_REGIONS=215624
EXP_NOSLOP_BP=36731644
EXP_PAD30_REGIONS=214494
EXP_PAD30_BP=49633029

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    printf 'Usage: %s <counts.gc-corrected.gz> <output.bed> --fai <ref.fai> [--pad N (default 30)]\n' \
        "$(basename "$0")" >&2
    exit 2
}

# --- parse args -------------------------------------------------------------
INPUT=""
OUTPUT=""
FAI=""
PAD=30
while [ $# -gt 0 ]; do
    case "$1" in
        --fai)
            [ $# -ge 2 ] || die "--fai requires a value"
            FAI="$2"
            shift 2
            ;;
        --fai=*)
            FAI="${1#--fai=}"
            shift
            ;;
        --pad)
            [ $# -ge 2 ] || die "--pad requires a value"
            PAD="$2"
            shift 2
            ;;
        --pad=*)
            PAD="${1#--pad=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        --*)
            die "unknown option: $1"
            ;;
        *)
            if [ -z "$INPUT" ]; then
                INPUT="$1"
            elif [ -z "$OUTPUT" ]; then
                OUTPUT="$1"
            else
                die "unexpected extra argument: $1"
            fi
            shift
            ;;
    esac
done

[ -n "$INPUT" ] && [ -n "$OUTPUT" ] || usage
[ -f "$INPUT" ] || die "input file not found: $INPUT"
# --fai is mandatory: it defines the contig ORDER sarek/GATK require. Emitting a
# lexicographically ordered BED is what broke the first pilot run (see lib_bed.sh).
[ -n "$FAI" ] || die "--fai is required: it defines the output's contig order.
       Pass --fai <reference>.fasta.fai (e.g. references/Homo_sapiens_assembly38.fasta.fai)."
[ -f "$FAI" ] || die "--fai file not found: $FAI"
case "$PAD" in
    ''|*[!0-9]*) die "--pad must be a non-negative integer, got: $PAD" ;;
esac

# awk merge program shared by both stages: reads sorted 3-col, merges by contig.
MERGE_AWK='
BEGIN { OFS="\t" }
{
    c=$1; s=$2; e=$3;
    if (NR==1 || c!=pc || s>pe) {
        if (NR>1) print pc, ps, pe;
        pc=c; ps=s; pe=e;
    } else if (e>pe) {
        pe=e;
    }
}
END { if (NR>0) print pc, ps, pe }
'

TMPDIR_WORK="$(mktemp -d "${TMPDIR:-/tmp}/build_target_bed.XXXXXX")"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
NOSLOP="$TMPDIR_WORK/noslop.bed"

# --- stage 1: no-slop target ------------------------------------------------
zcat "$INPUT" \
    | tail -n +6 \
    | cut -f1-3 \
    | bed_sort_by_fai "$FAI" \
    | awk "$MERGE_AWK" > "$NOSLOP"

read -r NOSLOP_REGIONS NOSLOP_BP < <(
    awk '{ n++; bp += $3 - $2 } END { print n+0, bp+0 }' "$NOSLOP"
)
printf 'no-slop : %s regions / %s bp\n' "$NOSLOP_REGIONS" "$NOSLOP_BP" >&2

# --- stage 2: +pad slop, re-merge ------------------------------------------
awk -v pad="$PAD" 'BEGIN{OFS="\t"} { s=$2-pad; if(s<0)s=0; print $1, s, $3+pad }' "$NOSLOP" \
    | bed_sort_by_fai "$FAI" \
    | awk "$MERGE_AWK" > "$OUTPUT"

read -r PAD_REGIONS PAD_BP < <(
    awk '{ n++; bp += $3 - $2 } END { print n+0, bp+0 }' "$OUTPUT"
)
printf '+%s slop: %s regions / %s bp\n' "$PAD" "$PAD_REGIONS" "$PAD_BP" >&2

# Hard gate: 3 columns, reference contig order, in-bounds, non-overlapping.
bed_assert_fai_sorted "$FAI" "$OUTPUT" || die "refusing to emit $OUTPUT"

# --- checksum assert (canonical pad=30 only) --------------------------------
if [ "$PAD" -eq 30 ]; then
    if [ "$NOSLOP_REGIONS" != "$EXP_NOSLOP_REGIONS" ] || [ "$NOSLOP_BP" != "$EXP_NOSLOP_BP" ]; then
        die "no-slop checksum mismatch: got ${NOSLOP_REGIONS}/${NOSLOP_BP} bp, expected ${EXP_NOSLOP_REGIONS}/${EXP_NOSLOP_BP} bp (wrong or changed input?)"
    fi
    if [ "$PAD_REGIONS" != "$EXP_PAD30_REGIONS" ] || [ "$PAD_BP" != "$EXP_PAD30_BP" ]; then
        die "+30 slop checksum mismatch: got ${PAD_REGIONS}/${PAD_BP} bp, expected ${EXP_PAD30_REGIONS}/${EXP_PAD30_BP} bp (wrong or changed input?)"
    fi
    printf 'OK: target BED built and checksums verified -> %s | no-slop %s regions/%s bp | +30 slop %s regions/%s bp\n' \
        "$OUTPUT" "$NOSLOP_REGIONS" "$NOSLOP_BP" "$PAD_REGIONS" "$PAD_BP" >&2
else
    printf 'OK: target BED built (pad=%s, checksum assert skipped) -> %s | no-slop %s regions/%s bp | +%s slop %s regions/%s bp\n' \
        "$PAD" "$OUTPUT" "$NOSLOP_REGIONS" "$NOSLOP_BP" "$PAD" "$PAD_REGIONS" "$PAD_BP" >&2
fi
