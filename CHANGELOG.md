# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-07-23

First working v1: **FASTQ + declared sample labels → one paired somatic VCF per patient**, by
wrapping the local, customised nf-core/sarek clone (tag 3.9.0, at `../sarek`) with a single
pinned, minimal invocation. This reverses the earlier ingest-first / fuller-scope design in
favour of a lean FASTQ-first orchestration repo mirroring the sibling `fastq-to-fasta` shape.

### Added

- `scripts/fetch_references.sh` — download GRCh38 (`Homo_sapiens_assembly38.fasta` + `.fai` +
  `.dict`) and the gnomAD germline resource (`af-only-gnomad.hg38.vcf.gz`).
- `bin/build_target_bed.sh` — build a 3-column, 30 bp-padded target BED from the DRAGEN target
  set.
- `bin/build_samplesheet.py` — merge a declarations TSV (sample → patient → label) with FASTQ
  auto-discovery, validate, and emit the sarek samplesheet
  (`patient,sex,status,sample,lane,fastq_1,fastq_2`).
- `scripts/run_pilot.sh` — the pinned minimal `nextflow run ../sarek` for the pilot pair
  (`-profile docker`, `--step mapping --tools mutect2 --wes`, explicit references,
  `--germline_resource`, `--skip_tools baserecalibrator,fastqc,mosdepth,samtools,multiqc,bcftools,vcftools`,
  `--markduplicates_pixel_distance 2500 --trim_nextseq --nucleotides_per_second 1000 -resume`).
- `bin/assert_output.py` — enforce the output contract on the produced VCF (pure python3+gzip).
- `assets/pilot_declarations.tsv` and `assets/samplesheet_pilot_example.csv` — example inputs.
- `nextflow.config` — minimal per-process resource override passed to sarek via `-c`.
- `tests/` — dependency-light soundness checks for the helper tools.
- Rewritten docs to match v1: `README.md`, `docs/inputs.md`, `docs/usage.md`,
  `docs/output.md`, new `docs/steps.md` runbook, and `CLAUDE.md`.

### Contract

- **Deliverable:** `variant_calling/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz` — bgzipped,
  FILTER not uniformly `.`, exactly two genotype columns named for the declared tumour and
  normal, `##tumor_sample=`/`##normal_sample=` matching, `FORMAT` contains `AF`, GRCh38
  contigs present. Pilot: `S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz`.
- **Validator:** every sample has a declared label; exactly one `status=0` and at least one
  `status=1` per patient; zero-normal patients are rejected — **v1 is paired somatic only**.

### Scope (deliberately out of v1 — v2 or downstream)

Kit registry / bait BED / hybrid-capture QC; tumour-only mode; preference-ordered normal
selection; epitopeprediction handoff samplesheet; annotation / VEP; multiple callers; BQSR
(switched off); MultiQC / QC bundle; a GUI.

## [Unreleased]

- Nothing yet.
