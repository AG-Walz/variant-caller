#!/usr/bin/env bash
#
# setup.sh — everything that has to exist ONCE on a machine before a run is possible.
# Run it again whenever you want: every step is idempotent and every download resumes.
#
# It does three things, in order:
#   1. refuses to continue unless the six required commands are on PATH
#   2. clones nf-core/sarek 3.9.0 next to this repo, if it is not already there
#   3. downloads ~11.8 GB of GRCh38 reference data into references/
#
# WHAT IT DOES NOT DO: create the samplesheet (host-specific, see README) or build the
# target BED (that is scripts/build_bed.sh, because it changes per capture kit).

# -e  stop at the first command that fails, instead of ploughing on with half a reference
# -u  a typo'd variable name is an error, not an empty string
# -o pipefail  a failing command inside a pipeline fails the pipeline (curl | bedtools)
set -euo pipefail

# Every path below is written relative to the repo root, so go there first. $0 is this
# script's path, dirname strips the filename, /.. climbs out of scripts/. This makes the
# script work identically whether you type ./scripts/setup.sh or /abs/path/scripts/setup.sh.
cd "$(dirname "$0")/.."

# --- 1. the toolchain -------------------------------------------------------------------
#
#   nextflow  the workflow engine. MUST be 25.10.x: sarek 3.9.0 requires >=25.10.2, but
#             get.nextflow.io currently installs 26.04.6, under which this exact pipeline
#             aborts on a valid paired samplesheet.
#   java      nextflow is a JVM program; 17+ is required, 21 is what we run on.
#   docker    every tool sarek calls (bwa, gatk, fastp...) runs in a container. Nothing
#             bioinformatic is installed on the host, which is why this list is so short.
#   bedtools  used only by build_bed.sh, checked here so you find out now and not later.
#   aria2c    a parallel/resumable downloader. curl would work but takes far longer on
#             the two 3.2 GB files, and cannot resume a half-finished one as cleanly.
#   curl      used by build_bed.sh to fetch the capture-kit BEDs from the vendor.
#
# We collect ALL the missing names before reporting, so you install them in one go rather
# than discovering them one failed run at a time.
missing=""
for t in nextflow java docker bedtools aria2c curl; do
    # `command -v` is the portable "is this on PATH"; >/dev/null discards the path it prints.
    command -v "$t" >/dev/null || missing="$missing $t"
done
if [ -n "$missing" ]; then
    # >&2 sends these to stderr, so they still appear if you pipe stdout to a log file.
    echo "missing:$missing" >&2
    echo "" >&2
    echo "install them with:" >&2
    echo "  mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools aria2" >&2
    echo "  export PATH=~/envs/vc/bin:\$PATH" >&2
    exit 1
fi

# --- 2. the sarek clone -----------------------------------------------------------------
#
# This repo contains no pipeline logic: it runs *stock* sarek, unmodified, from a sibling
# directory. `-c nextflow.config -params-file params/pilot.yaml` is the whole contribution.
# --branch 3.9.0 pins the tag (not a moving branch) and --depth 1 skips the history, which
# turns a ~400 MB clone into ~40 MB. If ../sarek already exists we leave it completely
# alone — including any local changes, which is why the README calls it read-only.
[ -d ../sarek ] || git clone --branch 3.9.0 --depth 1 https://github.com/nf-core/sarek.git ../sarek

# --- 3. the reference bundle ------------------------------------------------------------
#
# Two public buckets, both requester-pays-free and unauthenticated:
#   B  the Broad's GRCh38 reference bundle: the genome itself and its indices
#   G  GATK's somatic best-practice resources: the population allele frequencies
B=https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0
G=https://storage.googleapis.com/gatk-best-practices/somatic-hg38

# -p so it is not an error when the directory already exists (this script is re-runnable).
mkdir -p references/bwa

# aria2c flags, the same for every call below:
#   -x8  up to 8 connections to the server for one file
#   -s8  split that file into 8 parts downloaded in parallel  (-x and -s work as a pair)
#   -c   CONTINUE a partial file rather than restarting it — this is what makes an
#        interrupted setup.sh cheap to re-run, and why re-running a finished one is a no-op
#   -d   the destination directory
#
# The genome: the .fasta itself (3.2 GB), its .fai index (which line/byte does each contig
# start at) and its .dict sequence dictionary (contig names, lengths and MD5s). sarek needs
# all three, and nf-schema aborts at launch if any is missing — loudly, before any task runs.
aria2c -x8 -s8 -c -d references \
    "$B/Homo_sapiens_assembly38.fasta" \
    "$B/Homo_sapiens_assembly38.fasta.fai" \
    "$B/Homo_sapiens_assembly38.dict"

# The germline resource (3.2 GB + its .tbi index) does DOUBLE duty in this pipeline:
#   - Mutect2 reads it for population allele frequencies, to tell a common germline variant
#     from a somatic one
#   - GetPileupSummaries/CalculateContamination read it to estimate cross-sample contamination
# It is the one Mutect2 reference sarek's schema does NOT mark as required, and without it
# sarek publishes the UNFILTERED VCF (every FILTER field '.') without complaining. Supplying
# the .tbi we can simply download skips a measured 1m07s TABIX_GERMLINE_RESOURCE task.
aria2c -x8 -s8 -c -d references \
    "$G/af-only-gnomad.hg38.vcf.gz" \
    "$G/af-only-gnomad.hg38.vcf.gz.tbi"

# The BWA-MEM1 index: 5.3 GB across five files that bwa needs to align reads to the genome.
# sarek will happily BUILD this itself, but that took a measured 1h14m50s. The Broad's
# published index is byte-identical to what that build produces, so this is a pure win.
#
# The rename matters: upstream the files are Homo_sapiens_assembly38.fasta.64.{amb,ann,...}
# ("64" is bwa's 64-bit index format), but bwa locates its index by taking the .amb/.ann/...
# siblings of a common prefix. sarek passes references/bwa as that prefix directory, so the
# names must match the FASTA's basename exactly — hence -o rewrites each one on arrival.
for e in amb ann bwt pac sa; do
    aria2c -x8 -s8 -c -d references/bwa -o "Homo_sapiens_assembly38.$e" \
        "$B/Homo_sapiens_assembly38.fasta.64.$e"
done

echo
echo "setup complete. Next: ./scripts/build_bed.sh, then the samplesheet, then ./scripts/run.sh"
