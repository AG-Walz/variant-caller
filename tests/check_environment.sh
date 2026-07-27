#!/usr/bin/env bash
#
# check_environment.sh — preflight check for a box that will run the pipeline.
# ------------------------------------------------------------------
# Answers one question: can this machine run scripts/run_pilot.sh?
#
# Prints a PASS/FAIL/WARN line per requirement and exits non-zero if any HARD
# requirement fails. Read-only: it installs nothing and changes nothing.
#   FAIL  the run cannot start (or will die early)
#   WARN  the run can start, but something is missing or unusual
#
# Named check_* rather than test_* so the unit-test glob (tests/test_*) still
# selects only the dependency-light soundness tests, which run anywhere.
#
# Bootstrap what is missing with:  scripts/setup_env.sh
#
# Override via the environment:
#   SAREK_DIR=../sarek                    expected sibling sarek clone
#   REFERENCES_DIR=<repo>/references      where fetch_references.sh puts things
#   INPUT=<samplesheet.csv>               samplesheet whose FASTQ paths to check
#   MIN_DISK_GB=500                       free-space threshold on the work disk

set -uo pipefail   # NOT -e: this script reports failures, it does not abort on them

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SAREK_DIR="${SAREK_DIR:-${REPO_DIR}/../sarek}"
REFERENCES_DIR="${REFERENCES_DIR:-${REPO_DIR}/references}"
INPUT="${INPUT:-}"
MIN_DISK_GB="${MIN_DISK_GB:-500}"
SAREK_REF="${SAREK_REF:-3.9.0}"

MIN_NEXTFLOW="25.10.2"
MIN_JAVA_MAJOR=17

fails=0
warns=0

pass() { printf '  \033[32mPASS\033[0m  %-26s %s\n' "$1" "${2:-}"; }
fail() { printf '  \033[31mFAIL\033[0m  %-26s %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %-26s %s\n' "$1" "${2:-}"; warns=$((warns + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

version_ge() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

printf '\033[1mvariant-caller — environment check\033[0m\n'
printf 'repo: %s\n' "$REPO_DIR"

# --- Hard requirements: the toolchain -------------------------------------
head_ "Toolchain"

if command -v java >/dev/null 2>&1; then
    raw="$(java -version 2>&1 | head -n1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
    case "$raw" in
        1.*) major="$(printf '%s\n' "$raw" | cut -d. -f2)" ;;
        *)   major="$(printf '%s\n' "$raw" | cut -d. -f1)" ;;
    esac
    if [ -n "${major:-}" ] && [ "$major" -ge "$MIN_JAVA_MAJOR" ] 2>/dev/null; then
        pass "java" "${raw} (>= ${MIN_JAVA_MAJOR})"
    else
        fail "java" "${raw:-unknown} -- Nextflow ${MIN_NEXTFLOW} needs Java ${MIN_JAVA_MAJOR}+"
    fi
else
    fail "java" "not on PATH -- Nextflow needs Java ${MIN_JAVA_MAJOR}+"
fi

if command -v nextflow >/dev/null 2>&1; then
    nfv="$(nextflow -v 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n1)"
    if [ -n "$nfv" ] && version_ge "$nfv" "$MIN_NEXTFLOW"; then
        pass "nextflow" "${nfv} (>= ${MIN_NEXTFLOW})"
    else
        fail "nextflow" "${nfv:-unknown} -- sarek pins '!>=${MIN_NEXTFLOW}', a hard failure"
    fi
else
    fail "nextflow" "not on PATH -- run scripts/setup_env.sh"
fi

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        pass "docker" "usable by this user"
    else
        fail "docker" "installed but not usable (daemon down, or user not in 'docker' group)"
    fi
else
    fail "docker" "not on PATH -- the pilot runs with -profile docker"
fi

for tool in python3 awk curl git; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "$tool" "$(command -v "$tool")"
    else
        fail "$tool" "not on PATH"
    fi
done

if command -v screen >/dev/null 2>&1; then
    pass "screen" "$(command -v screen)"
else
    warn "screen" "not on PATH -- a dropped SSH connection would kill a long run"
fi

# --- Hard requirement: the sibling sarek clone ----------------------------
head_ "sarek clone (wrapped by path, not vendored)"

if [ -d "$SAREK_DIR/.git" ]; then
    ref="$(git -C "$SAREK_DIR" describe --tags --always 2>/dev/null || echo unknown)"
    if [ "$ref" = "$SAREK_REF" ]; then
        pass "sarek checkout" "${SAREK_REF} at ${SAREK_DIR}"
    else
        warn "sarek checkout" "at '${ref}', expected '${SAREK_REF}'"
    fi
    if [ -n "$(git -C "$SAREK_DIR" status --porcelain 2>/dev/null)" ]; then
        warn "sarek clean" "local modifications present -- not stock ${SAREK_REF}"
    else
        pass "sarek clean" "no local modifications"
    fi
    if [ -f "$SAREK_DIR/main.nf" ]; then
        pass "sarek main.nf" "present"
    else
        fail "sarek main.nf" "missing -- $SAREK_DIR does not look like sarek"
    fi
elif [ -d "$SAREK_DIR" ]; then
    fail "sarek clone" "$SAREK_DIR exists but is not a git clone"
else
    fail "sarek clone" "not found at $SAREK_DIR -- run scripts/setup_env.sh"
fi

# --- Soft: per-box data, absent on a fresh machine ------------------------
head_ "Per-box data (none of it is in git)"

check_file() {  # label, path, hint
    if [ -f "$2" ]; then
        pass "$1" "$(du -h "$2" 2>/dev/null | cut -f1) $2"
    else
        warn "$1" "missing -- $3"
    fi
}

check_file "reference fasta" "${REFERENCES_DIR}/Homo_sapiens_assembly38.fasta" "scripts/fetch_references.sh"
check_file "reference .fai"  "${REFERENCES_DIR}/Homo_sapiens_assembly38.fasta.fai" "scripts/fetch_references.sh"
check_file "reference .dict" "${REFERENCES_DIR}/Homo_sapiens_assembly38.dict" "scripts/fetch_references.sh"
check_file "germline resource" "${REFERENCES_DIR}/af-only-gnomad.hg38.vcf.gz" "scripts/fetch_references.sh"
check_file "target BED" "${REFERENCES_DIR}/target_pad30.bed" "bin/build_kit_bed.sh"

# The BED must be in the REFERENCE's contig order, not lexicographic: sarek reads
# --intervals in the order given and GATK's GatherPileupSummaries assumes dictionary
# order, so a chr19-before-chr2 BED fails the run in CalculateContamination, ~15
# minutes in. A BED built before 2026-07-27 (or by hand) is very likely wrong.
if [ -f "${REFERENCES_DIR}/target_pad30.bed" ] && [ -f "${REFERENCES_DIR}/Homo_sapiens_assembly38.fasta.fai" ]; then
    # shellcheck source=../bin/lib_bed.sh
    . "${REPO_DIR}/bin/lib_bed.sh"
    if bed_assert_fai_sorted "${REFERENCES_DIR}/Homo_sapiens_assembly38.fasta.fai" \
                             "${REFERENCES_DIR}/target_pad30.bed" 2>/dev/null; then
        pass "target BED order" "3 cols, reference contig order, in-bounds, non-overlapping"
    else
        fail "target BED order" "not a valid sarek --intervals BED -- rebuild: bin/build_kit_bed.sh --out ${REFERENCES_DIR}/target_pad30.bed --fai ${REFERENCES_DIR}/Homo_sapiens_assembly38.fasta.fai"
    fi
fi

# Samplesheet: absolute paths are host-specific and sarek sets "exists": true.
if [ -n "$INPUT" ]; then
    sheet="$INPUT"
elif [ -f "${REPO_DIR}/assets/samplesheet_pilot.csv" ]; then
    sheet="${REPO_DIR}/assets/samplesheet_pilot.csv"
else
    sheet=""
fi

if [ -z "$sheet" ]; then
    warn "samplesheet" "none yet -- build one with bin/build_samplesheet.py ON THIS BOX"
elif [ ! -f "$sheet" ]; then
    fail "samplesheet" "not found: $sheet"
else
    missing=0
    total=0
    while IFS=, read -r _p _s _st _sm _l fq1 fq2; do
        [ -n "${fq1:-}" ] || continue
        total=$((total + 1)); [ -f "$fq1" ] || missing=$((missing + 1))
        if [ -n "${fq2:-}" ]; then
            total=$((total + 1)); [ -f "$fq2" ] || missing=$((missing + 1))
        fi
    done < <(tail -n +2 "$sheet" | tr -d '\r')
    if [ "$missing" -eq 0 ] && [ "$total" -gt 0 ]; then
        pass "samplesheet FASTQs" "$total/$total present ($(basename "$sheet"))"
    else
        fail "samplesheet FASTQs" "$missing of $total missing -- regenerate on this box"
    fi
fi

# --- Soft: capacity -------------------------------------------------------
head_ "Capacity"

avail_gb="$(df -BG --output=avail "$REPO_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')"
if [ -n "$avail_gb" ]; then
    if [ "$avail_gb" -ge "$MIN_DISK_GB" ]; then
        pass "free disk" "${avail_gb} GB (>= ${MIN_DISK_GB} GB)"
    else
        warn "free disk" "${avail_gb} GB -- references, work/ and results want >= ${MIN_DISK_GB} GB"
    fi
fi

mem_gb="$(free -g 2>/dev/null | awk '/^Mem:/ {print $2}')"
if [ -n "$mem_gb" ]; then
    # bwa-mem2 index build: 280 MB * ceil(fasta_size / 10 MB) ~= 87 GB for GRCh38
    # (modules/nf-core/bwamem2/index/main.nf). Below that, mapping cannot start.
    if [ "$mem_gb" -ge 100 ]; then
        pass "RAM" "${mem_gb} GB"
    else
        fail "RAM" "${mem_gb} GB -- the bwa-mem2 index build alone needs ~87 GB"
    fi
fi

cores="$(nproc 2>/dev/null)"
[ -n "$cores" ] && pass "cores" "$cores"

# --- Summary --------------------------------------------------------------
printf '\n'
if [ "$fails" -gt 0 ]; then
    printf '\033[31m%d FAIL\033[0m, %d WARN — this box cannot run the pipeline yet.\n' "$fails" "$warns"
    printf 'Fix the FAILs above (scripts/setup_env.sh handles sarek + Nextflow), then re-run.\n'
    exit 1
fi
if [ "$warns" -gt 0 ]; then
    printf '\033[32mAll hard requirements met\033[0m, %d WARN — see above.\n' "$warns"
    exit 0
fi
printf '\033[32mAll checks passed.\033[0m Ready for scripts/run_pilot.sh\n'
