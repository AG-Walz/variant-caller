# Decision & Question Log

Running log of questions raised and decisions taken on the variant-caller project.
Append-only, newest entries at the bottom of each section. Each entry is dated.

- **DECISION** — a choice that has been made and is now in force.
- **QUESTION / OPEN** — something unresolved, waiting on data, a person, or a run.
- When an OPEN item is resolved, leave it in place and add a dated resolution line
  (reverse-in-place, so the history stays legible).

Authoritative long-form records currently live in the working tree's outer
`docs/` directory (NOT yet in this repo): `decisions-v5-fastq-first.md` (wins over
any other doc), `open-items.md`, `CHANGELOG.md`. This LOG is the fast index into them.

---

## Decisions

### 2026-07-22 — Ingest-first architecture (SUPERSEDED)
Original verdict was to ingest the vendor VCF. **Reversed 2026-07-23** (see below).
All *measurements* from the UrCa audit still stand; only this verdict was withdrawn.

### 2026-07-23 — Scope: FASTQ-first, minimal sarek, Mutect2
v1 = FASTQ + user-declared sample labels → one somatic VCF per patient. Nothing else.
Twelve decisions recorded in `decisions-v5-fastq-first.md`. Key points:
- Call from raw reads via a wrapped **stock sarek 3.9.0**, in `fastq-to-fasta`'s shape.
- Somatic caller is **Mutect2** (one file per pair, `AF` in FORMAT, real `tumor_sample`).
- **GRCh38** GATK bundle, `--igenomes_ignore true`. BQSR off. QC skippable in v1.
- Sample roles are **declared by the user, never inferred**; hard error on >1 normal/patient.
- Output *file* is normative (name with `_vs_`, populated FILTER, two named genotype
  columns, `##tumor_sample=`/`##normal_sample=`, `AF` in FORMAT); directory layout is not.
- Pilot **patient 11** (`S12944Nr11`/`S12944Nr12`) on `peptimine_highmem1`, in `screen`.
- Pilot passes on **mechanics only** — a well-formed `*.mutect2.filtered.vcf.gz`.

### 2026-07-24 — BED / target intervals: rebuild from stock Twist files
CeGaT's authoritative target `S000021_hg38_targets.bed` was not delivered (only an
unusable hg19 version was). Measurement proved CeGaT applied **no customization**, so we
rebuild from **kit vendor stock Twist files** via `bin/build_kit_bed.sh` (canonical):
`Twist_Exome_RefSeq_targets_hg38.bed` + `Twist_MitoPanel_chrM_all_hg38_target.bed`
(union 215,624 regions; 215,623 match this run's DRAGEN counts exactly).
Padding **30 bp** (matches CeGaT) → 214,494 regions / 49,633,134 bp.
`build_kit_bed.sh --fai <ref>.fai` clamps padded chrM to contig length (GATK rejects
out-of-bounds intervals). `bin/build_target_bed.sh` (recover-from-counts) is now
verification-only. Full detail: memory `urca-capture-kit-and-bed`.

### 2026-07-24 — v1 pre-pilot audit: four defects fixed
Committed in `aca2c15` on `feat/v1-pilot`: (1) `--trim_fastq` added so `--trim_nextseq`
is not a silent no-op; (2) `assert_output.py` now fails on zero-PASS VCF; (3) samplesheet
CSV demoted to an example, regenerated per-host; (4) `--save_reference` added (index build
~87 GB RAM). Rest of the pipeline verified sound.

### 2026-07-24 — v3 goal set (does NOT change v1)
Supervisor: replace CeGaT exome bioinformatics **Levels 2–5** (consume Level 1 FASTQ+CSV).
Five gaps identified; only **ROH calling** (`bcftools roh`) is genuinely missing from
sarek. Reopens germline calling, in-pipeline annotation, QC, and the output contract —
for v3, not v1. Full detail: memory `variant-caller-v3-goal`, `roadmap.md`.

---

## Open questions

- **[OPEN] The pilot has never been run.** Blocking gate for merging `feat/v1-pilot`.
  Must run on `peptimine_highmem1` (503 GB, docker, needs Nextflow installed), in `screen`.
  `nacho` cannot run it (62 GB RAM < ~87 GB index build).
- **[OPEN] Reference ALT handling for strict concordance.** DRAGEN used ALT-masked GRCh38;
  our `fetch_references.sh` pulls GRCh38 with ALTs. Same coords, different ALT handling.
- **[OPEN] Which CeGaT product are we replacing?** The Level 1–5 list is their exome/germline
  service ("trio filtering" is family-shaped), but the UrCa data is tumour/normal somatic
  (their CTP somatic product).
- **[OPEN] What does "replace" mean** — byte-comparable, concordant calls, or same analytical
  scope in our own formats?
- **[OPEN] External-dependent items** (not design debt): concordance for the 8 non-pilot
  patients (waits on pilot), who computes purity (Phase 3), expression source (req #6),
  hotspot list owner (clinical), GHGA governance.
