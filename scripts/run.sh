#!/usr/bin/env bash
# Copy this file, edit the variables, run it. Add -preview to validate paths without running.

SAREK=3.9.0
PROFILE=docker
WORKDIR=work
SAMPLESHEET=assets/samplesheet.csv
OUTDIR=results
INTERVALS=references/target_pad30.bed

# The JVM prefers IPv4; on an IPv6-only host sarek's https config include fails and the run
# dies before reading a parameter. Harmless everywhere else.
export NXF_OPTS="-Djava.net.preferIPv6Addresses=true"

nextflow run nf-core/sarek \
    -r ${SAREK} \
    -profile ${PROFILE} \
    -c nextflow.config \
    -work-dir ${WORKDIR} \
    --input ${SAMPLESHEET} \
    --outdir ${OUTDIR} \
    --genome GATK.GRCh38 \
    --wes true \
    --intervals ${INTERVALS} \
    --tools mutect2 \
    --nucleotides_per_second 1000 \
    --markduplicates_pixel_distance 2500 \
    --trim_fastq true \
    --trim_nextseq true \
    --save_reference true \
    -resume \
    "$@"
