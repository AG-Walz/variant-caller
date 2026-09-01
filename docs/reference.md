# Reference

## The target BED

`--intervals` restricts calling to the regions your kit sequenced, and it is the one input sarek
will not build for you. `scripts/build_bed.sh` builds it: set `BEDS`, `FAI`, `PADDING` and `OUTPUT`
at the top. Two of its steps are load-bearing.

- **`bedtools sort -faidx` puts the regions in the reference's own contig order.** Plain `sort` is
  alphabetical and puts chr10 before chr2; `sort -V` fixes that and still gets chrM, chrX, chrY and
  the alt contigs wrong. GATK trusts whatever order it is handed, so a wrongly sorted BED runs for
  half an hour and then dies in `CalculateContamination`.
- **`bedtools merge` emits exactly 3 columns.** sarek reads a wider BED's 5th column as a runtime
  estimate and shatters the run into thousands of chunks instead of dozens.

`FAI` must index the genome you call against — under `--genome GATK.GRCh38`, the one the README
downloads. Your kit BED must use the same contig names (`chr1`, not `1`).

30 bp of padding is the default; sarek adds none of its own. Keep the number in the output
filename, so a BED built at one padding cannot be picked up by a run expecting another.

For a BED that did not come from this script, check it is canonical. This prints nothing if it is:

```bash
bedtools sort -faidx $FAI -i $BED | bedtools merge -i - | bedtools slop -i - -g $FAI -b 0 | cmp - $BED
```

## The samplesheet

sarek's native format. Paths must be absolute and must exist on the machine that runs.

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
P1,NA,1,tumour_lib,L001,/abs/path/tumour.1.fastq.gz,/abs/path/tumour.2.fastq.gz
P1,NA,0,normal_lib,L001,/abs/path/normal.1.fastq.gz,/abs/path/normal.2.fastq.gz
```

- **`patient` is the individual**, never the sequencing order id. An order id shared across people
  collapses the cohort into one patient and pairs tumours against other people's normals.
- **`status` is 1 for tumour, 0 for normal.** Every patient needs exactly one 0.
- **`sample`** is the library, one row per lane. `sex` may be `NA`.

## What `run.sh` sets

`SAMPLESHEET`, `OUTDIR`, `WORKDIR` and `INTERVALS` feed `--input`, `--outdir`, `-work-dir` and
`--intervals`. `PROFILE` feeds `-profile` — change it if you use singularity or conda instead of
docker. Leave `SAREK` at 3.9.0, the version this is validated against. `-c nextflow.config` carries
resource overrides only; parameters passed that way produce errors.

| flag | why |
|---|---|
| `--genome GATK.GRCh38` | fetches the genome, its indexes, dbSNP, known indels, the gnomAD germline resource and a prebuilt BWA index. It also turns on BQSR and applies a 1000g panel of normals, which changes which calls PASS |
| `--wes true` | targeted rather than whole-genome models |
| `--intervals` | your target BED |
| `--tools mutect2` | the caller. **Pairing comes from the samplesheet's `status`, not from this flag** |
| `--nucleotides_per_second 1000` | splits calling into dozens of parallel chunks. At sarek's default an exome stays in one chunk and Mutect2 runs single-threaded for the whole run |
| `--markduplicates_pixel_distance 2500` | for patterned flowcells such as NovaSeq. On unpatterned optics set it back to 100 |
| `--trim_fastq true`, `--trim_nextseq true` | adapter and poly-G trimming. Poly-G matters on two-colour chemistry, which reads "no signal" as G |
| `--save_reference true` | keeps anything sarek built under `results/reference/`. Under `--genome` most references arrive prebuilt, so expect little there |
| `-resume` | always on |

## `nextflow.config`

Resource overrides only. **It ships sized for a 28-core, 500 GB box — lower
`executor { cpus; memory }` to match your machine.** That block caps the sum across all running
tasks at once, and it is free to change at any point.

`GATK4_MARKDUPLICATES` gets 60 GB against sarek's 30 GB; `GATK4_MUTECT2` gets 4 cpus and 16 GB, up
from 2 and 12. With dozens of chunks under the cpu cap, per-chunk `cpus` is what decides how many
run at once. Keep the `* task.attempt` on the memory values: it is what lets a task that ran out of
memory ask for more when nextflow retries it.

## What you get

Under `results/`:

| path | what |
|---|---|
| `variant_calling/mutect2/<T>_vs_<N>/*.mutect2.filtered.vcf.gz` | **the one you want** |
| `variant_calling/mutect2/<T>_vs_<N>/*.mutect2.vcf.gz` | unfiltered; almost certainly not |
| `preprocessing/recalibrated/<sample>/` | CRAMs |
| `multiqc/`, `reports/` | QC |
| `reference/` | whatever sarek built rather than downloaded; often nearly empty |

sarek names the VCF's two genotype columns `<patient>_<sample>`, but names the **file** from the
bare sample ids. They will not match, and that is not a bug.

```bash
VCF=results/variant_calling/mutect2/*/*.mutect2.filtered.vcf.gz
bcftools query -l $VCF                              # two columns: tumour, then normal
bcftools query -f '%FILTER\n' $VCF | sort | uniq -c # how many calls PASS
cat results/reports/mosdepth/*/*.mosdepth.summary.txt
```

Two blind spots when you read the calls. chrM, if your kit carries a mito panel, since Mutect2 is
not run in mitochondria mode here. And the regions GRCh38 falsely duplicates — CBS, CRYAA, KCNE1,
SMN1/SMN2, MRC1 and U2AF1 among them — where MAPQ drops to 0 and variants go missing rather than
appear. A call absent there is the reference's blind spot, not evidence against whoever reported it.

## What bites

Nothing validates the samplesheet, so the first three fail in silence.

- **A swapped tumour and normal is undetectable** — by sarek, by the output, by anything
  downstream. Reading the samplesheet before you launch is the only defence there is.
- **A patient with no `status=0` row runs tumour-only and finishes normally**, handing you a VCF
  full of inherited variants. The one visible symptom is a filename with no `_vs_` in it.
- **`status: 1.00` is not `1`, and a missing status column makes every row a normal.**
- **`Unable to parse config file`, on a host with no IPv4.** sarek fetches part of its config over
  https and Java tries IPv4 first, so the run dies before reading a single parameter — even though
  `curl` works on the same machine. `run.sh` already exports the fix.
- **Changing `memory` in a `withName` block re-runs that process and everything after it.** GATK
  renders `-Xmx` from `task.memory` into its command line, and that command line is part of a
  task's identity. The `executor` cap is free to change, and so is `cpus` on the two blocks here —
  but fastp renders `--thread`, so giving fastp a block would re-run nearly everything.
- **`no space left on device`, hours in.** Almost always `/var/lib/containerd`.
