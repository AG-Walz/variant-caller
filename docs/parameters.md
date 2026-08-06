# Parameters

Every setting lives inline in `scripts/run.sh`. There is no params file: once `--genome` supplied
the reference paths, only five tuned flags were left, and five flags do not need a file.

## What `run.sh` sets

| flag | why |
|---|---|
| `-r 3.9.0` | the version every measurement in [DECISIONS.md](../DECISIONS.md) was made against |
| `-profile docker` | selects a config block inside sarek, so it is a CLI option rather than a parameter |
| `-c nextflow.config` | resource overrides **only**. All three peer nf-core pipelines warn that passing *parameters* via `-c` produces errors |
| `--genome GATK.GRCh38` | supplies FASTA, `.fai`, `.dict`, gnomAD, the BWA index, dbSNP and known indels from `s3://ngi-igenomes/igenomes/` |
| `--wes true` | targeted data, not WGS — selects the right models in the callers |
| `--intervals` | the target BED; see [target-bed.md](target-bed.md) |
| `--tools mutect2` | the somatic caller. **Pairing comes from the samplesheet `status` column, not from this flag** |
| `--nucleotides_per_second 1000` | 49,633,134 bp / 1000 / 600 → **83 Mutect2 shards**. At the default 200000 the whole exome scores 248 "seconds", never crosses the 600 chunk threshold, and you get **one** shard: fully serial calling |
| `--markduplicates_pixel_distance 2500` | NovaSeq 6000 is a patterned flowcell. Picard's default of 100 is for unpatterned optics and makes the duplicate rate simply wrong |
| `--trim_fastq true` | adds adapter trimming. Without it fastp runs with `--disable_adapter_trimming` |
| `--trim_nextseq true` | adds `--trim_poly_g`. 2-colour chemistry reads "no signal" as G, so poly-G tails are real artefacts |
| `--save_reference true` | publish the built index to `results/reference/` instead of discarding it with the work dir |
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
- **a `.64.alt` file** in the BWA index, which makes BWA-MEM alt-aware.
- **WGS calling intervals**, which `--intervals` overrides.

All are wanted here. Under the earlier goal of reproducing the vendor's calls they were the reason
`--igenomes_ignore true` was set; under the current goal — independently checking whether their run
was done correctly — a PoN and BQSR make the evidence better, not worse.

## What is deliberately not set

- **`--skip_tools`.** QC runs: fastqc, mosdepth, samtools stats, multiqc. mosdepth coverage over
  the target is the evidence this project exists to produce.
- **`--pon`.** The igenomes one is in use; a cohort-specific panel is not built.
- **annotation.** No VEP, no normalisation. The VCF is emitted as `FilterMutectCalls` leaves it;
  annotation happens downstream in nf-core/epitopeprediction.
- **`-plugins`.** sarek 3.9.0 already declares `nf-schema@2.7.2` plus three others; pinning it on
  the command line is redundant and silently drops the rest from view.

## `nextflow.config`

Resource overrides for the run box, nothing else — so the pipeline stays provably stock.

- `executor { cpus = 26; memory = '480 GB' }` caps the **sum** across running tasks. This is not
  `process.resourceLimits`, which caps one task and can only clamp downward.
- `GATK4_MARKDUPLICATES` gets 60 GB: measured 42.5 GB peak against base.config's 30 GB ceiling.
- `GATK4_MUTECT2` gets 4 cpus: with 83 shards under a 26-cpu cap, per-shard `cpus` **is** the
  concurrency knob (26/4 ≈ 6 concurrent shards).

`{ N * task.attempt }` is not decoration — base.config scales its own requests by attempt, and
static literals silently remove retry escalation, so an OOM would be guaranteed to fail identically
on retry.
