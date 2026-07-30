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
bin/vc.py bed --out references/target_pad30.bed --fai references/Homo_sapiens_assembly38.fasta.fai
cp assets/samplesheet_template.csv assets/samplesheet_pilot.csv   # then edit it
bin/vc.py sheet assets/samplesheet_pilot.csv
bin/vc.py run
```

Full runbook, including the one-time reference download and the toolchain pins:
[docs/steps.md](docs/steps.md).

## Layout

```
bin/vc.py                       the entire CLI: bed | sheet | run
bin/assert_output.py            the output contract, asserted on the produced VCF
params/pilot.yaml               every sarek parameter, with the reason for each
assets/samplesheet_template.csv edit this; sarek's own 7 columns
nextflow.config                 resource overrides for the run box (resources only)
tests/                          python3 -m unittest discover -s tests
docs/                           introduction, steps, output contract, roadmap
```

Requires `bedtools`, `pybedtools`, `pyyaml`, and — to run — `nextflow` 25.10.x, Java 17+ and
Docker. The BED arithmetic is bedtools'; the pipeline is stock nf-core/sarek 3.9.0, cloned as
a sibling at `../sarek` and never modified. What is left in this repo is the small set of
checks measured to have no published equivalent: the intervals contract, the tumour/normal
cardinality rules, the germline-resource and container-disk pre-flights, and the VCF contract.
