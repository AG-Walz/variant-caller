# AG-Walz/variant-caller

A lean, nf-core-style Nextflow pipeline for **somatic variant calling** from targeted
and whole-exome sequencing.

> **Status: design stage.** This repository contains documentation only — no runnable
> pipeline code yet. Interfaces described here may change.

## What it does

Takes sequencing reads from a tumour (and, where available, a tumour-free sample from
the same patient) and produces a **raw somatic VCF**: the mutations the tumour acquired,
separated from those the patient was born with.

```
FASTQ ┐
BAM   ┴→ Clean → Align → Tidy → Call → VCF ┐
                                           ├→ epitopeprediction → mhcquant
VCF, peptides, FASTA, MS ──────────────────┘
```

## What it does not do

The VCF is emitted **raw** — not normalised, not annotated, not filtered by consequence.
[nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction) performs all of
that with its own tool versions, and duplicating it here would eventually produce two
silently disagreeing answers.

If you already have a VCF, peptides, a protein FASTA, or mass-spectrometry results, this
pipeline is not in your path — go straight to epitopeprediction.

## Documentation

| | |
|---|---|
| [Introduction](docs/introduction.md) | What somatic calling is and why the steps exist |
| [Inputs](docs/inputs.md) | Samplesheet, sample labels, reference data |
| [Usage](docs/usage.md) | Running the pipeline, parameters, profiles |
| [Output](docs/output.md) | What you get and how to check it is trustworthy |

## Credits

Developed at [AG Walz](https://github.com/AG-Walz), Tübingen. Built on
[nf-core](https://nf-co.re) modules and conventions, and indebted to
[nf-core/sarek](https://github.com/nf-core/sarek).

## Licence

To be confirmed before first release.
