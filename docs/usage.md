# Usage

v1 does not define its own Nextflow pipeline. It **wraps the local sarek clone** at `../sarek`
with one pinned, minimal command. `scripts/run_pilot.sh` runs exactly that command for the
pilot pair; this page documents what it runs and why every token is there.

## The pinned minimal sarek command

```bash
nextflow run "$SAREK_DIR" \
  -profile docker -c "$RESOURCE_CONFIG" \
  --step mapping --tools mutect2 --wes --igenomes_ignore true \
  --input "$SAMPLESHEET" --outdir "$OUTDIR" \
  --intervals "$TARGET_BED" --nucleotides_per_second 1000 \
  --fasta "$REF/Homo_sapiens_assembly38.fasta" \
  --fasta_fai "$REF/Homo_sapiens_assembly38.fasta.fai" \
  --dict "$REF/Homo_sapiens_assembly38.dict" \
  --germline_resource "$REF/af-only-gnomad.hg38.vcf.gz" \
  --skip_tools baserecalibrator,fastqc,mosdepth,samtools,multiqc,bcftools,vcftools \
  --markduplicates_pixel_distance 2500 --trim_fastq --trim_nextseq \
  --save_reference \
  -resume
```

`SAREK_DIR` defaults to `../sarek` (the local clone; there is no public sarek 3.9.0 — this
clone is customised). It is a variable in `run_pilot.sh` so you can point it elsewhere.

### What each flag does

| Flag | Why |
|---|---|
| `-profile docker` | The target box is **Docker only** (no Singularity/Apptainer). |
| `-c <RESOURCE_CONFIG>` | Minimal per-process resource override for the highmem box. This repo's root `nextflow.config` (the run script's `RESOURCE_CONFIG` default). |
| `--step mapping` | Start from FASTQ: map → mark duplicates → call. |
| `--tools mutect2` | GATK Mutect2, the only caller in v1. |
| `--wes` | Boolean in this clone's schema. Whole-exome / targeted mode. |
| `--igenomes_ignore true` | Do not resolve references from iGenomes; we pass every file explicitly. |
| `--intervals <target_pad30.bed>` | Restrict calling to the padded capture target. Must be **exactly 3 columns** (see below). |
| `--nucleotides_per_second 1000` | Integer (clone default 200000). Controls interval scatter granularity. |
| `--fasta` / `--fasta_fai` / `--dict` | GRCh38 reference and its indexes, passed explicitly. |
| `--germline_resource af-only-gnomad.hg38.vcf.gz` | Mutect2 germline resource. **Also doubles** as the GetPileupSummaries / contamination source. |
| `--skip_tools baserecalibrator,fastqc,mosdepth,samtools,multiqc,bcftools,vcftools` | Turn off BQSR and every QC/report tool. v1 produces one VCF, not a report bundle. |
| `--markduplicates_pixel_distance 2500` | Integer (no default in this clone). |
| `--trim_fastq` | **Required for any trimming to happen at all.** FASTP only runs when `params.trim_fastq \|\| params.split_fastq > 0 \|\| params.umi_location` (`subworkflows/local/fastq_preprocess_gatk/main.nf:107`), so `--trim_nextseq` on its own is a **silent no-op**. Also enables fastp adapter trimming (`--detect_adapter_for_pe`). |
| `--trim_nextseq` | **Boolean** bare flag in this clone (maps to fastp `--trim_poly_g`). The reads are NovaSeq 6000 (2-colour chemistry), where poly-G tails are a real artefact class. Inert without `--trim_fastq`. |
| `--save_reference` | Publish the built bwa-mem2 index to `<outdir>/reference`. The build costs ~87 GB RAM (`280 MB × ceil(fasta_size / 10 MB)`, `modules/nf-core/bwamem2/index/main.nf:5`) and ~1 h; saving it lets later patients reuse it via `--bwamem2` instead of rebuilding. |
| `-resume` | Reuse completed work in the same `--outdir`. Alignment dominates runtime, so resuming after a downstream failure costs minutes, not hours. Safe to use routinely. |

### Why `--germline_resource` is mandatory, not optional

Without `--germline_resource`, this sarek clone **silently publishes the unfiltered VCF**
tagged `mutect2` (FILTER column all `.`). Passing it is what yields
`*.mutect2.filtered.vcf.gz` with FilterMutectCalls verdicts. Because "silent" failures like
this are possible, `bin/assert_output.py` is a mandatory safety net, not a nicety
(see [output.md](output.md)).

### Why exactly one normal per patient matters

Mutect2 runs in **both** the paired-somatic and the tumour-only sub-workflow of this clone.
A patient with **zero** `status=0` rows (or with all rows `status=1`) **silently routes to
tumour-only** Mutect2 and still yields a populated-FILTER, AF-bearing VCF — one that is *not*
a paired comparison. v1 forbids this at samplesheet-build time (validator rules in
[inputs.md](inputs.md)), and the output assertion re-checks it by verifying the `_vs_`
filename and the two named genotype columns.

## The target BED

Built once by `bin/build_target_bed.sh <counts.gc-corrected.gz> <output.bed> [--pad N]` from a
DRAGEN target-count file, padded 30 bp (the default). The target set is identical across all 18
UrCa samples, so any one `*.target.counts.gc-corrected.gz` works; the canonical pad-30 output is
checksum-verified (region and bp counts) so a wrong or changed input file is a hard error. The
BED **must be exactly 3 columns** (`chrom  start  end`). This clone's
`create_intervals_bed` reads **column 5** of `--intervals` as a per-region *runtime-seconds*
estimate; any extra columns make the interval scatter silently wrong. Padding is **30 bp**
(not 100).

## Target-box notes (peptimine_highmem1)

- **28 cores, ~503 GB RAM, ~1.5 TB free on `/mnt/volume`.**
- **Docker only** — always `-profile docker`.
- **Nextflow is not installed.** `run_pilot.sh` checks for `nextflow` on `PATH` and, if
  missing, stops with install guidance. Install Nextflow (needs Java 11+) before running; see
  [steps.md](steps.md).
- **Run inside `screen`.** A full run is long; a dropped SSH session must not kill it.
- **Not SLURM.** Plain bash, no `sbatch`, no cluster profile. (The sibling `fastq-to-fasta`
  used `sbatch`+`cfc` for a different cluster; that does not apply here.)

## Fixed in v1 (do not change)

- **BQSR is off** (`baserecalibrator` in `--skip_tools`) — not an optional toggle.
- **Interval padding is 30 bp** — baked into the BED, not a runtime parameter.
- **Aligner and all other sarek defaults** are left as the clone ships them; v1 adds no
  further flags beyond the pinned set above.

---

## Out of scope for v1 (parked) — v2

- **Tumour-only run.** v1 rejects any patient without exactly one declared normal; there is no
  tumour-only command. A panel-of-normals + germline-resource tumour-only mode is **v2**.
- **Multiple callers, `--callers` selection.** v1 is Mutect2 only.
- **`--kit_registry` / per-kit PON / bait BED.** **v2.**
- **epitopeprediction handoff.** v1 emits no `epitopeprediction/samplesheet.csv`; run
  nf-core/epitopeprediction separately, pointing it at the VCF. It does its own filtering,
  normalisation and VEP annotation.
