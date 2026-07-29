# Output

v1 guarantees **one file per patient**: the paired somatic VCF. Everything else sarek could
write is switched off in the pinned command.

## The single deliverable

```
results/
└── variant_calling/
    └── <T>_vs_<N>/
        └── <T>_vs_<N>.mutect2.filtered.vcf.gz   (+ .tbi)
```

For the pilot (tumour `S12944Nr11`, normal `S12944Nr12`):

```
results/variant_calling/S12944Nr11_vs_S12944Nr12/S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz
```

This is the somatic mutation call set: FilterMutectCalls has run, the FILTER column carries
its verdicts (`PASS` and/or named filters), and both the tumour and normal genotype columns
are present so downstream tools know which is which. It is emitted **raw** in every other
sense — not normalised, not annotated, not consequence-filtered. Annotation is done downstream
by [nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction), which uses its
own tool versions; duplicating it here would eventually produce two silently disagreeing
answers.

## The output contract (enforced by `bin/assert_output.py`)

Because this sarek clone can *silently* produce a wrong-but-plausible VCF — an unfiltered file
if `--germline_resource` were dropped, or a tumour-only file if a patient had no normal — the
deliverable is not trusted until it passes an assertion. `bin/assert_output.py` is pure
`python3` + the `gzip` module (no bcftools/tabix; a `.vcf.gz` written with bgzip is readable by
the gzip module). It checks:

1. The filename contains `_vs_` and ends `.mutect2.filtered.vcf.gz` (a `.tbi` index should
   exist beside it).
2. The **FILTER column is not uniformly `.`** — FilterMutectCalls verdicts are present (`PASS`
   and/or named filters). A file that is all `.` means filtering did not run.
3. **Exactly two genotype (SAMPLE) columns**, and their names **equal the declared tumour and
   normal sample names** — checked *by name*. "Two columns present" is not enough; a tumour-only
   run also has columns.

   **The names inside the VCF are patient-prefixed.** sarek writes the read group as
   `SM:<patient>_<sample>` (`subworkflows/local/samplesheet_to_channel/main.nf:169`) and Mutect2
   takes its column names from `SM`, so the pilot's columns are `P11_S12944Nr11` /
   `P11_S12944Nr12` — inside a file named `S12944Nr11_vs_S12944Nr12...`. The **filename** uses
   the bare `sample` ids; the **contents** use `<patient>_<sample>`. Pass the prefixed form.
4. Headers `##tumor_sample=` and `##normal_sample=` are present and **match the two column
   names**.
5. `FORMAT` contains **`AF`** (allele frequency).
6. Reference is **GRCh38** — `##contig` lines present.

On any failure it exits non-zero with a message naming the **first failed check**.
`scripts/run_pilot.sh` calls it for you once the VCF is produced. To check by hand you pass the
declared tumour and normal ids so the by-name column check (3, 4) can run:

```bash
bin/assert_output.py --tumour P11_S12944Nr11 --normal P11_S12944Nr12 \
  results/variant_calling/S12944Nr11_vs_S12944Nr12/S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz
```

## Reading an empty or short result list

A short mutation list has two very different explanations — a genuinely clean tumour, or a
failed experiment. **v1 does not produce QC to tell them apart** (MultiQC, mosdepth,
fastqc, samtools stats are all skipped). If the list is surprising, judge it from the sarek
run log and, if needed, re-run with QC tools enabled outside the pinned command — coverage,
duplicate rate and contamination are the usual culprits, and they are a v2 concern here.

## Provenance

`nextflow` writes its execution trace, report and timeline into the run directory (and sarek's
`pipeline_info/` under `--outdir`). Keep them — they record the exact parameters and tool
versions behind a result.

---

## Not produced in v1 (parked) — v2 / downstream

The pre-reversal design promised a QC bundle and a downstream handoff. v1 produces **neither**:

- **`reports/` + `multiqc/multiqc_report.html`** — MultiQC and all per-sample QC are in
  `--skip_tools`. **v2** (or run sarek separately with QC enabled).
- **`epitopeprediction/samplesheet.csv`** — v1 emits no handoff samplesheet. Point
  nf-core/epitopeprediction at the VCF yourself. **Downstream / v2.**
- **`preprocessing/` CRAMs as a deliverable** — sarek still writes intermediates, but v1 does
  not treat them as an output contract. Only the VCF is guaranteed.
