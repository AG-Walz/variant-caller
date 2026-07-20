# Output

Everything is written under `--outdir`.

```
results/
├── preprocessing/     trimmed reads, aligned CRAMs
├── reports/           QC per sample, plus one combined MultiQC report
├── variant_calling/   the somatic VCFs
├── epitopeprediction/ samplesheet.csv  ← hand this to the next pipeline
└── pipeline_info/     software versions, execution trace, run report
```

## The two files that matter

**`variant_calling/<patient>/<patient>.somatic.vcf.gz`** — the somatic mutations, one file
per patient. Emitted raw: not normalised, not annotated, with tumour and comparison columns
both intact so the downstream pipeline knows which is which.

**`epitopeprediction/samplesheet.csv`** — points at those VCFs and carries each patient's
HLA type. Feed it directly to nf-core/epitopeprediction.

## Checking the run is trustworthy

Open `reports/multiqc/multiqc_report.html` first. An empty or very short mutation list has
two very different explanations — a genuinely clean tumour, or a failed experiment — and
only the QC report tells them apart.

**On-target coverage.** Exome capture only reads selected regions. If coverage over the
target regions is low, mutations were missed. Compare against what your kit and depth
should give; a tumour typically needs deeper coverage than a normal sample, because a
mutation may be present in only a minority of cells.

**Duplicate rate.** A high proportion of duplicate reads means the library had little
unique material. The effective coverage is lower than the raw number suggests.

**Capture efficiency.** The fraction of reads landing on target. Low values mean sequencing
was spent outside the regions of interest.

**Contamination estimate.** How much healthy tissue is mixed into the tumour sample. High
values make low-frequency mutations harder to detect and are worth knowing before
interpreting a short result list.

## Decisions recorded in the log

Every automatic choice appears in the run log and the report, never silently:

- which sample was selected for comparison, and why
- whether a patient fell back to tumour-only mode
- whether `tumour_adjacent` tissue had to be used — always accompanied by a warning
- which panel of normals applied to each kit

If a result looks surprising, read these before re-running anything.

## Provenance

`pipeline_info/` records the exact version of every tool, the parameters used, and a full
execution trace. Keep this directory — it is what makes a result reproducible months later,
and what you will need if a finding is ever questioned.
