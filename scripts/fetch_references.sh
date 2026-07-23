#!/usr/bin/env bash
# =============================================================================
# fetch_references.sh — download the GATK GRCh38 reference bundle that sarek
# needs for the pinned variant-caller v1 invocation:
#     --step mapping --tools mutect2 --wes --igenomes_ignore true
#
# Because we pass --igenomes_ignore true, sarek looks up NOTHING from iGenomes
# and instead uses the explicit --fasta / --fasta_fai / --dict / --germline_resource
# paths we give it. This script fetches exactly those files (and nothing more).
#
# FILES FETCHED (name is load-bearing — sarek + downstream tools match by name):
#   Homo_sapiens_assembly38.fasta        ~3.1 GB  Reference genome (GRCh38, Broad hg38 v0).
#                                                  Passed as --fasta. The alignment target.
#   Homo_sapiens_assembly38.fasta.fai    ~0.2 KB  FASTA index (samtools faidx). --fasta_fai.
#   Homo_sapiens_assembly38.dict         ~0.6 KB  Sequence dictionary (Picard). --dict.
#   af-only-gnomad.hg38.vcf.gz           ~3.3 GB  gnomAD allele-frequency-only germline
#                                                  resource. Passed as --germline_resource.
#                                                  DOUBLES as the GetPileupSummaries /
#                                                  CalculateContamination source — no
#                                                  separate small_exac file is needed.
#   af-only-gnomad.hg38.vcf.gz.tbi       ~2.5 MB  Tabix index for the gnomAD VCF.
#
# WHY fai + dict are fetched (not just built): sarek CAN build .fai and .dict on the
# fly from --fasta if they are omitted, but fetching the Broad-published copies is
# instant, deterministic, and avoids a redundant per-run indexing step.
#
# THE bwa-mem2 INDEX IS NOT FETCHED: no public bwa-mem2 index ships in these buckets.
# sarek builds the bwa-mem2 index automatically from --fasta on the first --step mapping
# run. That build is a ONE-TIME step but costs ~1 hour and tens of GB of RAM. If you
# want to avoid paying it inside the first pipeline run, you may prebuild it once with
# `bwa-mem2 index Homo_sapiens_assembly38.fasta` and point sarek at it via --bwa; v1
# does not require this and does not do it here.
#
# SOURCES (public Google Cloud Storage HTTPS mirrors, no auth required):
#   fasta / fai / dict : storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/
#   af-only-gnomad     : storage.googleapis.com/gatk-best-practices/somatic-hg38/
#
# USAGE:
#   scripts/fetch_references.sh [--dest DIR]
#       --dest DIR   directory to download into (default: ./references)
#       -h|--help    show this help
#
# BEHAVIOUR: idempotent. Files already present at the expected size are skipped.
# Partial downloads are resumed (curl -C -). A manifest of on-disk files with sizes
# is printed at the end so an operator can sanity-check against the expected sizes
# above (fasta ~3.1G, af-only-gnomad ~3.3G).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEST="./references"

BROAD_BASE="https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0"
GATK_SOMATIC_BASE="https://storage.googleapis.com/gatk-best-practices/somatic-hg38"

# Each entry: "<filename>|<url>|<expected_size_bytes>"
# Expected sizes are the published byte counts from the GCS buckets; they are used
# ONLY to decide whether an existing local file is complete (skip) or partial
# (resume). A size of 0 means "unknown — never skip, always resume/verify".
REFS=(
  "Homo_sapiens_assembly38.fasta|${BROAD_BASE}/Homo_sapiens_assembly38.fasta|3249912778"
  "Homo_sapiens_assembly38.fasta.fai|${BROAD_BASE}/Homo_sapiens_assembly38.fasta.fai|160928"
  "Homo_sapiens_assembly38.dict|${BROAD_BASE}/Homo_sapiens_assembly38.dict|581712"
  "af-only-gnomad.hg38.vcf.gz|${GATK_SOMATIC_BASE}/af-only-gnomad.hg38.vcf.gz|3184275189"
  "af-only-gnomad.hg38.vcf.gz.tbi|${GATK_SOMATIC_BASE}/af-only-gnomad.hg38.vcf.gz.tbi|2443190"
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { echo "ERROR: --dest requires a directory argument" >&2; exit 2; }
      DEST="$2"; shift 2 ;;
    --dest=*)
      DEST="${1#--dest=}"; shift ;;
    -h|--help)
      usage 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: 'curl' is not installed but is required to download the reference bundle.

Install it, then re-run this script:
  Debian/Ubuntu:  sudo apt-get update && sudo apt-get install -y curl
  RHEL/CentOS:    sudo yum install -y curl

The downloads resume, so a partial run is safe to restart.
EOF
  exit 3
fi

mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Portable file size in bytes (Linux stat -c ; BSD/macOS stat -f).
file_size() {
  local f="$1"
  if [[ ! -f "$f" ]]; then echo 0; return; fi
  stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || echo 0
}

# Human-readable size for the manifest.
human_size() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null && return
  fi
  echo "${bytes} B"
}

# ---------------------------------------------------------------------------
# Download loop
# ---------------------------------------------------------------------------
echo "Reference destination: $DEST"
echo "Fetching ${#REFS[@]} file(s). Large files (fasta ~3.1G, af-only-gnomad ~3.3G) may take a while."
echo

for entry in "${REFS[@]}"; do
  IFS='|' read -r fname url expected <<< "$entry"
  target="${DEST%/}/${fname}"
  have=$(file_size "$target")

  if [[ "$expected" -gt 0 && "$have" -eq "$expected" ]]; then
    echo "SKIP  $fname  (already present, $(human_size "$have"))"
    continue
  fi

  if [[ "$have" -gt 0 ]]; then
    echo "RESUME $fname  (have $(human_size "$have"), expecting $(human_size "$expected"))"
  else
    echo "GET   $fname  <- $url"
  fi

  # -L follow redirects, -C - resume from where we left off, -f fail on HTTP error,
  # --retry survive transient network blips.
  curl -fL -C - --retry 5 --retry-delay 5 -o "$target" "$url"

  # Post-download size sanity check (warn only; sizes can drift if the bucket is updated).
  got=$(file_size "$target")
  if [[ "$expected" -gt 0 && "$got" -ne "$expected" ]]; then
    echo "WARN  $fname downloaded size $(human_size "$got") != expected $(human_size "$expected")" >&2
    echo "      If this persists, delete the file and re-run to force a clean download." >&2
  else
    echo "OK    $fname  ($(human_size "$got"))"
  fi
  echo
done

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
echo "=============================================================="
echo "Reference bundle manifest — $DEST"
echo "=============================================================="
all_present=1
for entry in "${REFS[@]}"; do
  IFS='|' read -r fname url expected <<< "$entry"
  target="${DEST%/}/${fname}"
  sz=$(file_size "$target")
  if [[ "$sz" -gt 0 ]]; then
    printf '  %-40s %s\n' "$fname" "$(human_size "$sz")"
  else
    printf '  %-40s %s\n' "$fname" "MISSING"
    all_present=0
  fi
done
echo "--------------------------------------------------------------"
if [[ "$all_present" -eq 1 ]]; then
  echo "All reference files present. Point the sarek run at:"
  echo "    --fasta            ${DEST%/}/Homo_sapiens_assembly38.fasta"
  echo "    --fasta_fai        ${DEST%/}/Homo_sapiens_assembly38.fasta.fai"
  echo "    --dict             ${DEST%/}/Homo_sapiens_assembly38.dict"
  echo "    --germline_resource ${DEST%/}/af-only-gnomad.hg38.vcf.gz"
else
  echo "One or more files are MISSING — re-run this script to complete the bundle."
  exit 4
fi
