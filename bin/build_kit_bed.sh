#!/usr/bin/env bash
#
# build_kit_bed.sh — build the target BED from the CAPTURE KIT VENDOR's files.
# ------------------------------------------------------------------
# This is the CANONICAL way to produce references/target_pad30.bed.
# (bin/build_target_bed.sh reconstructs the same thing from DRAGEN counts and
# is kept only to VERIFY this output against what was physically captured.)
#
# Kit for the UrCa run (CTP somatic project report, p.3):
#   "Twist Human Core Exome + RefSeq + Mitochondrial Panel", Twist Bioscience
#
# That name maps to exactly TWO vendor files, both hg38:
#   1. Twist_Exome_RefSeq_targets_hg38.bed        Core Exome + RefSeq, 215,623 regions
#   2. Twist_MitoPanel_chrM_all_hg38_target.bed   chrM 1-16569,             1 region
#
# The separate "Twist_Exome_Core_Covered_Targets_hg38.bed" (192,262 regions) is
# NOT used: the RefSeq file already contains the Core Exome content.
#
# Proven identical to what CeGaT actually captured: this union gives 215,624
# regions, of which 215,623 match the DRAGEN target counts EXACTLY. The only
# difference is chrM (vendor tiles 1-16569; the counts report 113-16517).
#
# Padding: 30 bp, matching CeGaT's own DRAGEN setting
# (--vc-target-bed-padding 30, from the delivered VCF header).
#
# Output is EXACTLY 3 columns: sarek's create_intervals_bed reads column 5 as a
# per-region runtime estimate, so any extra column silently breaks the scatter.
#
# Usage:
#   build_kit_bed.sh --out references/target_pad30.bed \
#                    [--fai references/Homo_sapiens_assembly38.fasta.fai] \
#                    [--refseq FILE] [--mito FILE] [--pad N] \
#                    [--verify <counts.gc-corrected.gz>]
#
#   --fai      reference .fai; used to CLAMP padded ends to the contig length.
#              Strongly recommended: chrM 1-16569 padded by 30 would otherwise
#              become 0-16599, past the end of chrM, and GATK rejects that.
#   --refseq   local copy of the Twist RefSeq BED   (default: download)
#   --mito     local copy of the Twist Mito BED     (default: download)
#   --pad      symmetric padding in bp              (default: 30)
#   --verify   DRAGEN *.target.counts.gc-corrected.gz to cross-check against
#
# Pure curl + awk + coreutils. No bedtools (not installed on the target box).

set -euo pipefail
export LC_ALL=C

TWIST_BASE="https://www.twistbioscience.com/content/dam/twistbioscience/resources"
URL_REFSEQ="${URL_REFSEQ:-${TWIST_BASE}/2019-09/Twist_Exome_RefSeq_targets_hg38.bed}"
URL_MITO="${URL_MITO:-${TWIST_BASE}/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed}"

OUT=""
FAI=""
REFSEQ=""
MITO=""
PAD=30
VERIFY=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)    [ $# -ge 2 ] || die "--out needs a value";    OUT="$2";    shift 2 ;;
        --fai)    [ $# -ge 2 ] || die "--fai needs a value";    FAI="$2";    shift 2 ;;
        --refseq) [ $# -ge 2 ] || die "--refseq needs a value"; REFSEQ="$2"; shift 2 ;;
        --mito)   [ $# -ge 2 ] || die "--mito needs a value";   MITO="$2";   shift 2 ;;
        --pad)    [ $# -ge 2 ] || die "--pad needs a value";    PAD="$2";    shift 2 ;;
        --verify) [ $# -ge 2 ] || die "--verify needs a value"; VERIFY="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$OUT" ] || usage
case "$PAD" in ''|*[!0-9]*) die "--pad must be a non-negative integer, got: $PAD" ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/build_kit_bed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # url, dest, label
    command -v curl >/dev/null 2>&1 || die "curl is required to download the kit BEDs."
    note "downloading $3 ..."
    curl -fsSL --retry 3 --max-time 180 -o "$2" "$1" \
        || die "download failed: $1
       Download it by hand and pass it with --refseq / --mito."
    [ -s "$2" ] || die "downloaded $3 is empty: $1"
}

[ -n "$REFSEQ" ] || { REFSEQ="$WORK/refseq.bed"; fetch "$URL_REFSEQ" "$REFSEQ" "Twist RefSeq targets (hg38)"; }
[ -n "$MITO" ]   || { MITO="$WORK/mito.bed";     fetch "$URL_MITO"   "$MITO"   "Twist Mito panel (hg38)"; }
[ -f "$REFSEQ" ] || die "RefSeq BED not found: $REFSEQ"
[ -f "$MITO" ]   || die "Mito BED not found: $MITO"

# Sanity: these must be plain BEDs, not an HTML error page.
for f in "$REFSEQ" "$MITO"; do
    head -c 200 "$f" | grep -qi '<html\|<!doctype' \
        && die "$f looks like an HTML page, not a BED (a login wall or a moved URL?)"
    head -1 "$f" | awk -F'\t' '{exit !($1 ~ /^chr/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/)}' \
        || die "$f does not look like a 3-column BED; first line: $(head -1 "$f")"
done

# Shared merge: input must be sorted; merges overlapping AND adjacent regions.
MERGE_AWK='
BEGIN { OFS="\t" }
{
    c=$1; s=$2; e=$3;
    if (NR==1 || c!=pc || s>pe) { if (NR>1) print pc, ps, pe; pc=c; ps=s; pe=e }
    else if (e>pe) { pe=e }
}
END { if (NR>0) print pc, ps, pe }
'

# --- stage 1: union of the kit components, no padding ---------------------
cat "$REFSEQ" "$MITO" \
    | grep -v '^#' | grep -v '^track' | grep -v '^browser' \
    | awk -F'\t' 'NF>=3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {print $1"\t"$2"\t"$3}' \
    | sort -k1,1 -k2,2n \
    | awk "$MERGE_AWK" > "$WORK/noslop.bed"

read -r NR_ NB_ < <(awk '{n++; b+=$3-$2} END {print n+0, b+0}' "$WORK/noslop.bed")
note "kit union      : ${NR_} regions / ${NB_} bp"

# --- stage 2: pad, clamp to contig bounds, re-merge ------------------------
if [ -n "$FAI" ]; then
    [ -f "$FAI" ] || die "--fai file not found: $FAI"
    # Clamp the padded end to the contig length from the .fai (column 2).
    # Without this, chrM 1-16569 padded by 30 becomes 0-16599 -- past the end of
    # chrM -- and GATK rejects out-of-bounds intervals.
    awk -F'\t' -v pad="$PAD" 'BEGIN{OFS="\t"}
        NR==FNR { len[$1]=$2; next }
        {
            s=$2-pad; if (s<0) s=0;
            e=$3+pad;
            if (($1 in len) && e>len[$1]) e=len[$1];
            if (e>s) print $1, s, e;
        }' "$FAI" "$WORK/noslop.bed" \
        | sort -k1,1 -k2,2n | awk "$MERGE_AWK" > "$OUT"
    note "padding       : +${PAD} bp, ends clamped to contig lengths from $(basename "$FAI")"
else
    note "WARNING: no --fai given, so padded ends are NOT clamped to contig lengths."
    note "         chrM +${PAD} bp will run past the end of chrM and GATK will reject it."
    note "         Pass --fai <reference>.fasta.fai unless you know you don't need it."
    awk -F'\t' -v pad="$PAD" 'BEGIN{OFS="\t"}
        { s=$2-pad; if (s<0) s=0; print $1, s, $3+pad }' "$WORK/noslop.bed" \
        | sort -k1,1 -k2,2n | awk "$MERGE_AWK" > "$OUT"
fi

read -r PR_ PB_ < <(awk '{n++; b+=$3-$2} END {print n+0, b+0}' "$OUT")
note "padded (+${PAD})  : ${PR_} regions / ${PB_} bp"

ncol="$(awk -F'\t' 'NR==1{print NF; exit}' "$OUT")"
[ "$ncol" = "3" ] || die "output has ${ncol} columns, must be exactly 3 (sarek reads col 5 as a runtime estimate)"

# --- optional: verify against what was PHYSICALLY captured -----------------
if [ -n "$VERIFY" ]; then
    [ -f "$VERIFY" ] || die "--verify file not found: $VERIFY"
    note ""
    note "verifying against the DRAGEN target counts (what was actually captured)..."
    zcat "$VERIFY" | tail -n +6 | cut -f1-3 | sort -k1,1 -k2,2n \
        | awk "$MERGE_AWK" > "$WORK/truth.bed"
    sort "$WORK/noslop.bed" > "$WORK/a.s"
    sort "$WORK/truth.bed"  > "$WORK/b.s"
    same="$(comm -12 "$WORK/a.s" "$WORK/b.s" | wc -l)"
    onlyk="$(comm -23 "$WORK/a.s" "$WORK/b.s" | wc -l)"
    onlyt="$(comm -13 "$WORK/a.s" "$WORK/b.s" | wc -l)"
    tot="$(wc -l < "$WORK/b.s")"
    note "  exact matches      : ${same} / ${tot} captured regions"
    note "  only in kit files  : ${onlyk}"
    note "  only in the counts : ${onlyt}"
    if [ "$onlyk" -le 2 ] && [ "$onlyt" -le 2 ]; then
        note "  OK: kit BED matches the captured target set (chrM edge differences are expected)."
    else
        note "  WARNING: more divergence than expected. Check the kit version before running."
    fi
fi

note ""
note "OK: wrote ${OUT}"
