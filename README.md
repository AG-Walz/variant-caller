# variant-caller

Tumour/normal FASTQ → one paired somatic VCF per patient, by running
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0 with Mutect2.

Two scripts. Edit the variables at the top of each, then run it.

| script | when | what it does |
|---|---|---|
| `scripts/build_bed.sh` | once per capture kit | your kit's BEDs → one target BED |
| `scripts/run.sh` | every run | the nextflow command |

## Requirements

Docker, Java 17+, `bedtools`, and **Nextflow 25.10.x — not 26.x**, which aborts on a valid paired
samplesheet.

```bash
mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools
export PATH=~/envs/vc/bin:$PATH
```

You never download the genome — sarek fetches the GRCh38 bundle itself on the first run, about
10 GB. Docker writes image layers to `/var/lib/containerd` whatever its `data-root` says, and
sarek's images run to roughly 60 GB there, so check free space on that filesystem rather than on
the one holding the repo.

`nextflow.config` is sized for a 28-core, 500 GB box. Lower `executor { cpus; memory }` to match
your machine before the first run.

## Run it

Launch from the repo root — every path in both scripts is relative to where you start it.

**1. Build the target BED.** Fetch the `.fai` and one file per capture kit, then set `BEDS`,
`FAI`, `PADDING` and `OUTPUT` at the top of the script.

```bash
mkdir -p references
curl -fL -o references/Homo_sapiens_assembly38.fasta.fai \
  https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Homo_sapiens_assembly38.fasta.fai
curl -fL -o references/kit1.bed '<your capture kit target BED>'
$EDITOR scripts/build_bed.sh
./scripts/build_bed.sh
```

**2. Write the samplesheet.** Absolute paths; `patient` is the individual, not the sequencing order
id; `status` 1 = tumour, 0 = normal; exactly one normal per patient. Nothing checks that the roles
are right — read it before you launch. → [docs/usage.md](docs/usage.md#the-samplesheet)

```bash
cp assets/samplesheet_template.csv assets/samplesheet.csv
$EDITOR assets/samplesheet.csv
```

**3. Run.** Set `SAMPLESHEET`, `INTERVALS`, `OUTDIR` and `WORKDIR`. `-preview` checks every path in
about 40 s and runs nothing. → [docs/parameters.md](docs/parameters.md)

```bash
$EDITOR scripts/run.sh
./scripts/run.sh -preview
./scripts/run.sh
```

About 17 h per tumour/normal pair on a 28-core box. `-resume` is always on, so an interrupted run
continues where it stopped.

→ `results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz`

## Docs

| | |
|---|---|
| [docs/usage.md](docs/usage.md) | the samplesheet, and the failure modes that cost real time |
| [docs/target-bed.md](docs/target-bed.md) | building the target, and choosing the padding |
| [docs/parameters.md](docs/parameters.md) | what `run.sh` sets, and why |
| [docs/output.md](docs/output.md) | what you get, and how to check it |
| [DECISIONS.md](DECISIONS.md) | why the pipeline is shaped the way it is |

Paired somatic calling only: no tumour-only mode, no annotation, one caller.
