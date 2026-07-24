# Steps — operator runbook (pilot on peptimine_highmem1)

End-to-end recipe to produce the pilot deliverable: tumour `S12944Nr11` vs its normal
`S12944Nr12`, one paired somatic VCF. Run on the target box (28 cores, ~503 GB RAM, Docker
only). Each step lists the exact command and what to expect.

Assumes you are in the repo root: `/mnt/volume/variant_caller/variant-caller`.

## 0a. On a fresh box: clone both repos as siblings, then bootstrap

`run_pilot.sh` resolves sarek as **`../sarek`** — this repo *wraps* sarek by path, it does not
vendor or fork it. So the two must sit side by side:

```bash
mkdir -p ~/variant_caller && cd ~/variant_caller
git clone https://github.com/AG-Walz/variant-caller.git
cd variant-caller && git checkout feat/v1-pilot   # main is still the scaffold

scripts/setup_env.sh          # clones ../sarek at 3.9.0 + installs Nextflow
tests/check_environment.sh    # verifies everything, including what setup_env does not install
```

`setup_env.sh` is idempotent and installs no system packages — it detects Java and Docker and
tells you the command to install them, rather than running it for you on a shared box.
`check_environment.sh` is read-only and exits non-zero if any hard requirement is unmet.

**Versions are not negotiable:** sarek 3.9.0 pins `nextflowVersion = '!>=25.10.2'`, and the
leading `!` makes a lower version a **hard launch failure**, not a warning. Nextflow 25.10 in
turn requires **Java 17+**.

## 0b. Start a screen session

A full run is long; a dropped SSH connection must not kill it.

```bash
screen -S variant-caller
```

(Reattach later with `screen -r variant-caller`.)

## 1. Install Nextflow (once)

`scripts/setup_env.sh` in step 0a does this for you. To do it by hand:

```bash
which nextflow   # if this prints a path, check it is >= 25.10.2
curl -s https://get.nextflow.io | bash
sudo mv nextflow /usr/local/bin/    # or put it anywhere on PATH
nextflow -version                   # must be >= 25.10.2
```

Nextflow needs **Java 17+** (not 11 — 25.10 dropped it), e.g.
`sudo apt-get install -y openjdk-17-jre-headless`. Docker must be usable by your user without
sudo (`docker ps` should work). `scripts/run_pilot.sh` also checks for `nextflow` and `docker`
and stops with guidance if either is missing.

## 2. Fetch references (once, large download)

Downloads GRCh38 (`Homo_sapiens_assembly38.fasta` + `.fai` + `.dict`) and the gnomAD germline
resource (`af-only-gnomad.hg38.vcf.gz` + `.tbi`) into `references/` (git-ignored).

```bash
scripts/fetch_references.sh
```

Expect several tens of GB. The gnomAD VCF doubles as the contamination source, so no separate
small-exac file is needed.

## 3. Build the target BED (once)

Turns a DRAGEN target-count file into a **3-column**, **30 bp-padded** interval BED. The
target set is identical across all 18 UrCa samples, so any one `*.target.counts.gc-corrected.gz`
works and this is built once for the cohort. The run script expects it at
`references/target_pad30.bed`.

```bash
bin/build_target_bed.sh \
  /mnt/volume/data/DNA/00_metrics/<sample>.target.counts.gc-corrected.gz \
  references/target_pad30.bed
```

The output BED must be exactly 3 columns (`chrom  start  end`) — an extra column 5 would be
read by sarek as a per-region runtime estimate and silently break the interval scatter. The
canonical pad-30 output is checksum-verified (region and bp counts), so a wrong or changed
input file fails hard rather than silently.

## 4. Build the pilot samplesheet — **on the box that will run it**

Do not skip this. The samplesheet carries **absolute** FASTQ paths, and sarek's
`assets/schema_input.json` sets `"exists": true` on `fastq_1`/`fastq_2`, so a path that is
right on one machine is a hard launch failure on another. `assets/samplesheet_pilot_example.csv`
is committed as an **example** and carries one box's paths; regenerate it wherever the run
actually happens. (`run_pilot.sh` pre-flights this and refuses to launch if any FASTQ in the
sheet is missing, naming the files and this command.)

The declarations TSV is the portable artefact — it names samples, not paths. The builder merges
it with auto-discovery of the FASTQ files (R1/R2 pairing, sample id, lane), validates, and
writes the sarek samplesheet.

```bash
bin/build_samplesheet.py \
  --declarations assets/pilot_declarations.tsv \
  --fastq-dir <the FASTQ directory on THIS box> \
  --out assets/samplesheet_pilot.csv
```

Then run step 5 with `INPUT=assets/samplesheet_pilot.csv`.

`assets/pilot_declarations.tsv` declares (header row optional):

```
sample	patient	label
S12944Nr11	P11	tumour
S12944Nr12	P11	tumour_adjacent
```

The tool refuses to emit unless, for patient `P11`: every sample has a valid label, there is
exactly one `status=0` row (Nr12), and at least one `status=1` row (Nr11). The emitted sheet
has the header `patient,sex,status,sample,lane,fastq_1,fastq_2` (see [inputs.md](inputs.md)).

## 5. Run the pinned minimal sarek command

```bash
scripts/run_pilot.sh
```

The script first runs pre-flight checks (nextflow + docker present and usable; references, BED,
samplesheet, and resource `nextflow.config` in place; samplesheet header exactly correct; every
FASTQ named in the samplesheet exists on this box), then
wraps the local `../sarek` clone with the pinned flags (`-profile docker`, `--step mapping`,
`--tools mutect2`, `--wes`, the explicit reference files, `--germline_resource`,
`--skip_tools ...`, `--trim_fastq --trim_nextseq`, `--save_reference`, `-resume`; full command
in [usage.md](usage.md)). It maps
the reads, marks duplicates, runs paired Mutect2 over the target, and runs FilterMutectCalls.
Alignment dominates the runtime. `-resume` makes re-runs after a downstream hiccup cheap.
Override any path via environment variables (`SAREK_DIR`, `OUTDIR`, `INPUT`, `TARGET_BED`,
`TUMOUR_ID`, `NORMAL_ID`, ...).

## 6. Assertion (run automatically by step 5)

`run_pilot.sh` locates `S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz` under
`<outdir>/variant_calling` and runs the assertion itself. To re-check by hand:

```bash
bin/assert_output.py --tumour S12944Nr11 --normal S12944Nr12 \
  results/variant_calling/S12944Nr11_vs_S12944Nr12/S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz
```

Passes only if: filename contains `_vs_` and ends `.mutect2.filtered.vcf.gz`; FILTER is not
all `.`; exactly two genotype columns named `S12944Nr11` and `S12944Nr12`; `##tumor_sample=`
/ `##normal_sample=` match those names; `FORMAT` has `AF`; `##contig` (GRCh38) present. Any
failure exits non-zero and names the first failed check. Full contract in
[output.md](output.md).

## Expected pilot output

```
results/variant_calling/S12944Nr11_vs_S12944Nr12/S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz
```

(plus its `.tbi` index). That single file is the v1 deliverable for this patient.

## Extending beyond the pilot

For another pair, write a new declarations TSV (correct `patient` ids — never the `S000021`
order id), rebuild the samplesheet with `bin/build_samplesheet.py`, and run the same pinned
command with that samplesheet. The target BED and references are reused. Remember: v1 is
**paired only** — every patient needs exactly one declared normal, or the build fails.
