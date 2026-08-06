# Usage

## The samplesheet

Copy `assets/samplesheet_template.csv` and edit it. Paths must be absolute, and must exist on the
machine that runs.

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
P11,NA,1,S12944Nr11,L001,/abs/Nr11.1.fastq.gz,/abs/Nr11.2.fastq.gz
P11,NA,0,S12944Nr12,L001,/abs/Nr12.1.fastq.gz,/abs/Nr12.2.fastq.gz
```

- **`patient` is the individual** (`P11`), never the sequencing order id (`S000021`). The order id
  collapses the cohort into one person and pairs tumours against other patients' normals.
- **`status`: 1 = tumour, 0 = normal**, typed rather than inferred from filenames. Exactly one
  `status=0` row per patient.
- **`sample`** is the library. `sex` may be `NA`.

To avoid typing long paths, generate the rows and fill in patient and status by hand:

```bash
for f in /abs/path/*.1.fastq.gz; do
  s=$(basename "$f" .1.fastq.gz)
  printf 'PATIENT,NA,STATUS,%s,L001,%s,%s\n' "$s" "$f" "${f%.1.fastq.gz}.2.fastq.gz"
done
```

## Running

Launch from the repo root: `run.sh`'s paths are relative, and nextflow resolves relative paths
against the launch directory. Anything you append reaches nextflow, so
`./scripts/run.sh --outdir results_P12` overrides the file.

## Failure modes that cost real time

- **A swapped `status` is undetectable** — by sarek, by the output, by anything downstream. Read
  the samplesheet before launching.
- **A patient with no `status=0` row runs tumour-only and completes.** mutect2 is absent from
  sarek's `tools_requiring_normal_samples`, so nothing stops it; the file is written *without*
  `_vs_` in its name and its variants are largely germline. Measured across 7 fixtures, nf-schema
  passes every bad sheet and `eido validate` exits 0 *when validation fails*.
- **`status: 1.00` parses as a BigDecimal, and an absent status column defaults every row to 0.**
  Both are silent, and both are easy to produce from a spreadsheet or pandas.
- **A name-ordered target BED dies ~30 minutes in**, inside `CalculateContamination`. See
  [target-bed.md](target-bed.md).
- **Docker image layers land in `/var/lib/containerd`**, not in docker's `data-root`. sarek's
  images run to roughly 60 GB there, and two runs died on `no space left on device`. Check that
  filesystem, not the one holding the repo.
- **Changing a process's `cpus` in `nextflow.config` costs you the cache** — most of the 17 h.
  fastp is threaded by `--thread $task.cpus` and the rendered command line is part of the hash, so
  `-resume` re-runs fastp and everything after it. Memory-only edits are free; `GATK4_MUTECT2` and
  `GATK4_MARKDUPLICATES` never interpolate `task.cpus`.
- **Nextflow 26.x aborts on a valid paired samplesheet.** Pin 25.10.x — `get.nextflow.io` installs
  26.04.6 by default.
- **On an IPv6-only host the run dies at config-parse time**, reporting `Unable to parse config
  file` while `curl` on the same box returns 200. sarek's config includes an nf-core config over
  https and the JVM prefers IPv4. `run.sh` exports `NXF_OPTS=-Djava.net.preferIPv6Addresses=true`
  for this; `NXF_OFFLINE=true` is not a substitute, as it skips the include and then fails schema
  validation.
