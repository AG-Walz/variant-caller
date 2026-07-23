#!/usr/bin/env bash
#
# run_pilot.sh — variant-caller v1 pilot run
# ------------------------------------------------------------------
# Wraps the local nf-core/sarek clone with the ONE pinned minimal
# invocation for a single paired-somatic patient (UrCa pilot P11:
# tumour S12944Nr11 vs tumour_adjacent S12944Nr12), then asserts the
# somatic VCF against the v1 output contract.
#
# Every token in the nextflow command below is deliberate and has been
# verified against the sarek clone's nextflow_schema.json.
#
# Override any variable via the environment, e.g.:
#   OUTDIR=/data/run1 TUMOUR_ID=S12944Nr11 ./scripts/run_pilot.sh
#
set -euo pipefail

# --- Resolve repo-relative paths -----------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# --- Tunable variables (override via env) --------------------------
SAREK_DIR="${SAREK_DIR:-$(cd -- "${REPO_DIR}/../sarek" 2>/dev/null && pwd || echo "${REPO_DIR}/../sarek")}"
RESOURCE_CONFIG="${RESOURCE_CONFIG:-${REPO_DIR}/nextflow.config}"
INPUT="${INPUT:-${REPO_DIR}/assets/samplesheet_pilot_example.csv}"
OUTDIR="${OUTDIR:-${REPO_DIR}/results}"

REFERENCES_DIR="${REFERENCES_DIR:-${REPO_DIR}/references}"
TARGET_BED="${TARGET_BED:-${REFERENCES_DIR}/target_pad30.bed}"
FASTA="${FASTA:-${REFERENCES_DIR}/Homo_sapiens_assembly38.fasta}"
FAI="${FAI:-${REFERENCES_DIR}/Homo_sapiens_assembly38.fasta.fai}"
DICT="${DICT:-${REFERENCES_DIR}/Homo_sapiens_assembly38.dict}"
GNOMAD="${GNOMAD:-${REFERENCES_DIR}/af-only-gnomad.hg38.vcf.gz}"

# Declared pilot pair (tumour vs normal). The output contract is checked
# BY NAME against these — a tumour-only run would silently pass "two columns".
TUMOUR_ID="${TUMOUR_ID:-S12944Nr11}"
NORMAL_ID="${NORMAL_ID:-S12944Nr12}"

EXPECTED_HEADER="patient,sex,status,sample,lane,fastq_1,fastq_2"

# --- Pre-flight checks ---------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

if ! command -v nextflow >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: nextflow is not on PATH.

Install it (Java 11+ required) with:
    curl -s https://get.nextflow.io | bash
    sudo mv nextflow /usr/local/bin/   # or add it to your PATH

Then re-run this script.
EOF
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    die "docker is not on PATH. The pilot runs with '-profile docker' and needs the Docker engine."
fi
docker info >/dev/null 2>&1 || die "docker is installed but not usable (daemon down or no permission). Fix Docker, then re-run."

[[ -d "$SAREK_DIR" ]]        || die "SAREK_DIR does not exist: $SAREK_DIR"
[[ -f "$RESOURCE_CONFIG" ]]  || die "resource config not found: $RESOURCE_CONFIG"
[[ -f "$INPUT" ]]            || die "samplesheet not found: $INPUT"
[[ -f "$TARGET_BED" ]]       || die "intervals BED not found: $TARGET_BED  (build it with bin/, or set TARGET_BED)"
[[ -f "$FASTA" ]]            || die "reference FASTA not found: $FASTA  (run fetch_references.sh, or set FASTA)"
[[ -f "$FAI" ]]             || die "reference .fai not found: $FAI"
[[ -f "$DICT" ]]            || die "reference .dict not found: $DICT"
[[ -f "$GNOMAD" ]]          || die "germline resource (af-only gnomAD) not found: $GNOMAD"

ASSERT="${REPO_DIR}/bin/assert_output.py"
[[ -f "$ASSERT" ]]          || die "output validator not found: $ASSERT"

# Samplesheet header must match the sarek contract exactly.
actual_header="$(head -n1 "$INPUT" | tr -d '\r')"
[[ "$actual_header" == "$EXPECTED_HEADER" ]] || \
    die "samplesheet header mismatch in $INPUT
       expected: $EXPECTED_HEADER
       found:    $actual_header"

echo "Pre-flight checks passed. Launching sarek..."
echo "  SAREK_DIR = $SAREK_DIR"
echo "  INPUT     = $INPUT"
echo "  OUTDIR    = $OUTDIR"

# --- The pinned minimal sarek invocation (v1) ----------------------
nextflow run "$SAREK_DIR" \
    -profile docker -c "$RESOURCE_CONFIG" \
    --step mapping --tools mutect2 --wes --igenomes_ignore true \
    --input "$INPUT" --outdir "$OUTDIR" \
    --intervals "$TARGET_BED" --nucleotides_per_second 1000 \
    --fasta "$FASTA" --fasta_fai "$FAI" --dict "$DICT" \
    --germline_resource "$GNOMAD" \
    --skip_tools baserecalibrator,fastqc,mosdepth,samtools,multiqc,bcftools,vcftools \
    --markduplicates_pixel_distance 2500 --trim_nextseq \
    -resume

# --- Locate the somatic VCF and assert the output contract ---------
VCF_NAME="${TUMOUR_ID}_vs_${NORMAL_ID}.mutect2.filtered.vcf.gz"
echo "Locating ${VCF_NAME} under ${OUTDIR}/variant_calling ..."

VCF="$(find "${OUTDIR}/variant_calling" -type f -name "$VCF_NAME" 2>/dev/null | head -n1 || true)"
[[ -n "$VCF" ]] || die "expected somatic VCF not found under ${OUTDIR}/variant_calling: $VCF_NAME
       (a run that silently routed to tumour-only mode will NOT produce a '_vs_' file)"

echo "Found: $VCF"
echo "Asserting v1 output contract..."
python3 "$ASSERT" --tumour "$TUMOUR_ID" --normal "$NORMAL_ID" "$VCF"
