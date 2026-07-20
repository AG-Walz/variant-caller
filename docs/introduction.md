# Introduction

Written for users who are new to somatic variant calling. If you already know the field,
skip to [Inputs](inputs.md).

## The problem

A tumour is made of the patient's own cells, carrying mutations. When you sequence a
tumour you find millions of differences from the reference genome — but the great
majority are variants the patient was **born with** (germline), present in every cell of
their body. Only a small fraction were **acquired by the tumour** (somatic).

The somatic ones are what matter here: they produce proteins the immune system has never
seen, which makes them candidate targets for a personalised vaccine. Everything this
pipeline does exists to separate a real tumour-only mutation from the many ways a
sequencing experiment can be misleading.

## How the separation works

The reliable method is comparison. Sequence the tumour, and also sequence a tumour-free
sample from **the same patient** — usually blood. Anything present in both is inherited.
Anything present only in the tumour is a candidate somatic mutation.

Where no tumour-free sample exists, the comparison falls back to public databases: variants
common in the general population are probably inherited, and variants that keep appearing
across unrelated samples are probably technical artefacts. This works, but it is
substantially noisier, and the pipeline flags it clearly.

## The four steps

**Clean.** Sequencing produces short fragments of DNA called reads. Some carry leftover
laboratory adapter sequence, and quality degrades toward the end of each read. Both are
trimmed away.

**Align.** Each read is matched to the position in the reference genome it most likely came
from. This is the slowest step.

**Tidy.** Two corrections that make the statistics trustworthy. Sample preparation copies
DNA fragments, so identical reads are flagged as copies — otherwise one early error looks
like ten independent pieces of evidence. And sequencers mis-estimate their own confidence
in systematic ways, which is measured and corrected.

**Call.** The tumour and the tumour-free sample are compared position by position, asking
whether there is real evidence of a change in one and not the other.

## Why it stops there

The output is a VCF: a text file listing mutations and the evidence for each. It is
deliberately **raw** — nothing is renamed, reformatted, annotated with gene names, or
filtered by whether it changes a protein.

All of that is done by
[nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction), which then turns
the mutations into peptides and predicts which will be visible to the immune system. If
this pipeline annotated the VCF too, the two would use different tool versions and
eventually disagree — invisibly, in ways nobody would think to check.

## Things that commonly go wrong

- **A mislabelled sample.** If the tumour and the tumour-free sample are swapped, or a
  sample is assigned to the wrong patient, the results are wrong in a way that looks
  perfectly normal. This is why labels are validated before anything runs.
- **Tissue taken beside the tumour.** It often already carries the tumour's earliest
  mutations, so comparing against it can erase exactly the mutations you most want.
- **Too little sequencing depth.** Mutations are missed, and a short result list looks the
  same as a genuinely clean tumour. Check the QC report before trusting an empty answer.
- **Chromosome naming.** A reference using `chr1` with a capture kit file using `1` yields
  zero mutations and no error message. The pipeline checks this up front.
