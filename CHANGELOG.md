# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-07-23

First working v1: **FASTQ + declared sample labels → one paired somatic VCF per patient**, by
wrapping a sibling clone of upstream nf-core/sarek (tag 3.9.0, at `../sarek`) with a single
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
  `--markduplicates_pixel_distance 2500 --trim_fastq --trim_nextseq --save_reference
  --nucleotides_per_second 1000 -resume`).
- `bin/assert_output.py` — enforce the output contract on the produced VCF (pure python3+gzip).
- `assets/pilot_declarations.tsv` and `assets/samplesheet_pilot_example.csv` — example inputs.
- `nextflow.config` — minimal per-process resource override passed to sarek via `-c`.
- `tests/` — dependency-light soundness checks for the helper tools.
- Rewritten docs to match v1: `README.md`, `docs/inputs.md`, `docs/usage.md`,
  `docs/output.md`, new `docs/steps.md` runbook, and `CLAUDE.md`.

### Contract

- **Deliverable:** `variant_calling/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz` — bgzipped,
  FILTER not uniformly `.`, **at least one `PASS` record**, exactly two genotype columns named
  for the declared tumour and normal, `##tumor_sample=`/`##normal_sample=` matching, `FORMAT`
  contains `AF`, GRCh38 contigs present.
  Pilot: `S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz`.
- **Validator:** every sample has a declared label; exactly one `status=0` and at least one
  `status=1` per patient; zero-normal patients are rejected — **v1 is paired somatic only**.

### Scope (deliberately out of v1 — v2 or downstream)

Kit registry / bait BED / hybrid-capture QC; tumour-only mode; preference-ordered normal
selection; epitopeprediction handoff samplesheet; annotation / VEP; multiple callers; BQSR
(switched off); MultiQC / QC bundle; a GUI.

## [Unreleased]

### Fixed

- **`--trim_nextseq` was a silent no-op.** sarek gates FASTP on
  `params.trim_fastq || params.split_fastq > 0 || params.umi_location`
  (`subworkflows/local/fastq_preprocess_gatk/main.nf:107`), so the flag alone meant FASTP never
  ran — no poly-G trim, no adapter trim, and no warning. `run_pilot.sh` now also passes
  `--trim_fastq`. The reads are NovaSeq 6000 (2-colour chemistry), where poly-G tails are real.

### Added

- `--save_reference` in `run_pilot.sh`, so the ~87 GB / ~1 h bwa-mem2 index build is published
  to `<outdir>/reference` and can be reused via `--bwamem2` for the remaining patients instead
  of rebuilt (sarek's default is `save_reference = false`).
- **Output contract: at least one `PASS` record.** A VCF where FilterMutectCalls rejected every
  record passed every structural check while making downstream `bcftools view -f PASS` yield an
  empty file with no error. `assert_output.py` now fails on `n_pass == 0` (check `filter-pass`).
- `run_pilot.sh` pre-flight: every FASTQ named in the samplesheet must exist on this box.
  sarek's `schema_input.json` sets `"exists": true` on `fastq_1`/`fastq_2`, so a samplesheet
  carrying another machine's absolute paths is a hard launch failure; the check names the
  missing files and the `build_samplesheet.py` command that fixes them.

- `scripts/setup_env.sh` — one-time bootstrap for a fresh box: clones the sibling `../sarek` at
  tag 3.9.0 (which `run_pilot.sh` resolves **by path**, so the repos must be siblings) and
  installs Nextflow at the required version. Idempotent, and installs no system packages: Java
  and Docker need root and a policy decision on a shared box, so it detects them and prints the
  install command rather than running it.
- `tests/check_environment.sh` — read-only preflight answering "can this box run the pipeline?".
  PASS/FAIL/WARN per requirement (Java 17+, Nextflow ≥ 25.10.2, usable Docker, python3/awk/curl/
  git, sarek sibling at 3.9.0 and unmodified, references, samplesheet FASTQs resolvable, free
  disk, RAM ≥ 100 GB for the bwa-mem2 index build), non-zero exit on any hard failure.

### Changed

- `assets/samplesheet_pilot_example.csv` is documented as an **example** only. The samplesheet
  is now expected to be regenerated on whichever box runs the pipeline; the declarations TSV is
  the portable artefact.

### Corrected

- **sarek 3.9.0 is public and this clone is stock.** `CLAUDE.md`, `README.md` and `docs/usage.md`
  claimed the wrapped clone was "customised" and that "there is no public sarek 3.9.0". Both are
  false: tag `3.9.0` is published on `nf-core/sarek` at `b97952e`, and the local clone is
  identical to it with no local modifications. A new box reproduces it with `git clone` +
  `git checkout 3.9.0`.
- **Prerequisites were wrong.** `docs/steps.md` said Nextflow "needs Java 11+". sarek 3.9.0 pins
  `nextflowVersion = '!>=25.10.2'` — a hard failure, not a warning — and Nextflow 25.10 requires
  **Java 17+**. A box provisioned per the old instructions would have failed at launch.
