# Changelog

## 0.1.0 — 2026-09-01

First release. Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0 with Mutect2: two editable shell scripts,
a resource config, and a samplesheet.

Requires Docker, Java 17+, `bedtools`, `bcftools` and Nextflow 25.10.x.
