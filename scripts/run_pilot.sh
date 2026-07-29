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
# NOTE these are the BARE sample ids, which is what the output FILE is named
# from. The names INSIDE the VCF are patient-prefixed; see PATIENT_ID below.
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

# The patient id, read from column 1. It is NOT cosmetic: sarek writes the BAM
# read group as SM:<patient>_<sample> (samplesheet_to_channel/main.nf:169), and
# Mutect2 takes its genotype column names and its ##tumor_sample=/##normal_sample=
# headers from SM. So the names INSIDE the VCF are patient-prefixed while the
# FILE is named from the bare sample ids -- both are needed below.
mapfile -t PATIENTS < <(tail -n +2 "$INPUT" | tr -d '\r' | cut -d, -f1 | sort -u)
(( ${#PATIENTS[@]} == 1 )) || die "run_pilot.sh runs ONE patient; $INPUT declares ${#PATIENTS[@]}: ${PATIENTS[*]}
       Split the samplesheet, or run sarek directly for a multi-patient cohort."
PATIENT_ID="${PATIENT_ID:-${PATIENTS[0]}}"

# Every FASTQ named in the samplesheet must exist ON THIS BOX. sarek's
# schema_input.json sets "exists": true on fastq_1/fastq_2, so a stale absolute
# path is a hard launch failure -- but only after Nextflow has started. Catch it
# here, and say what to do about it. The committed CSV is an EXAMPLE carrying one
# box's paths; the samplesheet is meant to be regenerated where the run happens.
missing=()
while IFS=, read -r _patient _sex _status _sample _lane fq1 fq2; do
    [[ -n "${fq1:-}" ]] || continue
    [[ -f "$fq1" ]] || missing+=("$fq1")
    [[ -z "${fq2:-}" || -f "$fq2" ]] || missing+=("$fq2")
done < <(tail -n +2 "$INPUT" | tr -d '\r')

if (( ${#missing[@]} > 0 )); then
    die "samplesheet $INPUT names ${#missing[@]} FASTQ file(s) that do not exist here:
       $(printf '%s\n       ' "${missing[@]}")
       Regenerate the samplesheet on THIS box before launching:
         bin/build_samplesheet.py \\
             --declarations assets/pilot_declarations.tsv \\
             --fastq-dir <the FASTQ directory on this box> \\
             --out <samplesheet.csv>
       then re-run with INPUT=<samplesheet.csv>."
fi

# --- the intervals BED must satisfy sarek/GATK's assumptions -------
# Fixing the builders is not enough: a BED built before 2026-07-27, or by hand,
# can still be lexicographically ordered (chr19 before chr2, chrM before chrX).
# sarek reads --intervals in the order given and GATK's GatherPileupSummaries
# assumes dictionary order, so such a BED runs for ~15 minutes and then dies in
# CalculateContamination on a reversed interval. Catch it here, before launch.
# shellcheck source=../bin/lib_bed.sh
. "${REPO_DIR}/bin/lib_bed.sh"
bed_assert_fai_sorted "$FAI" "$TARGET_BED" || die "intervals BED is not valid for sarek: $TARGET_BED
       Rebuild it (this also fixes contig order):
         bin/build_kit_bed.sh --out $TARGET_BED --fai $FAI"

echo "Pre-flight checks passed. Launching sarek..."
echo "  SAREK_DIR = $SAREK_DIR"
echo "  INPUT     = $INPUT"
echo "  OUTDIR    = $OUTDIR"

# --- The pinned minimal sarek invocation (v1) ----------------------
# Two flags that are easy to get wrong, both verified against the clone:
#   --trim_fastq    MANDATORY to make --trim_nextseq do anything. FASTP only
#                   runs when `params.trim_fastq || params.split_fastq > 0 ||
#                   params.umi_location` (fastq_preprocess_gatk/main.nf:107),
#                   so --trim_nextseq ALONE is a silent no-op. The reads are
#                   NovaSeq 6000 (2-colour), where poly-G tails are real.
#   --save_reference  publishes the bwa-mem2 index to <outdir>/reference. The
#                   index build costs ~87 GB RAM (280 MB x ceil(fasta/10 MB))
#                   and ~1 h; saving it lets the remaining patients reuse it
#                   via --bwamem2 instead of rebuilding.
nextflow run "$SAREK_DIR" \
    -profile docker -c "$RESOURCE_CONFIG" \
    --step mapping --tools mutect2 --wes --igenomes_ignore true \
    --input "$INPUT" --outdir "$OUTDIR" \
    --intervals "$TARGET_BED" --nucleotides_per_second 1000 \
    --fasta "$FASTA" --fasta_fai "$FAI" --dict "$DICT" \
    --germline_resource "$GNOMAD" \
    --skip_tools baserecalibrator,fastqc,mosdepth,samtools,multiqc,bcftools,vcftools \
    --markduplicates_pixel_distance 2500 --trim_fastq --trim_nextseq \
    --save_reference \
    -resume

# --- Locate the somatic VCF and assert the output contract ---------
VCF_NAME="${TUMOUR_ID}_vs_${NORMAL_ID}.mutect2.filtered.vcf.gz"
echo "Locating ${VCF_NAME} under ${OUTDIR}/variant_calling ..."

VCF="$(find "${OUTDIR}/variant_calling" -type f -name "$VCF_NAME" 2>/dev/null | head -n1 || true)"
[[ -n "$VCF" ]] || die "expected somatic VCF not found under ${OUTDIR}/variant_calling: $VCF_NAME
       (a run that silently routed to tumour-only mode will NOT produce a '_vs_' file)"

echo "Found: $VCF"
echo "Asserting v1 output contract..."
# Patient-prefixed on purpose -- the VCF's sample columns are SM names, not the
# samplesheet's `sample` column. Passing the bare ids here fails a GOOD run.
python3 "$ASSERT" --tumour "${PATIENT_ID}_${TUMOUR_ID}" --normal "${PATIENT_ID}_${NORMAL_ID}" "$VCF"
