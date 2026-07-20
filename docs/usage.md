# Usage

> **The pipeline is not yet implemented.** The commands below describe the intended
> interface and are documented in advance so it can be reviewed. They will not run today.

## Basic run

```bash
nextflow run AG-Walz/variant-caller \
  -profile docker \
  --input        samplesheet.csv \
  --outdir       results/ \
  --fasta        /refs/genome/GRCh38.fa \
  --genome_build GRCh38 \
  --kit_registry assets/kits.yaml \
  -resume
```

## Tumour-only run

When a patient has no tumour-free sample, two extra resources are required. The pipeline
refuses to start without them rather than producing unreliable calls.

```bash
nextflow run AG-Walz/variant-caller \
  -profile singularity \
  --input        samplesheet.csv \
  --outdir       results/ \
  --fasta        /refs/genome/GRCh38.fa \
  --genome_build GRCh38 \
  --kit_registry assets/kits.yaml \
  --pon                /refs/pon/twist_v2_pon.vcf.gz \
  --germline_resource  /refs/gnomad/af-only-gnomad.hg38.vcf.gz
```

## Parameters

**Required**

| Parameter | Description |
|---|---|
| `--input` | Samplesheet CSV. |
| `--outdir` | Output directory. |
| `--fasta` | Reference genome FASTA. |
| `--genome_build` | Build label, e.g. `GRCh38`. Used for reporting; nothing is downloaded. |
| `--kit_registry` | Kit registry YAML. |

**Required for tumour-only**

| Parameter | Description |
|---|---|
| `--pon` | Panel of normals VCF. Overridden by a per-kit entry in the registry. |
| `--germline_resource` | Population frequency VCF, e.g. gnomAD. |

**Optional**

| Parameter | Default | Description |
|---|---|---|
| `--callers` | `mutect2` | Comma-separated. Additional callers may be enabled. |
| `--intervals_padding` | `100` | Bases added around each target region when calling. |
| `--aligner` | `bwamem2` | Read aligner. |
| `--skip_trimming` | `false` | Skip adapter and quality trimming. |
| `--skip_bqsr` | `false` | Skip base quality recalibration. Consider for very small panels. |
| `--fasta_fai`, `--dict`, `--bwamem2` | — | Prebuilt indexes. Built automatically if omitted. |

## Profiles

Use exactly one container profile: `-profile docker`, `-profile singularity`, or
`-profile conda`. Add an institutional profile after it if your site has one, e.g.
`-profile singularity,cfc`.

## Resuming

`-resume` reuses completed work from a previous run in the same directory. Because
alignment dominates the runtime, resuming after a downstream failure costs minutes rather
than hours. It is safe to use routinely.

## Handing off to epitopeprediction

The run writes `epitopeprediction/samplesheet.csv`, which points at the VCFs and carries the
HLA types across. Pass it straight on:

```bash
nextflow run nf-core/epitopeprediction \
  -profile docker \
  --input  results/epitopeprediction/samplesheet.csv \
  --outdir epitope_results/
```

That pipeline performs its own filtering, normalisation and VEP annotation, so no
preparation of the VCF is needed — or wanted.
