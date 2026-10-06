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
resource overrides only; parameters passed that way produce errors. Give `OUTDIR` a new value each
run (a date or cohort label) so results don't collide; keep `WORKDIR` the same across runs so
`-resume` reuses cached tasks — recalibrated CRAMs, QC — instead of recomputing them.

`TOOLS` feeds `--tools`. The three `*_VS_*` switches pick which VCFs you get, and all three are on
by default: the somatic VCF per pair, a germline VCF per normal — the pair
[epitopeprediction](https://github.com/nf-core/epitopeprediction) takes as somatic calls plus
germline context — and each tumour's own calls against the reference.

| switch | what runs | where |
|---|---|---|
| `TUMOUR_VS_NORMAL` | paired somatic call, first sarek run, on by default | `variant_calling/<tool>/<T>_vs_<N>/` |
| `TUMOUR_VS_REF` | each tumour alone, on by default | `vs_reference/variant_calling/<tool>/<T>_only/` (Mutect2, Manta) and `<T>/` (Strelka, HaplotypeCaller) |
| `NORMAL_VS_REF` | each normal alone, on by default | same, for `<N>` |

The `_VS_REF` switches add a second sarek run from the recalibrated CRAMs, so they cost calling
time only. sarek routes a sample by `status` alone, so `run.sh` lists each selected sample twice
under two made-up patients: `<sample>_only` with status 1 reaches Mutect2 in tumour-only mode and
Manta, the bare id with status 0 reaches HaplotypeCaller, Strelka's germline model and Manta.
Mutect2 has no germline mode, and sarek has no tumour-only Strelka. Mutect2 on a normal is not a
germline call: what its filters let through is the patient's private variation, measured at
682 PASS on a normal against 734 in the paired call. The germline call to use is HaplotypeCaller's.

| flag | why |
|---|---|
| `--genome GATK.GRCh38` | fetches the genome, its indexes, dbSNP, known indels, the gnomAD germline resource and a prebuilt BWA index. It also turns on BQSR and applies a 1000g panel of normals, which changes which calls PASS |
| `--wes true` | targeted rather than whole-genome models |
| `--intervals` | your target BED |
| `--tools` | `TOOLS`. Manta is there only to hand Strelka indel candidates, and HaplotypeCaller only ever calls germline, so it does nothing in the paired run. **Pairing comes from the samplesheet's `status`, not from this flag** |
| `--only_paired_variant_calling true` | keeps the germline call off the normal in the paired run, so every single-sample VCF comes from the second run and lives in one place |
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
from 2 and 12. `STRELKA_.*` gets 2 cpus and 4 GB, down from 6 and 36: a shard measured at 1.3 cores
and 1 GB. With dozens of chunks under the cpu cap, per-chunk `cpus` is what decides how many run at
once. Keep the `* task.attempt` on the memory values: it is what lets a task that ran out of
memory ask for more when nextflow retries it.

## What you get

Under `results/`:

| path | what |
|---|---|
| `variant_calling/mutect2/<T>_vs_<N>/*.mutect2.filtered.vcf.gz` | **the one you want** |
| `variant_calling/mutect2/<T>_vs_<N>/*.mutect2.vcf.gz` | unfiltered; almost certainly not |
| `variant_calling/strelka/<T>_vs_<N>/*.somatic_{snvs,indels}.vcf.gz` | the second caller, in two files. Its columns are `NORMAL` and `TUMOR`, and it has no `GT` field |
| `variant_calling/manta/<T>_vs_<N>/` | structural variants; only here to feed Strelka indel candidates |
| `vs_reference/variant_calling/mutect2/<sample>_only/*.mutect2.filtered.vcf.gz` | the sample alone, tumour-only mode, when a `_VS_REF` switch is on |
| `vs_reference/variant_calling/strelka/<sample>/*.strelka.variants.vcf.gz` | the sample alone, germline mode. `*.genome.vcf.gz` next to it is the gVCF |
| `vs_reference/variant_calling/haplotypecaller/<N>/<N>.haplotypecaller.filtered.vcf.gz` | **the germline VCF**, filtered by GATK's CNN tranches. Germline only, so no `<T>` directory appears unless `TUMOUR_VS_REF` is on |
| `vs_reference/variant_calling/manta/<sample>_only/*.tumor_sv.vcf.gz`, `manta/<sample>/*.diploid_sv.vcf.gz` | structural variants, both modes |
| `vs_reference/samplesheet.csv` | the sheet `run.sh` derived for the second run. Read it if a `_VS_REF` output is missing |
| `preprocessing/recalibrated/<sample>/` | CRAMs |
| `multiqc/`, `reports/` | QC |
| `reference/` | whatever sarek built rather than downloaded; often nearly empty |

For epitopeprediction, one samplesheet row per patient maps onto these files as follows. Keep the
two VCFs separate: every record in `filename` is treated as a somatic candidate, so germline calls
there would become self peptides. The germline VCF is context only.

| column | value |
|---|---|
| `filename` | `variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz` |
| `tumor_sample` | `<patient>_<T>`, the genotype column name, not the file name |
| `germline_vcf` | `vs_reference/variant_calling/haplotypecaller/<N>/<N>.haplotypecaller.filtered.vcf.gz` |

Both come from the same reference under `--genome GATK.GRCh38`, so build and contig names match.

sarek names the VCF's two genotype columns `<patient>_<sample>`, but names the **file** from the
bare sample ids. They will not match, and that is not a bug.

## Checking a run

`run.sh` ends by writing `results/vcf_check.tsv`: one line per VCF with its genotype columns, its
record count and its PASS count. Read it against these values, measured on one exome pair at a
49.6 Mb target:

| VCF | measured | if it is far off |
|---|---|---|
| `mutect2/<T>_vs_<N>/*.mutect2.filtered` | 2 columns, tumour first; 734 PASS of 6,212 | one column or no `_vs_`: the patient had no `status=0` row. Tens of thousands PASS: tumour and normal swapped. The unfiltered `*.mutect2.vcf.gz` always shows 0 PASS |
| `strelka/<T>_vs_<N>/*.somatic_{snvs,indels}` | `NORMAL,TUMOR`; 930 and 8 PASS | should land near Mutect2's count, not at ten times it |
| `vs_reference/.../haplotypecaller/<N>/*.filtered` | 45,913 records, 98 % PASS | under 20,000: coverage or BED problem, check mosdepth. Over 60,000: the BED is wider than the kit |
| `vs_reference/.../strelka/<N>/*.variants` | 44,383 records, 95 % PASS | should track HaplotypeCaller within a few percent |
| `vs_reference/.../mutect2/<N>_only/*.filtered` | 682 PASS | germline the panel of normals cannot remove; not evidence of anything in the normal |
| `vs_reference/.../mutect2/<T>_only/*.filtered` | 1,330 PASS against 734 paired | about half germline, by the line above; not a somatic call set |

The germline VCF keeps its non-PASS records, tagged with CNN tranche filters, so epitopeprediction
must select PASS. Of the 734 somatic PASS calls, the 150 bp windows around them held 160 PASS
germline variants: roughly one somatic site in five has germline context nearby.

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
- **The second run only works from the directory the first was launched in.** sarek writes the
  CRAM paths in `results/csv/recalibrated.csv` relative to that directory, and `run.sh` copies them
  as they are. `-preview` never reaches the second run, since its inputs do not exist yet.
- **`Unable to parse config file`, on a host with no IPv4.** sarek fetches part of its config over
  https and Java tries IPv4 first, so the run dies before reading a single parameter — even though
  `curl` works on the same machine. `run.sh` already exports the fix.
- **Changing `memory` in a `withName` block re-runs that process and everything after it.** GATK
  renders `-Xmx` from `task.memory` into its command line, and that command line is part of a
  task's identity. The `executor` cap is free to change, and so is `cpus` on the two blocks here —
  but fastp renders `--thread`, so giving fastp a block would re-run nearly everything.
- **`no space left on device`, hours in.** Almost always `/var/lib/containerd`.
