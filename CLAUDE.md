# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project Overview

`variant-caller` v1 is a **lean orchestration repo**, not an nf-core DSL2 pipeline. It turns
tumour/normal **FASTQ + user-declared sample labels** into **one paired somatic VCF per
patient**, and nothing else. It does this by **shelling out** to a single, pinned
`nextflow run` of a **sibling clone of upstream nf-core/sarek** (tag 3.9.0) that lives beside
this repo at `../sarek`. It does **not** `include` sarek modules, fork sarek, or reimplement
calling. There is no `main.nf`, no `modules/`, no `workflows/`.

Mirror the shape of the sibling `fastq-to-fasta` repo: README + CLAUDE at top, bash run
scripts, a minimal resource `nextflow.config` passed via `-c`, example inputs under `assets/`.
This repo adds `bin/` helper tools and `tests/` for soundness.

## Repository Structure

- `scripts/setup_env.sh` — bootstrap a fresh box: clone the sibling `../sarek` at tag 3.9.0 and
  install Nextflow. Idempotent; installs **no** system packages (detects Java/Docker, prints the
  install command instead of running it).
- `tests/check_environment.sh` — read-only preflight; PASS/FAIL/WARN table, non-zero exit if any
  hard requirement is unmet. Named `check_*` so the `tests/test_*` glob stays the unit tests.
- `scripts/fetch_references.sh` — download GRCh38 + gnomAD germline resource into `references/`.
- `scripts/run_pilot.sh` — the pinned minimal `nextflow run ../sarek ...` for the pilot pair.
- `bin/build_kit_bed.sh --out <bed> --fai <ref.fai> [--verify <counts.gz>]` — **canonical** target
  BED, built from the capture kit vendor's own files (Twist `..._RefSeq_targets_hg38.bed` +
  `..._MitoPanel_chrM_all_hg38_target.bed`). `--fai` clamps padded ends to contig lengths; without
  it `chrM` runs past its end and GATK rejects the interval.
- `bin/build_target_bed.sh <counts.gc-corrected.gz> <out.bed> [--pad N]` — the same BED
  reconstructed from DRAGEN counts. **Verification only**, not the input: it is the only evidence
  of what was physically captured, so use it to check the kit BED.
- `bin/build_samplesheet.py --declarations <tsv> --fastq-dir <dir> --out <csv>` — validated
  sarek samplesheet.
- `bin/assert_output.py --tumour <id> --normal <id> <vcf>` — enforce the output contract on the
  produced VCF (pure python3 + gzip).
- `assets/` — example declarations TSV (`pilot_declarations.tsv`) and example samplesheet
  (`samplesheet_pilot_example.csv`).
- `nextflow.config` (repo root) — minimal per-process resource override passed to sarek via `-c`.
- `tests/` — dependency-light soundness checks for the helper tools.
- `docs/` — introduction, inputs, usage, output, steps.

## How to run (pilot, on peptimine_highmem1)

```bash
scripts/setup_env.sh                 # fresh box: clone ../sarek 3.9.0 + install Nextflow
tests/check_environment.sh           # verify (incl. Java 17+, Docker, RAM, sarek sibling)
scripts/fetch_references.sh          # once → references/
bin/build_target_bed.sh /mnt/volume/data/DNA/00_metrics/<sample>.target.counts.gc-corrected.gz \
    references/target_pad30.bed      # once
bin/build_samplesheet.py --declarations assets/pilot_declarations.tsv \
    --fastq-dir <FASTQ dir ON THIS BOX> \
    --out assets/samplesheet_pilot.csv           # REQUIRED: paths are absolute
INPUT=assets/samplesheet_pilot.csv scripts/run_pilot.sh   # pinned command AND the assertion
```

`assets/samplesheet_pilot_example.csv` is an **example** carrying one box's absolute paths.
sarek's `schema_input.json` sets `"exists": true` on `fastq_1`/`fastq_2`, so it must be
regenerated wherever the run happens; `run_pilot.sh` pre-flights this and refuses to launch
otherwise.

`run_pilot.sh` calls `bin/assert_output.py --tumour S12944Nr11 --normal S12944Nr12 <vcf>`
itself once the VCF is produced.

Target box: 28 cores, ~503 GB RAM, **Docker only** (no singularity/apptainer), **Nextflow not
pre-installed**, run in `screen`. So: always `-profile docker`; run scripts check for
`nextflow`; **not** SLURM/`sbatch`.

**Versions are hard requirements, not preferences:** sarek 3.9.0 pins
`nextflowVersion = '!>=25.10.2'` (the leading `!` makes a lower version a launch failure), and
Nextflow 25.10 needs **Java 17+** — not 11.

## The pinned sarek command (every token is deliberate — do not add flags not listed)

```
nextflow run ../sarek -profile docker -c <RESOURCE_CONFIG> \
  --step mapping --tools mutect2 --wes --igenomes_ignore true \
  --input <samplesheet.csv> --outdir <outdir> \
  --intervals <target_pad30.bed> --nucleotides_per_second 1000 \
  --fasta Homo_sapiens_assembly38.fasta --fasta_fai ...fasta.fai --dict ...dict \
  --germline_resource af-only-gnomad.hg38.vcf.gz \
  --skip_tools baserecalibrator,fastqc,mosdepth,samtools,multiqc,bcftools,vcftools \
  --markduplicates_pixel_distance 2500 --trim_fastq --trim_nextseq \
  --save_reference -resume
```

## Key domain facts

- **`--trim_fastq`, `--trim_nextseq`, `--wes` and `--save_reference` are boolean** bare flags in
  this clone; `--nucleotides_per_second` (default 200000, we use 1000) and
  `--markduplicates_pixel_distance` are integers.
- **`--trim_nextseq` alone does nothing.** FASTP is gated on
  `params.trim_fastq || params.split_fastq > 0 || params.umi_location`
  (`subworkflows/local/fastq_preprocess_gatk/main.nf:107`) — without `--trim_fastq` the process
  never runs and no poly-G trim happens, silently. The reads are NovaSeq 6000 (2-colour).
- **The bwa-mem2 index build needs ~87 GB RAM** (`280 MB × ceil(fasta_size / 10 MB)`,
  `modules/nf-core/bwamem2/index/main.nf:5`). This is why the run is highmem-only, and why we
  pass `--save_reference` (sarek's default `save_reference = false` throws the index away).
- **`--germline_resource` doubles** as the GetPileupSummaries/contamination source. Without it,
  the clone **silently** publishes the *unfiltered* VCF (FILTER all `.`) — so passing it is
  required and `assert_output.py` is a mandatory safety net.
- **The target BED must be exactly 3 columns.** `create_intervals_bed` reads column 5 as a
  per-region runtime-seconds estimate; extra columns silently break the scatter.
- **Labels/patient grouping are DECLARED, never inferred.** The UrCa Nr-odd/even filename habit
  is a vendor convention; DRAGEN VCFs order genotype columns normal-then-tumour against a
  tumour-then-normal filename, so guessing is unsafe.
- **Downcast:** `tumour` → status 1; `tumour_adjacent`/`control_healthy`/`control_benign` →
  status 0. Emitted samplesheet header: `patient,sex,status,sample,lane,fastq_1,fastq_2`
  (`sex=NA`, `lane=L001`).
- **Patient id must be e.g. `P11`, NEVER the order id `S000021`** (that collapses the cohort
  into one individual and crosses every tumour against every normal).
- **v1 is paired somatic only.** Mutect2 also has a tumour-only sub-workflow; a patient with no
  `status=0` silently routes there and yields a non-paired VCF. Validator + the `_vs_` /
  by-name-column assertion prevent this.
- Pilot deliverable: `S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz`.

## Dev-box constraints

Helper tools must be dependency-light: **pure `python3` stdlib** (no pysam/pandas) and
`awk`/coreutils bash only. On this dev box `docker`, `java`, `nextflow`, `bedtools`, `bgzip`,
`tabix`, `shellcheck` are **not** available — validate with `bash -n` / `python3 -m py_compile`.

## Scope boundaries (v1 vs v2)

**v1:** FASTQ + declared labels → one paired somatic Mutect2 VCF per patient, by wrapping the
local sarek clone. That is all.

**NOT in v1 (v2 or downstream):** kit registry / bait BED / hybrid-capture QC; tumour-only
mode; preference-ordered normal selection; epitopeprediction handoff samplesheet; annotation /
VEP; multiple callers; BQSR; MultiQC / QC bundle; a GUI. When editing docs, keep every file
consistent with the pinned command and the output contract; do not reintroduce the parked
pre-reversal vision as if it were v1.

**v3 (recorded 2026-07-24, not started):** replace CeGaT's exome bioinformatics **Levels 2–5** —
consume Level 1 (FASTQ + CSV) and deliver mapping, SNV/indel **and ROH** calling, annotation,
CNV calling and variant comparison. Full mapping, the five real gaps and the decisions it
reopens: **[`docs/roadmap.md`](docs/roadmap.md)**. Load-bearing fact: **sarek has no ROH support
at all** (`modules/nf-core/bcftools/` has no `roh`, and `--tools` has no ROH entry) — it is the
one Level 1–5 capability that is missing rather than merely switched off. Do **not** pull v3
scope into v1.

## Where to work

Develop only inside this repo. The siblings `../sarek`, `../fastq-to-fasta`, `../docs` are
**read-only reference** — never modify them.
