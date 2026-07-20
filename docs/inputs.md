# Inputs

## Samplesheet

A CSV with one row per sequencing file. Nothing is inferred from filenames.

```csv
patient,sample,type,organ,kit,lane,fastq_1,fastq_2,alleles
P01,P01_tum,tumour,lung,twist_exome_v2,L001,/data/P01_tum_L001_R1.fastq.gz,/data/P01_tum_L001_R2.fastq.gz,HLA-A*02:01;HLA-B*07:02
P01,P01_tum,tumour,lung,twist_exome_v2,L002,/data/P01_tum_L002_R1.fastq.gz,/data/P01_tum_L002_R2.fastq.gz,HLA-A*02:01;HLA-B*07:02
P01,P01_blood,control_healthy,blood,twist_exome_v2,L001,/data/P01_blood_L001_R1.fastq.gz,/data/P01_blood_L001_R2.fastq.gz,HLA-A*02:01;HLA-B*07:02
```

| Column | Required | Description |
|---|---|---|
| `patient` | yes | Groups samples from one individual. Comparison happens only within a patient. |
| `sample` | yes | Unique sample name within the patient. |
| `type` | yes | `tumour`, `control_healthy`, `control_benign` or `tumour_adjacent`. See below. |
| `organ` | recommended | Tissue of origin, e.g. `blood`, `lung`. Required for `control_healthy`. |
| `kit` | yes | Capture kit name; must exist in the kit registry. |
| `lane` | no | Sequencing run. Repeat the sample across rows if sequenced more than once. |
| `fastq_1` / `fastq_2` | yes | Read files. `fastq_2` may be empty for single-end data. |
| `alleles` | no | Patient HLA type, or a path to a typing result. Passed through untouched. |

For aligned input, replace the FASTQ columns with a `bam` or `cram` column plus its index.

## Sample labels

Four labels, ordered by how likely a sample is to contain the tumour's own mutations —
which is the only thing that matters when choosing what to compare against.

**`tumour`** — the malignant sample. Never used as a comparison.

**`control_healthy`** — any tumour-free tissue from the patient: blood, PBMC, or healthy
solid tissue from a distant site. The default comparison sample. Use `organ` to record
which. *Caution:* in blood cancers the blood is the tumour, and in older patients blood can
carry its own acquired mutations.

**`control_benign`** — a benign lesion. Usable, but benign tissue can carry acquired
mutations of its own. Also valuable downstream: a peptide found in both the tumour and a
benign lesion is likely a general proliferation marker rather than cancer-specific.

**`tumour_adjacent`** — normal-looking tissue beside the tumour. Usable only as a last
resort. Such tissue frequently contains stray tumour cells and often already carries the
tumour's earliest mutations, so comparing against it can delete the most valuable findings.
The pipeline warns whenever it has to fall back to this.

The comparison sample is chosen automatically, in the order
`control_healthy` > `control_benign` > `tumour_adjacent`, and only among samples sharing the
same `patient`. If none exists, the patient runs in tumour-only mode.

> Tissue from a **different** person is never a valid comparison — it shares none of the
> patient's inherited variants. Give such samples their own `patient` id; they can serve as
> cohort background but will never be selected for comparison.

## Reference data

| Dataset | Required | Purpose |
|---|---|---|
| Reference genome (FASTA) | yes | The coordinate system for everything else. Any build; indexes are built automatically if missing. |
| Capture kit target BED | yes | Where to look for mutations. From the kit vendor. |
| Capture kit bait BED | yes | What the probes were designed against. Used to measure capture efficiency — not interchangeable with the target file. |
| Panel of normals (VCF) | tumour-only | Recurring technical artefacts of one kit and machine. Only valid for the kit it was built from. |
| Population frequency database (VCF) | tumour-only | Typically gnomAD. Distinguishes inherited from acquired variants when no patient sample exists. |
| HLA typing | no | Not used here; carried through for downstream prediction. |

No VEP cache is needed — annotation happens downstream.

## Kit registry

Capture kits are declared once in a YAML file and referenced by name from the samplesheet:

```yaml
kits:
  twist_exome_v2:
    target_bed: /refs/kits/twist_v2/targets.bed
    bait_bed:   /refs/kits/twist_v2/baits.bed
    pon:        /refs/pon/twist_v2_pon.vcf.gz
```

A panel of normals is only valid for the kit and chemistry it was built from, so declaring
it per kit makes the correct pairing automatic. An unknown kit name is an immediate error.
