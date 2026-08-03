#!/usr/bin/env bash
#
# setup.sh — everything that has to exist on a machine before a run is possible.
#
#   usage: setup.sh <file-list> <references-dir> <sarek-dir>
#   e.g.:  ./scripts/setup.sh assets/references.txt references ../sarek
#
# It does three things:
#   1. refuses to continue unless the six required commands are on PATH
#   2. clones nf-core/sarek 3.9.0 into <sarek-dir>, if that directory does not exist
#   3. downloads every file in <file-list> into <references-dir>
#
# WHICH files those are is not this script's business — it is data, in the file you pass.
# assets/references.txt is the GRCh38 bundle this pipeline was validated against; edit it,
# or point at your own list, to fetch a different genome or use an internal mirror.
#
# Re-run it whenever you like: the clone is skipped if present and every download resumes
# where it stopped, so a re-run after an interruption costs only what is missing.
#
# WHAT IT DOES NOT DO: build the target BED (scripts/build_bed.sh, because it changes per
# capture kit) or write the samplesheet (host-specific — see the README).

# Long-form names for what `set -euo pipefail` means, because the short flags are unreadable:
#   errexit   stop at the first failing command, rather than continuing with half a reference
#   nounset   a misspelled variable is an error, not a silently empty string
#   pipefail  a failure anywhere in a | pipeline fails the whole pipeline
set -o errexit -o nounset -o pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <file-list> <references-dir> <sarek-dir>" >&2
    echo "  e.g. $0 assets/references.txt references ../sarek" >&2
    exit 1
fi
LIST=$1
REFDIR=$2
SAREKDIR=$3

# --- 1. the toolchain -------------------------------------------------------------------
#
#   nextflow  the workflow engine. MUST be 25.10.x: sarek 3.9.0 requires >=25.10.2, but
#             get.nextflow.io currently installs 26.04.6, under which this exact pipeline
#             aborts on a valid paired samplesheet.
#   java      nextflow is a JVM program; 17+ is required, 21 is what we run on.
#   docker    every tool sarek calls (bwa, gatk, fastp...) runs in a container. Nothing
#             bioinformatic is installed on the host, which is why this list is so short.
#   bedtools  used by build_bed.sh; checked here so you find out now and not three steps on.
#   aria2c    a parallel, resumable downloader. curl would work but takes far longer on the
#             two 3.2 GB files and cannot resume a half-finished one as cleanly.
#   curl      used by build_bed.sh to fetch capture-kit BEDs by URL.
#
# All the missing names are collected before reporting, so you install them in one go rather
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
# This repo contains no pipeline logic: it runs *stock* sarek, unmodified. `-c
# nextflow.config -params-file params/pilot.yaml` is the whole contribution.
#
# The tag is the one hardcoded thing in these scripts, deliberately. Where files live is
# your choice; which sarek this is validated against is not — 3.9.0 is the version every
# measurement in DECISIONS.md was made on. --depth 1 skips the history, turning a ~400 MB
# clone into ~40 MB. An existing directory is left completely alone, including any local
# changes to it, which is why the README calls it read-only.
[ -d "$SAREKDIR" ] || git clone --branch 3.9.0 --depth 1 https://github.com/nf-core/sarek.git "$SAREKDIR"

# --- 3. the reference files ---------------------------------------------------------------
#
# Each line of <file-list> is a URL, a tab, and where that file should land relative to
# <references-dir>. `read -r url dest` splits on whitespace and -r stops backslashes being
# treated as escapes. The `|| [ -n "$url" ]` catches a final line with no trailing newline.
while read -r url dest || [ -n "$url" ]; do
    # Skip blank lines and comments, so the list can explain itself.
    case "$url" in ''|'#'*) continue ;; esac

    # A destination may name a subdirectory (bwa/...), so make it before downloading into it.
    mkdir -p "$REFDIR/$(dirname "$dest")"

    # aria2c flags:
    #   -x8  up to 8 connections to the server for this file
    #   -s8  split it into 8 parts fetched in parallel   (-x and -s work as a pair)
    #   -c   CONTINUE a partial file rather than restarting it. This is what makes an
    #        interrupted setup.sh cheap to re-run, and a finished one nearly a no-op.
    #   -d   the directory to write into
    #   -o   the filename to write, which is how a URL can be renamed on arrival
    aria2c -x8 -s8 -c -d "$REFDIR/$(dirname "$dest")" -o "$(basename "$dest")" "$url"
done < "$LIST"

echo
echo "setup complete: sarek at $SAREKDIR, files from $LIST in $REFDIR/"
