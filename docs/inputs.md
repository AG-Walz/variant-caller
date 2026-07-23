# Inputs

v1 takes two things from you — **FASTQ files** and a **declarations TSV** that says which
sample belongs to which patient and what each sample is. From those, `bin/build_samplesheet.py`
mechanically derives and writes the sarek samplesheet. You never hand-edit the samplesheet.

## Declarations TSV (what you write)

One row per sample. Three tab-separated columns; a header row is optional (the builder
tolerates it):

```
sample	patient	label
S12944Nr11	P11	tumour
S12944Nr12	P11	tumour_adjacent
```

- `sample` — the sample id **as it appears in the FASTQ filenames after the order prefix is
  stripped** (see "Auto-derived" below). For UrCa, `S000021_S12944Nr11.1.fastq.gz` → `S12944Nr11`.
- `patient` — the individual this sample belongs to, e.g. `P11`. **Declare this; never use the
  order id** (`S000021`). The order id is shared across the whole cohort — using it would
  collapse every sample into one "patient" and cross every tumour against every normal.
- `label` — one of the four declared labels below.

Roles and patient grouping are **declared, never inferred.** The UrCa Nr-odd/Nr-even filename
habit is a vendor convention, not a fact, and DRAGEN VCFs order their genotype columns
normal-then-tumour against a filename that is tumour-then-normal — so guessing is unsafe.

An example declarations file for the pilot is at `assets/pilot_declarations.tsv`; the
samplesheet it produces is committed as `assets/samplesheet_pilot_example.csv`. The order
prefix stripped from filenames defaults to `S000021_` and is overridable with
`--order-prefix`.

## Sample labels and the status downcast

Four labels, ordered by how likely a sample is to carry the tumour's own mutations:

**`tumour`** — the malignant sample. Downcast to sarek `status=1`.

**`control_healthy`** — tumour-free tissue from the patient (blood, PBMC, healthy distant
tissue). Downcast to `status=0`.

**`control_benign`** — a benign lesion. Downcast to `status=0`. Benign tissue can carry its
own acquired mutations.

**`tumour_adjacent`** — normal-looking tissue beside the tumour. Downcast to `status=0`.
Usable only as a last resort: such tissue frequently already carries the tumour's earliest
mutations, so comparing against it can erase exactly the findings you want. (The UrCa pilot
normal, Nr12, is declared `tumour_adjacent`.)

sarek only understands a binary `status`: **`tumour` → 1**, all three of
`tumour_adjacent` / `control_healthy` / `control_benign` → **0**. The four-way label is what
you declare; the downcast is what sarek sees.

## Validator rules (checked at samplesheet-build time)

`bin/build_samplesheet.py` refuses to emit a samplesheet unless, for every patient:

1. **Every sample carries a declared label** (one of the four). An unknown label names the
   offending sample and fails.
2. **Exactly one `status=0` row per patient.** More than one normal is a hard error in v1 —
   the preference-ordered resolver (`control_healthy` > `control_benign` > `tumour_adjacent`)
   is v2.
3. **At least one `status=1` (tumour) row per patient.**
4. **Zero `status=0` rows is rejected.** v1 is **paired somatic only**; it has no tumour-only
   mode. A patient with no normal is an error, not a fallback.

Each error names the offending sample or patient.

## The emitted sarek samplesheet (what the tool writes)

Header, in exactly this order:

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
```

Pilot example:

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
P11,NA,1,S12944Nr11,L001,/mnt/volume/data/fastq-example-data/UrCA/01_fastq/S000021_S12944Nr11.1.fastq.gz,/mnt/volume/data/fastq-example-data/UrCA/01_fastq/S000021_S12944Nr11.2.fastq.gz
P11,NA,0,S12944Nr12,L001,/mnt/volume/data/fastq-example-data/UrCA/01_fastq/S000021_S12944Nr12.1.fastq.gz,/mnt/volume/data/fastq-example-data/UrCA/01_fastq/S000021_S12944Nr12.2.fastq.gz
```

| Column | Value in v1 |
|---|---|
| `patient` | Declared patient id (e.g. `P11`). Comparison happens only within a patient. |
| `sex` | `NA` — unknown, and not needed for the pinned command. |
| `status` | Downcast from the declared label: `1` for `tumour`, `0` otherwise. |
| `sample` | Auto-derived sample id (order prefix and `.1/.2` stripped). |
| `lane` | `L001` — UrCa pre-merges its four physical lanes into one file = one read group. |
| `fastq_1` / `fastq_2` | Absolute paths to the R1 / R2 files. |

### Auto-derived (mechanical, done by the tool)

- **R1/R2 pairing** — recognises `.1`/`.2`, `_R1`/`_R2`, and `_1`/`_2`.
- **sample id** — strip the `S000021_` order prefix and the `.1`/`.2` mate suffix
  (`S000021_S12944Nr11.1.fastq.gz` → `S12944Nr11`).
- **lane** — `L001` for UrCa (one merged file per sample).

### Declared (NOT mechanical for UrCa)

- **which samples share a patient**, and **each sample's label** — because `Nr11` and `Nr12`
  do not share a filename stem, patient membership cannot be read off the filenames. That is
  the whole reason the declarations TSV exists.

## Reference data

Downloaded by `scripts/fetch_references.sh` into `references/` (git-ignored):

| Dataset | Purpose |
|---|---|
| `Homo_sapiens_assembly38.fasta` (+ `.fai`, `.dict`) | GRCh38 reference; the coordinate system. Passed as `--fasta` / `--fasta_fai` / `--dict`. |
| `af-only-gnomad.hg38.vcf.gz` (+ `.tbi`) | gnomAD germline resource. Passed as `--germline_resource`; **doubles** as the GetPileupSummaries / contamination source (no separate small-exac file needed). |

The **target BED** is not downloaded — it is built once from the DRAGEN target-count files by
`bin/build_target_bed.sh` (padded 30 bp, **exactly 3 columns**). See
[usage.md](usage.md#the-target-bed) for why the column count matters.

No panel of normals and no VEP cache are used in v1.

---

## Out of scope for v1 (parked, not deleted) — v2 / other pipelines

The pre-reversal design carried extra samplesheet columns and a kit registry. These are
**not part of v1** and are recorded here only so the intent is not lost:

- **`kit` column + kit registry (YAML) + bait BED** — hybrid-capture QC and per-kit panel of
  normals. v1 uses a single target BED and no PON. **v2.**
- **`alleles` / HLA column** — passthrough for downstream epitope prediction. v1 does not
  emit an epitopeprediction handoff. **Downstream / v2.**
- **`organ` column** — only meaningful for the preference-ordered normal resolver, which is
  **v2**.
- **Preference-ordered comparison-sample selection** (`control_healthy` > `control_benign` >
  `tumour_adjacent`) and **tumour-only fallback** — v1 requires exactly one declared normal
  and rejects everything else. **v2.**
