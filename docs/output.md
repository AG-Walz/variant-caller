# Output

```
results/
├── variant_calling/mutect2/<T>_vs_<N>/
│   ├── <T>_vs_<N>.mutect2.filtered.vcf.gz     ← the one you want
│   └── <T>_vs_<N>.mutect2.vcf.gz              ← unfiltered; almost certainly not
├── preprocessing/recalibrated/<sample>/       CRAMs
├── reference/                                 the built index (--save_reference)
└── multiqc/, reports/                         QC
```

`filtered` is the `FilterMutectCalls` output. A file **without** `_vs_` in its name means that
patient ran tumour-only — see [usage.md](usage.md).

## Checking it

```bash
# the target BED is canonical iff unchanged by its own recipe
FAI=references/Homo_sapiens_assembly38.fasta.fai
BED=references/target_pad30.bed
bedtools sort -faidx $FAI -i $BED | bedtools merge -i - | bedtools slop -i - -g $FAI -b 0 | cmp - $BED

# two genotype columns, named <patient>_<sample>
bcftools query -l results/variant_calling/mutect2/*/*.vcf.gz

# how many calls actually PASS
bcftools query -f '%FILTER\n' results/variant_calling/mutect2/*/*.vcf.gz | sort | uniq -c | sort -rn

# coverage over the target — the point of the exercise
cat results/reports/mosdepth/*/*.mosdepth.summary.txt
```

sarek writes the read group as `SM:<patient>_<sample>`, so the VCF's genotype columns are
patient-prefixed while the **file** is named from the bare sample ids. Comparing the file name to
the column names fails a perfectly good run.

## What nothing checks

Each of these fails silently or expensively. They were enforced by 2,606 lines of code that was
deleted on 2026-07-30, and the reasons for deleting it still hold — but know they are gone:

- **Samplesheet cardinality.** A missing normal runs tumour-only and completes. `status: 1.00`
  parses as a BigDecimal; an absent status column defaults every row to 0.
- **A swapped tumour/normal.** Not detectable by any check here, in sarek, or in the output.
- **The intervals contract.** `build_bed.sh` makes it true by construction rather than asserting
  it. A zero-length interval would still get through — GATK rejects those loudly, so it is not
  silent.
- **Free space on `/var/lib/containerd`.** Two runs died there.

The pilot's own numbers, for comparison: 10,642 records, 683 PASS, produced without a panel of
normals and with BQSR off. The current configuration has both on, so neither number should be
expected to reproduce.
