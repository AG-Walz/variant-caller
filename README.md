# AG-Walz/variant-caller

Turn tumour/normal **FASTQ** plus **declared sample labels** into **one somatic VCF per
patient**. Nothing else.

v1 is a lean orchestration repo: it does not reimplement variant calling. It **wraps a
sibling [nf-core/sarek](https://github.com/nf-core/sarek) clone** (tag 3.9.0, upstream) with
a single, deliberately minimal invocation and guards the result with a strict output
assertion. Think "shell script around `nextflow run`", not "DSL2 pipeline".

## What it does (v1)

```
FASTQ (tumour + its normal)                 one nextflow run of the local sarek clone
+ samplesheet.csv (patient, status, FASTQ)      ─────────────────────────────────────────►
                                            variant_calling/<T>_vs_<N>/
                                              <T>_vs_<N>.mutect2.filtered.vcf.gz
```

For each patient the pipeline aligns the reads, marks duplicates, and runs GATK **Mutect2**
in **paired** tumour-vs-normal mode over the capture target, then FilterMutectCalls. The one
deliverable is a bgzipped, FILTER-populated, AF-bearing somatic VCF whose two genotype
columns are the declared tumour and normal samples.

## What it does NOT do (v1 — all of this is v2 or downstream)

- **No kit registry / bait BED / hybrid-capture QC.** One target BED, built once from the
  capture kit vendor's files. No capture-efficiency metrics.
- **No tumour-only mode.** v1 is paired somatic only. A patient without exactly one normal
  is a hard error, not a fallback.
- **No role inference.** Labels and patient grouping are *declared* by the user, never
  guessed from filenames.
- **No annotation / VEP, no normalisation, no consequence filtering.** The VCF is emitted as
  FilterMutectCalls leaves it. Annotation is done downstream by
  [nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction).
- **No epitopeprediction handoff samplesheet.**
- **No BQSR** (base recalibration is switched off), no multiple callers, no MultiQC, no GUI.

These are not oversights; they are scope. Some are planned for v2 behind the same output
contract; some belong to other pipelines.

**Where this is going:** v3's goal is to replace CeGaT's exome bioinformatics **Levels 2–5** —
take Level 1 (FASTQ + CSV) and deliver mapping, SNV/indel **and ROH** calling, annotation, CNV
calling and variant comparison. See **[docs/roadmap.md](docs/roadmap.md)**.

## How to run

```bash
# 1. the target BED (once per reference)
FAI=references/Homo_sapiens_assembly38.fasta.fai
T=https://www.twistbioscience.com/content/dam/twistbioscience/resources
cat <(curl -sL $T/2019-09/Twist_Exome_RefSeq_targets_hg38.bed) \
    <(curl -sL $T/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed) \
  | bedtools sort -faidx $FAI | bedtools merge -i - \
  | bedtools slop -i - -g $FAI -b 30 | bedtools merge -i - > references/target_pad30.bed

# 2. the run
nextflow run ../sarek -profile docker -c nextflow.config -params-file params/pilot.yaml -w work -resume
```

Full runbook — toolchain pins, the reference download, the samplesheet, and the optional
sanity checks: [docs/steps.md](docs/steps.md).

## Layout

```
params/pilot.yaml                every sarek parameter, with the reason for each
nextflow.config                  resource overrides for the run box
assets/samplesheet_template.csv  copy, edit, point params/pilot.yaml at it
references/                      the target BED and the reference .fai (git-ignored bundle)
docs/                            introduction, steps, the output contract, roadmap
```

**There is no code in this repository.** The interval arithmetic is bedtools', the pipeline is
stock [nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0 cloned as a sibling at `../sarek`
and never modified, and everything this project decides lives in `params/pilot.yaml`.

Requires `bedtools`, `curl`, and — to run — Nextflow **25.10.x**, Java 17+ and Docker.
