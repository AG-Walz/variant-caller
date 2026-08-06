# Output

Under `results/`:

| path | what |
|---|---|
| `variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz` | the one you want — `FilterMutectCalls` output |
| `variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.vcf.gz` | unfiltered; almost certainly not |
| `preprocessing/recalibrated/<sample>/` | CRAMs |
| `reference/` | what sarek generated for the run (`--save_reference`) |
| `multiqc/`, `reports/` | QC |

A file **without** `_vs_` in its name means that patient ran tumour-only — see
[usage.md](usage.md).

sarek writes the read group as `SM:<patient>_<sample>`, so the VCF's genotype columns are
patient-prefixed while the **file** is named from the bare sample ids. Comparing the file name to
the column names fails a perfectly good run.

If your target includes a mitochondrial panel, treat chrM calls as indicative rather than
validated: mitochondrial variants are heteroplasmic and Mutect2 is not run in `--mitochondria-mode`.

## Checking it

`VCF` below is `results/variant_calling/mutect2/*/*.mutect2.filtered.vcf.gz`.

| check | command |
|---|---|
| the target BED is canonical, being unchanged by its own recipe | `bedtools sort -faidx $FAI -i $BED \| bedtools merge -i - \| bedtools slop -i - -g $FAI -b 0 \| cmp - $BED` |
| two genotype columns, named `<patient>_<sample>` | `bcftools query -l $VCF` |
| how many calls PASS | `bcftools query -f '%FILTER\n' $VCF \| sort \| uniq -c \| sort -rn` |
| coverage over the target | `cat results/reports/mosdepth/*/*.mosdepth.summary.txt` |

## What nothing checks

- **Samplesheet cardinality, and a swapped tumour/normal.** See
  [usage.md](usage.md#failure-modes-that-cost-real-time).
- **The intervals contract.** `build_bed.sh` makes it true by construction rather than asserting
  it. A zero-length interval would still get through — GATK rejects those loudly, so it is not
  silent.
- **`--germline_resource` exists.** It is the only Mutect2 reference parameter with no
  `"exists": true` in sarek's schema, so a wrong path is not caught, and without the resource sarek
  publishes the **unfiltered** VCF. `--genome GATK.GRCh38` supplies it; this only bites if you
  override it.
