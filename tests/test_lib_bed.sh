#!/usr/bin/env bash
#
# test_lib_bed.sh — regression guard for the contig-ordering bug that broke the
# first pilot run (2026-07-27).
#
# A lexicographically sorted BED (chr19 before chr2, chrM before chrX) makes
# sarek scatter intervals out of sequence-dictionary order, and GATK's
# CalculateContamination then dies on a reversed interval. These tests pin the
# ordering contract of bin/lib_bed.sh using tiny synthetic fixtures, so they run
# on any box with no reference, no counts file and no bedtools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../bin/lib_bed.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_lib_bed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$LIB" ] || { printf 'FAIL: lib not found: %s\n' "$LIB"; exit 1; }
if bash -n "$LIB"; then ok "bin/lib_bed.sh parses clean (bash -n)"; else bad "bin/lib_bed.sh has syntax errors"; fi

# shellcheck source=../bin/lib_bed.sh
. "$LIB"

# A miniature GRCh38-shaped .fai: the canonical order, with chrM LAST. Both
# traps live here -- chr2 after chr19, and chrM after chrX/chrY.
FAI="$WORK/ref.fai"
printf 'chr1\t1000\nchr2\t1000\nchr9\t1000\nchr10\t1000\nchr19\t1000\nchrX\t1000\nchrY\t1000\nchrM\t500\n' > "$FAI"

# --- bed_sort_by_fai puts rows in reference order ---------------------------
printf 'chrM\t10\t20\nchr2\t10\t20\nchr10\t10\t20\nchr19\t10\t20\nchrX\t10\t20\nchr1\t10\t20\n' \
    > "$WORK/shuffled.bed"
GOT="$(bed_sort_by_fai "$FAI" < "$WORK/shuffled.bed" | cut -f1 | tr '\n' ' ')"
if [ "$GOT" = "chr1 chr2 chr10 chr19 chrX chrM " ]; then
    ok "bed_sort_by_fai emits reference order (chr2 before chr10/chr19, chrM last)"
else
    bad "bed_sort_by_fai order wrong: got '$GOT'"
fi

# The exact orders that must NOT be produced.
if [ "$GOT" != "chr1 chr10 chr19 chr2 chrM chrX " ]; then
    ok "output is not lexicographic (the sort -k1,1 bug)"
else
    bad "output is lexicographic — the original bug is back"
fi
if [ "$GOT" != "chr1 chr2 chr10 chr19 chrM chrX " ]; then
    ok "output is not version-sorted (sort -V still misplaces chrM)"
else
    bad "output is version-sorted — chrM is in the wrong place"
fi

# Within a contig, rows must be ordered by numeric start.
printf 'chr1\t100\t200\nchr1\t20\t30\nchr1\t9\t10\n' > "$WORK/starts.bed"
GOT="$(bed_sort_by_fai "$FAI" < "$WORK/starts.bed" | cut -f2 | tr '\n' ' ')"
if [ "$GOT" = "9 20 100 " ]; then
    ok "bed_sort_by_fai orders starts numerically within a contig"
else
    bad "start order wrong: got '$GOT'"
fi

# A contig absent from the .fai must be a hard error, never a silent drop.
if printf 'chr_decoy\t1\t2\n' | bed_sort_by_fai "$FAI" >/dev/null 2>&1; then
    bad "bed_sort_by_fai accepted a contig that is not in the .fai"
else
    ok "bed_sort_by_fai rejects a contig that is not in the .fai"
fi

# --- bed_assert_fai_sorted is the gate --------------------------------------
assert_rejects() {  # label, bed-content
    printf '%b' "$2" > "$WORK/case.bed"
    if bed_assert_fai_sorted "$FAI" "$WORK/case.bed" >/dev/null 2>&1; then
        bad "assert accepted $1"
    else
        ok "assert rejects $1"
    fi
}

printf 'chr1\t0\t100\nchr1\t200\t300\nchr2\t0\t50\nchrM\t0\t500\n' > "$WORK/good.bed"
if bed_assert_fai_sorted "$FAI" "$WORK/good.bed" >/dev/null 2>&1; then
    ok "assert accepts a well-formed reference-ordered BED"
else
    bad "assert rejected a valid BED"
fi

assert_rejects "a lexicographically ordered BED (chr10 before chr2)" \
    'chr1\t0\t10\nchr10\t0\t10\nchr2\t0\t10\n'
assert_rejects "chrM placed before chrX (the sort -V trap)" \
    'chr1\t0\t10\nchrM\t0\t10\nchrX\t0\t10\n'
assert_rejects "starts going backwards within a contig" \
    'chr1\t500\t600\nchr1\t100\t200\n'
assert_rejects "an end past the contig length (the unclamped chrM case)" \
    'chrM\t0\t530\n'
assert_rejects "a 4-column BED (sarek reads col 5 as a runtime estimate)" \
    'chr1\t0\t10\textra\n'
assert_rejects "an unmerged overlap" \
    'chr1\t0\t100\nchr1\t50\t150\n'
assert_rejects "a contig absent from the .fai" \
    'chr1\t0\t10\nchr_decoy\t0\t10\n'

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
