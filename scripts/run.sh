#!/usr/bin/env bash
#
# run.sh — launch the pipeline.
#
#   usage: run.sh <sarek-dir> <params-file> <config-file> [extra nextflow arguments]
#   e.g.:  ./scripts/run.sh ../sarek params/pilot.yaml nextflow.config
#          ./scripts/run.sh ../sarek params/pilot.yaml nextflow.config -preview
#
# -preview validates every parameter and path and exits in ~40 s without launching a task.
# Anything else you add is passed straight to nextflow (-with-report report.html, -stub, ...).
#
# Everything that decides WHAT is computed lives in the params file; everything that decides
# HOW MUCH MACHINE it gets lives in the config file. There is nothing here to tune.
#
# RUN IT FROM THE DIRECTORY YOUR PARAMS FILE'S PATHS ARE RELATIVE TO — the repo root, if you
# are using params/pilot.yaml as shipped. This script deliberately does not cd anywhere:
# nextflow resolves relative paths in a params file against the directory it is launched
# from, so a script that quietly moved you elsewhere would make those paths mean something
# different from what they say. If you get it wrong, nf-schema aborts at launch naming the
# path it could not find, before any task starts.
#
# BEFORE THIS WORKS you need setup.sh (toolchain, sarek, references), build_bed.sh (the
# target BED), and the samplesheet your params file's `input:` points at.

# Long-form names for what `set -euo pipefail` means, because the short flags are unreadable:
#   errexit   stop at the first failing command
#   nounset   a misspelled variable is an error, not a silently empty string
#   pipefail  a failure anywhere in a | pipeline fails the whole pipeline
set -o errexit -o nounset -o pipefail

if [ $# -lt 3 ]; then
    echo "usage: $0 <sarek-dir> <params-file> <config-file> [extra nextflow arguments]" >&2
    echo "  e.g. $0 ../sarek params/pilot.yaml nextflow.config -preview" >&2
    exit 1
fi
SAREKDIR=$1
PARAMS=$2
CONFIG=$3
shift 3

# --- the IPv6 workaround ------------------------------------------------------------------
#
# sarek's own nextflow.config ends with `includeConfig "${params.custom_config_base}/..."`,
# an https include of the nf-core institutional config. That fetch is done by the JVM, and
# the JVM prefers IPv4 addresses when DNS returns both. On a host with no IPv4 route to the
# internet it fails, and a failed config include is fatal: the run dies with "Unable to parse
# config file" before nextflow has looked at a single parameter. curl on the same host
# succeeds, which makes this look like a nextflow bug rather than a routing one.
#
# Telling the JVM to try IPv6 first fixes it. NXF_OPTS is passed to the JVM by the nextflow
# launcher, and "${NXF_OPTS:-...}" means an NXF_OPTS you set yourself still wins.
#
# NXF_OFFLINE=true is NOT an alternative. sarek's include is guarded so offline mode skips
# it, but the run then fails schema validation instead — measured, not assumed.
export NXF_OPTS="${NXF_OPTS:--Djava.net.preferIPv6Addresses=true}"

# --- the invocation -------------------------------------------------------------------------
#
# exec replaces this shell with nextflow, so Ctrl-C and exit codes reach you directly instead
# of being swallowed by a wrapper process.
#
#   run "$SAREKDIR"   the pipeline is a local clone, stock and unmodified. A path rather than
#                     a name, so nextflow never tries to resolve or update it from the hub.
#   -profile docker   turn on Docker as the container engine. The one thing specified here
#                     rather than in a file, because a profile is not a parameter — it
#                     selects a config block defined inside sarek.
#   -c "$CONFIG"      resource overrides: the executor's total CPU/memory cap and the
#                     per-process blocks. Resources only, no parameters, so the sarek clone
#                     stays provably stock.
#   -params-file      every sarek parameter in one file, with the reason for each. Passing
#                     these as flags once produced an orphaned run from a truncated paste;
#                     a file cannot be half-pasted.
#   -resume           reuse any task whose inputs, container and rendered command line are
#                     unchanged since a previous run in this work directory. Always on: on a
#                     fresh work dir it is a no-op, and after an interruption it is the
#                     difference between minutes and 17 hours. Caveat worth knowing: the
#                     rendered command IS part of that identity, so changing a process's
#                     `cpus` in the config invalidates every task whose tool threads by
#                     $task.cpus (fastp does; mutect2 and markduplicates do not), and
#                     everything downstream of it.
#   "$@"              your extra arguments, last, so they can override anything above.
#
# The work directory is not set here: nextflow defaults it to ./work in the directory you
# launch from, which is the same place the params file's relative paths resolve against.
# It grows to tens of GB, it is gitignored, and deleting it is safe once results/ exists —
# but deleting it also deletes everything -resume could have reused.
exec nextflow run "$SAREKDIR" \
    -profile docker \
    -c "$CONFIG" \
    -params-file "$PARAMS" \
    -resume \
    "$@"

# Output lands in <outdir>/variant_calling/mutect2/<tumour>_vs_<normal>/ as
# <tumour>_vs_<normal>.mutect2.filtered.vcf.gz — the FilterMutectCalls output, which is what
# you want — beside the unfiltered .mutect2.vcf.gz, which you almost certainly do not.
