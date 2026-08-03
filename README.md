# variant-caller

Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0.

**Purpose:** an independent call set, to check whether the sequencing vendor's own run was done
correctly. Not a reproduction of their calls — the reference they delivered was the wrong genome
build, which is what prompted this.

Two scripts, both editable templates in the style of
[fastq-to-fasta](https://github.com/AG-Walz/fastq-to-fasta)'s example scripts: change the
variables at the top and run.

```
scripts/build_bed.sh  once per kit   your capture-kit BEDs -> one target BED
scripts/run.sh        every run      the nextflow command
```

## Requirements

Docker, Java 17+, `bedtools`, and **Nextflow 25.10.x — not 26.x**, which aborts on a valid
paired samplesheet.

```bash
mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools
export PATH=~/envs/vc/bin:$PATH
```

There is no reference download step. `--genome GATK.GRCh38` makes sarek fetch the GRCh38 bundle
— FASTA, `.fai`, `.dict`, the gnomAD germline resource, the BWA index, dbSNP and known indels —
from `s3://ngi-igenomes/igenomes/` on first run.

## Run it

**1. Build the target BED** — the one input sarek will not build for you.
→ [docs/target-bed.md](docs/target-bed.md)

```bash
mkdir -p references && cd references
curl -O https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Homo_sapiens_assembly38.fasta.fai
curl -O <your capture kit's target BED>          # one or more, from the kit vendor
cd ..
$EDITOR scripts/build_bed.sh                     # set BEDS, FAI, PADDING, OUTPUT
./scripts/build_bed.sh                           # prints regions and total bp
```

**2. Write the samplesheet.** Absolute paths; `status` 1 = tumour, 0 = normal; exactly one normal
per patient. → [docs/usage.md](docs/usage.md#the-samplesheet)

```bash
cp assets/samplesheet_template.csv assets/samplesheet_pilot.csv
$EDITOR assets/samplesheet_pilot.csv
```

**3. Point the run at both, and go.** → [docs/parameters.md](docs/parameters.md)

```bash
$EDITOR scripts/run.sh                           # SAMPLESHEET, INTERVALS, OUTDIR, PROFILE
./scripts/run.sh -preview                        # ~40 s: validates every path, runs nothing
./scripts/run.sh
```

→ `results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz`
→ [docs/output.md](docs/output.md)

Roughly 17 h for one tumour/normal pair on 28 cores. `run.sh` always passes `-resume`, so an
interrupted run continues where it stopped.

## Documentation

| | |
|---|---|
| [docs/usage.md](docs/usage.md) | the samplesheet, the run box, and the failure modes that cost real time |
| [docs/target-bed.md](docs/target-bed.md) | building the target, and how to choose the padding |
| [docs/parameters.md](docs/parameters.md) | every flag in `run.sh`, why it is set, what is deliberately not |
| [docs/output.md](docs/output.md) | what you get, and how to check it |
| [DECISIONS.md](DECISIONS.md) | why the pipeline is shaped the way it is |

## Scope

Paired somatic calling only: no tumour-only mode, no annotation, one caller. Annotation happens
downstream in [nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction).
