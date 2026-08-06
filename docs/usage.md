# Usage

## The samplesheet

Copy `assets/samplesheet_template.csv` and edit it. Paths must be absolute, and on the machine
that runs.

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
P11,NA,1,S12944Nr11,L001,/abs/Nr11.1.fastq.gz,/abs/Nr11.2.fastq.gz
P11,NA,0,S12944Nr12,L001,/abs/Nr12.1.fastq.gz,/abs/Nr12.2.fastq.gz
```

- **`status`: 1 = tumour, 0 = normal.** Exactly one `status=0` row per patient.
- **`patient` is the individual** (`P11`), never the sequencing order id (`S000021`). Using the
  order id collapses the cohort into one person and pairs tumours against other patients' normals.
- **`sample`** is the library. `sex` may be `NA`.

To avoid typing long paths, generate the rows and fill in patient and status by hand:

```bash
for f in /abs/path/*.1.fastq.gz; do
  s=$(basename "$f" .1.fastq.gz)
  printf 'PATIENT,NA,STATUS,%s,L001,%s,%s\n' "$s" "$f" "${f%.1.fastq.gz}.2.fastq.gz"
done
```

Role must be typed, never inferred: the vendor's own delivered VCFs order their genotype columns
normal-then-tumour inside a file named tumour-then-normal, so filename conventions cannot be
trusted.

## Running

```bash
$EDITOR scripts/run.sh          # the six variables at the top
./scripts/run.sh -preview       # ~40 s, validates every path, launches nothing
./scripts/run.sh
```

Anything you append reaches nextflow, so `./scripts/run.sh --outdir results_P12` overrides the
file. Run from the repo root — the paths in `run.sh` are relative to wherever you launch, and
nothing here changes directory on you.

## Failure modes that cost real time

- **A swapped `status` is undetectable** — by sarek, by the output, by anything downstream. Read
  the samplesheet before launching.
- **A patient with no `status=0` row runs tumour-only and completes.** mutect2 is absent from
  sarek's `tools_requiring_normal_samples`, so nothing stops it. The file is written *without*
  `_vs_` in its name and its variants are largely germline. Nothing validates this: measured
  across 7 fixtures, nf-schema passes all the bad ones, and `eido validate` exits 0 *when
  validation fails*.
- **A name-ordered target BED dies ~30 minutes in**, inside `CalculateContamination`. See
  [target-bed.md](target-bed.md).
- **Docker image layers land in `/var/lib/containerd`**, not in docker's `data-root`. Two runs
  died there on `no space left on device`. Check that filesystem, not the one holding the repo.
- **Changing a process's `cpus` in `nextflow.config` costs you the cache.** fastp is threaded by
  `--thread $task.cpus`, and the rendered command line is part of the task hash, so editing its
  `cpus` makes `-resume` re-run fastp and everything downstream — about 16 h. Memory-only edits
  are free; `GATK4_MUTECT2` and `GATK4_MARKDUPLICATES` never interpolate `task.cpus`.
- **Nextflow 26.x aborts on a valid paired samplesheet.** Pin 25.10.x.

## On peptimine_highmem1

```bash
export PATH=/mnt/volume/bin/miniconda/bin:$PATH     # nextflow 25.10.4 + openjdk 21 live here
cd /mnt/volume/nacho/variant-caller
./scripts/run.sh -preview && ./scripts/run.sh
```

`references/target_pad30.bed` and `assets/samplesheet_pilot.csv` for pair P11 are already there.
`nextflow` is **not** on the default PATH on that box, which is what the first line is for. The
first run under `--genome GATK.GRCh38` stages ~10 GB from S3.

Two things specific to that box:

- `/` is 96 GB at 83 % and `/var/lib/containerd` holds 60 GB of it. Check
  `df -h /var/lib/containerd` before a long run.
- **It routes IPv6 only.** sarek's `nextflow.config` includes an nf-core config over https, that
  fetch is done by the JVM, and the JVM prefers IPv4 — so the run dies at config-parse time with
  `Unable to parse config file`, while `curl` on the same box returns 200. `run.sh` exports
  `NXF_OPTS=-Djava.net.preferIPv6Addresses=true` for this. `NXF_OFFLINE=true` is not a
  substitute: it skips the include and then fails schema validation.
