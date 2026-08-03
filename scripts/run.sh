#!/usr/bin/env bash
#
# run.sh — launch the pipeline.
#
#   ./scripts/run.sh              run it
#   ./scripts/run.sh -preview     validate every parameter and path, then exit (~40 s)
#   ./scripts/run.sh -with-report report.html      (anything you pass reaches nextflow)
#
# Everything that decides WHAT is computed lives in params/pilot.yaml; everything that
# decides HOW MUCH MACHINE it gets lives in nextflow.config. This script only assembles
# the invocation, so there is nothing here to tune.
#
# BEFORE THIS WORKS you need, in order: ./scripts/setup.sh (toolchain + references +
# ../sarek), ./scripts/build_bed.sh (the target), and assets/samplesheet_pilot.csv
# (copy assets/samplesheet_template.csv and edit it). nf-schema checks all of those
# paths at launch and aborts before starting a single task if one is missing.

set -euo pipefail          # see setup.sh for what these three do
cd "$(dirname "$0")/.."    # nextflow resolves the relative paths in params/pilot.yaml
                           # against the directory it is LAUNCHED from, so this line is
                           # what lets you call the script from anywhere.

# --- the IPv6 workaround ----------------------------------------------------------------
#
# sarek's own nextflow.config ends with `includeConfig "${params.custom_config_base}/..."`,
# an https include of the nf-core institutional config. Fetching it is done by the JVM, and
# the JVM prefers IPv4 addresses when DNS returns both. On a box with no IPv4 route to the
# internet that fetch fails, and a failed config include is fatal: the run dies with
# "Unable to parse config file" before nextflow has looked at a single parameter. curl on
# the same box succeeds, which makes this look like a nextflow bug rather than a routing one.
#
# Telling the JVM to try IPv6 first fixes it. NXF_OPTS is passed through to the JVM by the
# nextflow launcher. "${NXF_OPTS:-...}" means an NXF_OPTS you set yourself still wins.
#
# NXF_OFFLINE=true is NOT an alternative. sarek's include is guarded so that offline mode
# skips it, but the run then fails schema validation instead — measured, not assumed.
export NXF_OPTS="${NXF_OPTS:--Djava.net.preferIPv6Addresses=true}"

# --- the invocation ---------------------------------------------------------------------
#
# exec replaces this shell with nextflow, so Ctrl-C and exit codes reach you directly
# instead of being swallowed by a wrapper process.
#
#   run ../sarek        the pipeline is the sibling clone, stock and unmodified. A path
#                       rather than a name, so nextflow never tries to resolve or update it.
#   -profile docker     turn on Docker as the container engine. This is the ONLY thing
#                       specified on the command line rather than in a file, because a
#                       profile is not a parameter — it selects a config block inside sarek.
#   -c nextflow.config  our resource overrides: the executor's total CPU/memory cap and the
#                       two per-process blocks. Resources only, no parameters, so the sarek
#                       clone stays provably stock.
#   -params-file        every sarek parameter, in one file with the reason for each. Passing
#                       these as flags once produced an orphaned run from a truncated paste;
#                       a file cannot be half-pasted.
#   -w work             the scratch directory: one subdirectory per task, holding its inputs
#                       (symlinked), its rendered command and its outputs. It grows to tens
#                       of GB — it is gitignored, and it is safe to delete once a run is
#                       finished and results/ is published, but deleting it also deletes
#                       everything -resume could have reused.
#   -resume             reuse any task whose inputs, container and rendered command line are
#                       unchanged since a previous run in this work directory. Always on:
#                       on a fresh work dir it is a no-op, and after an interruption it is
#                       the difference between minutes and 17 hours. Caveat worth knowing:
#                       the rendered command IS part of that identity, so changing a
#                       process's `cpus` in nextflow.config invalidates every task whose
#                       tool threads by $task.cpus (fastp does; mutect2 and markduplicates
#                       do not) plus everything downstream of it.
#   "$@"                your extra arguments, last so they can override anything above.
exec nextflow run ../sarek \
    -profile docker \
    -c nextflow.config \
    -params-file params/pilot.yaml \
    -w work \
    -resume \
    "$@"

# Output lands in results/variant_calling/mutect2/<tumour>_vs_<normal>/ as
# <tumour>_vs_<normal>.mutect2.filtered.vcf.gz — the FilterMutectCalls output, which is
# what you want — beside the unfiltered .mutect2.vcf.gz, which you almost certainly do not.
