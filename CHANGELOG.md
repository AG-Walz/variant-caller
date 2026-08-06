# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-08-06

First working version: **tumour/normal FASTQ → one paired somatic VCF per patient**, by running
stock [nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0 from the hub. The purpose is an
independent call set, to check whether the sequencing vendor's own run was done correctly.

The pipeline is two editable shell templates. Everything else in this repository is documentation.
Why it is shaped this way: [DECISIONS.md](DECISIONS.md).

### Added

- `scripts/build_bed.sh` — capture-kit BEDs → one target BED for `--intervals`, the only input
  sarek will not build for you. `cat | bedtools sort -faidx | merge | slop -g | merge`, padding
  set at the top. This cohort's two Twist files at 30 bp give 214,494 regions / 49,633,134 bp,
  md5 `69ed88c5131c8613efe5e20e66954e74`. See [docs/target-bed.md](docs/target-bed.md).
- `scripts/run.sh` — the pinned `nextflow run nf-core/sarek -r 3.9.0`, every parameter inline.
  Always passes `-resume`; `-preview` validates paths in ~40 s without launching. See
  [docs/parameters.md](docs/parameters.md).
- `nextflow.config` — resource overrides only, no params and no container engine, so the pipeline
  stays provably stock. Every number is a measurement: MarkDuplicates 60 GB against a 42.5 GB
  observed peak, Mutect2 4 cpus as the concurrency knob for 83 shards under a 26-cpu cap.
- `assets/samplesheet_template.csv` — two-row tumour/normal example.
- `DECISIONS.md` — the choices behind the pipeline, each with the reason it was made.
- `docs/parameters.md` — every flag in `run.sh`, why it is set, and what is deliberately not set.
- `docs/target-bed.md` — building the target, choosing the padding, and why `cat` beats every
  published BED-joining tool for this job.
- `docs/README.md` — documentation index.

### Changed

- **The samplesheet is sarek's native format**, `patient,sex,status,sample,lane,fastq_1,fastq_2`.
  The scaffold documented a bespoke format with `type`, `organ`, `kit` and `alleles` columns; none
  of it is read by anything. `status` is binary — 1 = tumour, 0 = normal. The clinical labels
  (`tumour` / `tumour_adjacent` / `control_healthy` / `control_benign`) become a future GUI's input
  contract rather than a CLI one.
- **References are not downloaded.** `--genome GATK.GRCh38` fetches FASTA, `.fai`, `.dict`, the
  gnomAD germline resource, the BWA index, dbSNP and known indels from `s3://ngi-igenomes/igenomes/`
  on first run. This also brings a 1000g panel of normals and BQSR, both wanted here.
- `README.md` rewritten to prerequisites and three steps; the detail moved to `docs/`.
- `docs/usage.md` rewritten around the real samplesheet, plus the failure modes that cost real
  time — a swapped `status`, a patient with no normal running tumour-only and completing, a
  name-ordered BED dying 30 minutes in, Docker layers filling `/var/lib/containerd`.
- `docs/output.md` rewritten to the real output paths, with the checks worth running by hand and
  an explicit list of what nothing checks any more.
- `.gitignore` covers Nextflow run artefacts, references and reads, containers and local notes.

### Removed

- `docs/introduction.md` and `docs/inputs.md` — they described a design that no longer exists: a
  kit registry, per-sample `organ` and `alleles`, and a tumour-only fallback for patients with no
  normal. Paired calling is now the only mode.

### Requirements

Docker, Java 17+, `bedtools`, and **Nextflow 25.10.x**. sarek 3.9.0 pins `!>=25.10.2`, a hard
failure rather than a warning, and 26.x aborts on a valid paired samplesheet.

### Scope

Paired somatic calling only: no tumour-only mode, no annotation, one caller. Annotation happens
downstream in [nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction).

Deliberately left open, not decided: a cohort-specific panel of normals, and concordance against
the vendor's call set, which has never been measured.
