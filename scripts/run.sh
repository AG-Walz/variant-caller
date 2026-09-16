#!/usr/bin/env bash
# Copy this file, edit the variables, run it. Add -preview to validate paths without running.

SAREK=3.9.0                             # Sarek version
PROFILE=docker                          # Nextflow profile to use (docker, singularity, conda, test, etc.)
WORKDIR=work                            # Nextflow work directory
SAMPLESHEET=assets/samplesheet.csv      # Samples to analyze
OUTDIR=results                          # Output directory
INTERVALS=references/target_pad30.bed   # bed file (OUTPUT of build_bed.sh)
TOOLS=mutect2,strelka,manta,haplotypecaller  # Callers. Manta only feeds Strelka indel candidates; HaplotypeCaller only calls germline
TUMOUR_VS_NORMAL=true                   # paired somatic calls, <tumour>_vs_<normal>
TUMOUR_VS_REF=false                     # each tumour alone against the reference
NORMAL_VS_REF=true                      # each normal alone against the reference: the germline VCF epitopeprediction needs

# The JVM prefers IPv4; on an IPv6-only host sarek's https config include fails and the run
# dies before reading a parameter.
export NXF_OPTS="-Djava.net.preferIPv6Addresses=true"

COMMON=(-r ${SAREK} -profile ${PROFILE} -c nextflow.config -work-dir ${WORKDIR}
        --genome GATK.GRCh38 --wes true --intervals ${INTERVALS}
        --only_paired_variant_calling true --nucleotides_per_second 1000 -resume "$@")

[[ ${TUMOUR_VS_NORMAL} == true ]] && PAIRED_TOOLS="--tools ${TOOLS}"

nextflow run nf-core/sarek "${COMMON[@]}" \
    --input ${SAMPLESHEET} \
    --outdir ${OUTDIR} \
    ${PAIRED_TOOLS} \
    --markduplicates_pixel_distance 2500 \
    --trim_fastq true \
    --trim_nextseq true \
    --save_reference true || exit 1

[[ ${TUMOUR_VS_REF} == true || ${NORMAL_VS_REF} == true ]] || exit 0
[[ " $* " == *" -preview "* ]] && exit 0    # the CRAMs below do not exist yet

# Every selected sample twice, each as its own patient: status 1 reaches the tumour-only callers
# (Mutect2, Manta), status 0 the germline callers (Strelka, HaplotypeCaller). sarek has no other
# way to call one sample against the reference.
SINGLE=${OUTDIR}/vs_reference/samplesheet.csv
mkdir -p "$(dirname ${SINGLE})"
awk -F, -v t=${TUMOUR_VS_REF} -v n=${NORMAL_VS_REF} 'NR == 1 { print; next }
    ($3 == 1 && t == "true") || ($3 == 0 && n == "true") {
        print $4 "_only,"     $2 ",1," $4 "," $5 "," $6
        print $4 "_germline," $2 ",0," $4 "," $5 "," $6 }' \
    ${OUTDIR}/csv/recalibrated.csv > ${SINGLE}

nextflow run nf-core/sarek "${COMMON[@]}" \
    --step variant_calling \
    --input ${SINGLE} \
    --outdir ${OUTDIR}/vs_reference \
    --tools ${TOOLS}
