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
+ declarations.tsv (sample→patient→label)   ─────────────────────────────────────────►
                                            variant_calling/<T>_vs_<N>/
                                              <T>_vs_<N>.mutect2.filtered.vcf.gz
```

For each patient the pipeline aligns the reads, marks duplicates, and runs GATK **Mutect2**
in **paired** tumour-vs-normal mode over the capture target, then FilterMutectCalls. The one
deliverable is a bgzipped, FILTER-populated, AF-bearing somatic VCF whose two genotype
columns are the declared tumour and normal samples.

## What it does NOT do (v1 — all of this is v2 or downstream)

- **No kit registry / bait BED / hybrid-capture QC.** One target BED, built once from the
  DRAGEN target set. No capture-efficiency metrics.
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

## Quickstart (pilot: UrCa Nr11 tumour vs Nr12 normal)

Run on the target box (Docker only, Nextflow in a `screen` session). End to end:

```bash
# 0. Fresh box only: clone ../sarek at 3.9.0 and install Nextflow, then verify.
#    run_pilot.sh resolves sarek as ../sarek, so the two repos must be SIBLINGS.
scripts/setup_env.sh
tests/check_environment.sh

# 1. Download the reference bundle (genome + gnomAD germline resource). One-off, large.
scripts/fetch_references.sh

# 2. Build the 3-column target BED from a DRAGEN target-count file, padded 30 bp. One-off.
#    (the target set is identical across all 18 UrCa samples, so any one file works)
bin/build_target_bed.sh \
  /mnt/volume/data/DNA/00_metrics/<sample>.target.counts.gc-corrected.gz \
  references/target_pad30.bed

# 3. Build the sarek samplesheet from a declarations TSV + the FASTQ directory.
#    REQUIRED, and on the box that will run it: the sheet carries absolute paths and
#    sarek's schema sets "exists": true on them. The committed CSV is only an example.
bin/build_samplesheet.py --declarations assets/pilot_declarations.tsv \
    --fastq-dir <the FASTQ directory on THIS box> \
    --out assets/samplesheet_pilot.csv

# 4. Run the pinned minimal sarek command for the pilot pair.
#    (run_pilot.sh runs the output assertion itself once the VCF is produced)
INPUT=assets/samplesheet_pilot.csv scripts/run_pilot.sh
```

`run_pilot.sh` ends by calling the assertion for you. To re-check a VCF by hand:

```bash
bin/assert_output.py --tumour S12944Nr11 --normal S12944Nr12 \
  results/variant_calling/S12944Nr11_vs_S12944Nr12/S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz
```

Expected deliverable:
`results/variant_calling/S12944Nr11_vs_S12944Nr12/S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz`

Full operator runbook: **[docs/steps.md](docs/steps.md)**.

## Repository layout

```
README.md            this file
CLAUDE.md            guidance for Claude Code in this repo
scripts/
  setup_env.sh          bootstrap a fresh box: clone ../sarek at 3.9.0 + install Nextflow
  fetch_references.sh   download genome + gnomAD germline resource
  run_pilot.sh          the pinned minimal `nextflow run <sarek>` for the pilot pair
bin/
  build_target_bed.sh   DRAGEN target-count file → 3-column, 30 bp-padded target BED
  build_samplesheet.py  declarations TSV + FASTQ dir → sarek samplesheet (with validation)
  assert_output.py      enforce the output contract on the produced VCF
assets/
  pilot_declarations.tsv        example declarations (sample→patient→label)
  samplesheet_pilot_example.csv example emitted sarek samplesheet
nextflow.config         minimal resource-override config passed to sarek via `-c`
tests/                  soundness checks for the helper tools
  check_environment.sh  read-only preflight: can THIS box run the pipeline?
docs/                   introduction, inputs, usage, output, steps
```

The wrapped sarek clone lives beside this repo at `../sarek` (path is a variable in the run
script). This repo never forks or edits sarek.

## Documentation

| | |
|---|---|
| [Introduction](docs/introduction.md) | What somatic calling is and why the steps exist |
| [Inputs](docs/inputs.md) | Declarations TSV, sample labels, the emitted samplesheet, references |
| [Usage](docs/usage.md) | The pinned sarek command, flags, and target-box notes |
| [Output](docs/output.md) | The single deliverable and the contract that guards it |
| [Steps](docs/steps.md) | Numbered end-to-end runbook for the pilot |
| [Roadmap](docs/roadmap.md) | v1 / v2 / v3 scope — incl. the CeGaT Level 2–5 replacement goal |

## Credits

Developed at [AG Walz](https://github.com/AG-Walz), Tübingen. Built by wrapping a local
clone of [nf-core/sarek](https://github.com/nf-core/sarek) and following the lean
orchestration shape of the sibling `fastq-to-fasta` repo.

## Licence

To be confirmed before first release.
