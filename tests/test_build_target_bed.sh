#!/usr/bin/env bash
#
# test_build_target_bed.sh — runnable on the dev box (no bedtools/docker needed).
#
# Exercises bin/build_target_bed.sh against a REAL DRAGEN tumour counts file and
# asserts: exit 0, exactly 3 columns on every row, contigs == chr1..22,X,Y,M,
# and the printed pad=30 checksums. Plus a negative test documenting that
# column-5 stripping is intrinsic (the tool only ever reads cut -f1-3).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/../bin/build_target_bed.sh"
REAL_COUNTS="/mnt/volume/data/DNA/00_metrics/S000021_S12944Nr11.tumor.target.counts.gc-corrected.gz"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_build_target_bed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

# --- preconditions ----------------------------------------------------------
[ -f "$TOOL" ] || { printf 'FAIL: tool not found: %s\n' "$TOOL"; exit 1; }
[ -x "$TOOL" ] || bad "tool is not executable: $TOOL"
if [ ! -f "$REAL_COUNTS" ]; then
    printf 'SKIP: real counts file not present: %s\n' "$REAL_COUNTS"
    exit 0
fi

# bash -n cleanliness of the tool itself.
if bash -n "$TOOL"; then ok "bin/build_target_bed.sh parses clean (bash -n)"; else bad "bin/build_target_bed.sh has syntax errors"; fi

# --- main run (pad=30, canonical) ------------------------------------------
OUT="$WORK/target_pad30.bed"
ERRLOG="$WORK/stderr.log"
if "$TOOL" "$REAL_COUNTS" "$OUT" >/dev/null 2>"$ERRLOG"; then
    ok "tool exited 0 on real tumour counts file"
else
    bad "tool exited non-zero (see below)"
    cat "$ERRLOG"
fi

# exactly 3 columns on EVERY row.
BADCOLS="$(awk -F'\t' 'NF!=3{c++} END{print c+0}' "$OUT")"
if [ "$BADCOLS" -eq 0 ]; then ok "every output row has exactly 3 tab-separated columns"; else bad "$BADCOLS rows do not have 3 columns"; fi

# start < stop and both integers on every row (sanity of the interval math).
BADINT="$(awk -F'\t' '$2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $2 >= $3 {c++} END{print c+0}' "$OUT")"
if [ "$BADINT" -eq 0 ]; then ok "every row has integer start < stop"; else bad "$BADINT rows have bad start/stop"; fi

# contigs are exactly chr1..22, chrX, chrY, chrM.
EXPECTED="$(printf 'chr%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 X Y M | sort -u)"
GOT="$(cut -f1 "$OUT" | sort -u)"
if [ "$GOT" = "$EXPECTED" ]; then
    ok "contigs are exactly chr1..22, chrX, chrY, chrM"
else
    bad "unexpected contig set:"
    printf '  got:\n%s\n  expected:\n%s\n' "$GOT" "$EXPECTED"
fi

# printed checksums (parsed from stderr banner).
if grep -q 'no-slop : 215624 regions / 36731644 bp' "$ERRLOG"; then ok "no-slop checksum printed: 215624 regions / 36731644 bp"; else bad "no-slop checksum banner missing/incorrect"; fi
if grep -q '+30 slop: 214494 regions / 49633029 bp' "$ERRLOG"; then ok "+30 slop checksum printed: 214494 regions / 49633029 bp"; else bad "+30 slop checksum banner missing/incorrect"; fi
if grep -q 'checksums verified' "$ERRLOG"; then ok "success banner reports checksums verified"; else bad "success banner missing"; fi

# --- negative test: column-5 stripping is intrinsic -------------------------
# A DRAGEN counts file carries a 5th data column (per-region coverage) and a 6th
# (improper_pairs). The tool reads only cut -f1-3, so those columns can NEVER
# leak into the BED. We prove it by confirming the RAW input has >3 columns
# while the OUTPUT has exactly 3 — i.e. the extra columns were dropped, not
# passed through. (sarek reads col-5 as a runtime estimate, so a leaked column
# would silently corrupt the interval scatter.)
RAWCOLS="$(zcat "$REAL_COUNTS" | sed -n '6p' | awk -F'\t' '{print NF}')"
if [ "$RAWCOLS" -gt 3 ]; then
    ok "raw counts input has $RAWCOLS columns (>3), yet output has 3 — col-5+ stripping is intrinsic (cut -f1-3)"
else
    bad "expected raw input to have >3 columns to exercise stripping, got $RAWCOLS"
fi

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
