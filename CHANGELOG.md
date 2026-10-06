# Changelog

## Unreleased

- `--tools mutect2,strelka,manta`: Strelka as an independent second caller, Manta only as its indel
  candidate source. `--only_paired_variant_calling true` stops sarek calling germline variants on
  the normal, which any tool with a germline mode otherwise does.
- `nextflow.config`: `STRELKA_.*` at 2 cpus / 4 GB, sized from the trace.
- `run.sh`: `TOOLS`, `TUMOUR_VS_NORMAL`, `TUMOUR_VS_REF` and `NORMAL_VS_REF` variables. The two
  `_VS_REF` switches add a second sarek run from the recalibrated CRAMs that calls each selected
  sample alone, once as tumour-only and once as germline, under `results/vs_reference/`.
- `haplotypecaller` in the default `TOOLS` and `NORMAL_VS_REF` on by default, so every run also
  yields a filtered germline VCF per normal, the context epitopeprediction needs to build mutant
  peptides on the patient's own sequence (#4, @axelwalter).
- `run.sh` writes `results/vcf_check.tsv` when it finishes: genotype columns, records and PASS
  calls per VCF. `docs/reference.md` lists the values measured on the pilot pair to read it
  against. Mutect2 tumour-only passed 682 calls on a normal against 734 paired, so that output is
  documented as germline background, not a somatic call set.
- `TUMOUR_VS_REF` on by default too, so one run of `run.sh` gives all three comparisons — paired
  somatic, tumour-alone, normal-alone/germline — without editing the switches. `OUTDIR`'s comment
  now says to name it per run; `WORKDIR` stays shared across runs so `-resume` keeps reusing its
  cache.

## 0.1.0 — 2026-09-01

First release. Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0 with Mutect2: two editable shell scripts,
a resource config, and a samplesheet.

Requires Docker, Java 17+, `bedtools`, `bcftools` and Nextflow 25.10.x.
