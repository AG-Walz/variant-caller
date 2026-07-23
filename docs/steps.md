# Steps — operator runbook (pilot on peptimine_highmem1)

End-to-end recipe to produce the pilot deliverable: tumour `S12944Nr11` vs its normal
`S12944Nr12`, one paired somatic VCF. Run on the target box (28 cores, ~503 GB RAM, Docker
only). Each step lists the exact command and what to expect.

Assumes you are in the repo root: `/mnt/volume/variant_caller/variant-caller`.

## 0. Start a screen session

A full run is long; a dropped SSH connection must not kill it.

```bash
screen -S variant-caller
```

(Reattach later with `screen -r variant-caller`.)

## 1. Install Nextflow (once)

Nextflow is **not** pre-installed on this box. It needs Java 11+.

```bash
which nextflow   # if this prints a path, skip this step
curl -s https://get.nextflow.io | bash
sudo mv nextflow /usr/local/bin/    # or put it anywhere on PATH
nextflow -version
```

`scripts/run_pilot.sh` also checks for `nextflow` and stops with guidance if it is missing.
Docker must be usable by your user (`docker ps` should work).

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

## 4. Build the pilot samplesheet (optional — an example is committed)

`assets/samplesheet_pilot_example.csv` is already in the repo and is what `run_pilot.sh` uses
by default, so for the pilot you can skip straight to step 5. Run this only to regenerate it or
to build a sheet for other samples. It merges the declarations TSV (which sample is which
patient / label) with auto-discovery of the FASTQ files (R1/R2 pairing, sample id, lane),
validates it, and writes the sarek samplesheet.

```bash
bin/build_samplesheet.py \
  --declarations assets/pilot_declarations.tsv \
  --fastq-dir /mnt/volume/data/fastq-example-data/UrCA/01_fastq \
  --out assets/samplesheet_pilot_example.csv
```

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
samplesheet, and resource `nextflow.config` in place; samplesheet header exactly correct), then
wraps the local `../sarek` clone with the pinned flags (`-profile docker`, `--step mapping`,
`--tools mutect2`, `--wes`, the explicit reference files, `--germline_resource`,
`--skip_tools ...`, `--trim_nextseq`, `-resume`; full command in [usage.md](usage.md)). It maps
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
