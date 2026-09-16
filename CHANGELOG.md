# Changelog

## Unreleased

- `--tools mutect2,strelka,manta`: Strelka as an independent second caller, Manta only as its indel
  candidate source. `--only_paired_variant_calling true` stops sarek calling germline variants on
  the normal, which any tool with a germline mode otherwise does.
- `nextflow.config`: `STRELKA_.*` at 2 cpus / 4 GB, sized from the trace.
- `run.sh`: `TOOLS`, `TUMOUR_VS_NORMAL`, `TUMOUR_VS_REF` and `NORMAL_VS_REF` variables. The two
  `_VS_REF` switches add a second sarek run from the recalibrated CRAMs that calls each selected
  sample alone, once as tumour-only and once as germline, under `results/vs_reference/`.

## 0.1.0 — 2026-09-01

First release. Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0 with Mutect2: two editable shell scripts,
a resource config, and a samplesheet.

Requires Docker, Java 17+, `bedtools`, `bcftools` and Nextflow 25.10.x.
