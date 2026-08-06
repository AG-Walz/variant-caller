# Parameters

## What `run.sh` sets

`WORKDIR`, `SAMPLESHEET`, `OUTDIR` and `INTERVALS` are the variables at the top of the script,
feeding `-work-dir`, `--input`, `--outdir` and `--intervals`. `SAREK` and `PROFILE` are there too,
but pinned. The rest:

| flag | why |
|---|---|
| `-r 3.9.0` | the version every measurement here was made against |
| `-profile docker` | selects a config block inside sarek, so it is a CLI option rather than a parameter |
| `-c nextflow.config` | resource overrides **only**. nf-core's own usage docs warn that passing *parameters* via `-c` produces errors |
| `--genome GATK.GRCh38` | supplies FASTA, `.fai`, `.dict`, gnomAD, the BWA index, dbSNP and known indels from `s3://ngi-igenomes/igenomes/` |
| `--wes true` | targeted data, not WGS — selects the right models in the callers |
| `--intervals` | the target BED; see [target-bed.md](target-bed.md) |
| `--tools mutect2` | the somatic caller. **Pairing comes from the samplesheet `status` column, not from this flag** |
| `--nucleotides_per_second 1000` | 49,633,134 bp / 1000 / 600 → **83 Mutect2 shards**. At the default 200000 a whole exome scores 248 "seconds", never crosses the 600 chunk threshold, and you get **one** shard: fully serial calling |
| `--markduplicates_pixel_distance 2500` | NovaSeq 6000 is a patterned flowcell. Picard's default of 100 is for unpatterned optics and makes the duplicate rate wrong |
| `--trim_fastq true` | adds adapter trimming. Without it fastp runs with `--disable_adapter_trimming` |
| `--trim_nextseq true` | adds `--trim_poly_g`. 2-colour chemistry reads "no signal" as G, so poly-G tails are artefacts |
| `--save_reference true` | publishes whatever sarek generated for the run to `results/reference/` instead of discarding it with the work dir |
| `-resume` | always on. A no-op on a fresh work dir; after an interruption it is the difference between minutes and 17 hours |

`--trim_fastq` and `--trim_nextseq` are two switches, not one gating the other. The FASTP gate is
`params.trim_fastq || params.split_fastq > 0 || params.umi_location`
(`subworkflows/local/fastq_preprocess_gatk/main.nf:107`) and `split_fastq` **defaults to
50000000**, so FASTP always runs regardless.

## What `--genome GATK.GRCh38` brings with it

Beyond the references, and each announced only as a `log.warn`:

- **a 1000g panel of normals** (`conf/igenomes.config:76`), applied automatically by
  `modules/nf-core/gatk4/mutect2/main.nf:35`. It changes which calls PASS.
- **BQSR**, because dbSNP and known indels come with it.
- **a `.64.alt` file** in the BWA index, which makes BWA-MEM alt-aware. It also means the 1h15m
  `BWAMEM1_INDEX` build never happens, so do not go looking for a built index under
  `results/reference/`.
- **WGS calling intervals**, which `--intervals` overrides.

All are wanted here.

## What is deliberately not set

- **`--skip_tools`.** QC runs: fastqc, mosdepth, samtools stats, multiqc.
- **`--pon`.** The igenomes one is in use; a cohort-specific panel is not built.
- **annotation.** No VEP, no normalisation. The VCF is emitted as `FilterMutectCalls` leaves it;
  annotation happens downstream in nf-core/epitopeprediction.
- **`-plugins`.** sarek 3.9.0 already declares `nf-schema@2.7.2` plus three others; pinning it on
  the command line is redundant and silently drops the rest from view.

## `nextflow.config`

Resource overrides only, so the pipeline stays provably stock. **The values ship sized for a
28-core, 500 GB box — lower them to match your machine.**

- `executor { cpus = 26; memory = '480 GB' }` caps the **sum** across running tasks. This is not
  `process.resourceLimits`, which caps one task and can only clamp downward.
- `GATK4_MARKDUPLICATES` and its Spark variant get 6 cpus and 60 GB: measured 42.5 GB peak against
  base.config's 30 GB ceiling.
- `GATK4_MUTECT2` gets 4 cpus: with 83 shards under a 26-cpu cap, per-shard `cpus` **is** the
  concurrency knob (26/4 ≈ 6 concurrent shards).

`{ N * task.attempt }` is not decoration — base.config scales its own requests by attempt, and
static literals silently remove retry escalation, so an OOM would fail identically on retry.
