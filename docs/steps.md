# Steps — the operator runbook

Two commands. There is no code in this repository: the target BED is a bedtools one-liner,
and the run is stock nf-core/sarek driven by `params/pilot.yaml`.

```bash
# 1. the target BED (once per reference)
FAI=references/Homo_sapiens_assembly38.fasta.fai
T=https://www.twistbioscience.com/content/dam/twistbioscience/resources
cat <(curl -sL $T/2019-09/Twist_Exome_RefSeq_targets_hg38.bed) \
    <(curl -sL $T/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed) \
  | bedtools sort -faidx $FAI | bedtools merge -i - \
  | bedtools slop -i - -g $FAI -b 30 | bedtools merge -i - > references/target_pad30.bed

# 2. the run
nextflow run ../sarek -profile docker -c nextflow.config -params-file params/pilot.yaml -w work -resume
```

Expected BED: **214,494 regions / 49,633,134 bp**, md5 `69ed88c5131c8613efe5e20e66954e74`.

**Two flags in that one-liner are load-bearing.** `-faidx` orders contigs the way the
*reference* does; without it bedtools sorts contig names as strings (chr19 before chr2, chrM
before chrX), and sarek reads `--intervals` in the order given while GATK's
`GatherPileupSummaries` assumes dictionary order — that combination killed a run 29m46s in
with `Invalid interval. Contig:chr22 start:42062823 end:40827186`. `-g` on `slop` clamps the
padding to contig lengths; chrM is 16,569 bp and the mito panel tiles all of it, so +30 would
run past the end and GATK rejects out-of-bounds intervals. `slop` refuses to run without `-g`;
`sort` will happily run without `-faidx`.

Padding is 30 bp because that is CeGaT's own DRAGEN setting (`--vc-target-bed-padding 30`);
their coverage metrics (49,599,660 bp) confirm calls are reported over the padded territory.

## Once per box

```bash
git clone --branch 3.9.0 --depth 1 https://github.com/nf-core/sarek.git ../sarek
mamba create -y -p /mnt/volume/bin/envs/vc -c conda-forge -c bioconda \
    nextflow=25.10.4 openjdk=17 bedtools
export PATH=/mnt/volume/bin/envs/vc/bin:$PATH
```

**Pin Nextflow to 25.10.x.** sarek 3.9.0 requires `>=25.10.2`, but `get.nextflow.io` currently
installs **26.04.6**, under which the pinned invocation aborts on a valid paired samplesheet
with *"The sample-sheet only contains normal-samples … expect at least one tumor-sample"*.
Nextflow 25.10 needs **Java 17+**, not 11. Docker must work without sudo.

Run long jobs so the log survives: `tmux new -d -s vc "nextflow run … 2>&1 | tee -a run.log"`.

## References

```bash
B=https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0
G=https://storage.googleapis.com/gatk-best-practices/somatic-hg38
mkdir -p references/bwa
aria2c -x8 -s8 -c -d references $B/Homo_sapiens_assembly38.fasta{,.fai} $B/Homo_sapiens_assembly38.dict
aria2c -x8 -s8 -c -d references $G/af-only-gnomad.hg38.vcf.gz{,.tbi}
for e in amb ann bwt pac sa; do
    aria2c -x8 -s8 -c -d references/bwa -o Homo_sapiens_assembly38.$e $B/Homo_sapiens_assembly38.fasta.64.$e
done
```

The last loop fetches the published BWA-MEM1 index, byte-identical to the one sarek otherwise
spends **1h14m50s** building. Uncomment `bwa: references/bwa` in `params/pilot.yaml` to use it
(it changes the alignment tasks' input identity, so adopt it on a fresh cohort, not mid-run).

`af-only-gnomad.hg38.vcf.gz` is not optional: it is both Mutect2's population resource and the
contamination source, and **without it sarek publishes the unfiltered VCF with no error**.
`aria2c` also verifies transfers if you pass `--check-integrity=true --checksum=md5=<published>`;
`curl -C -` and `wget -c` both silently accept a same-size corrupted file.

## The samplesheet

Copy `assets/samplesheet_template.csv`, edit it, point `input:` in `params/pilot.yaml` at it.
Absolute paths, on the box that runs:

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
P11,NA,1,S12944Nr11,L001,/abs/S000021_S12944Nr11.1.fastq.gz,/abs/S000021_S12944Nr11.2.fastq.gz
P11,NA,0,S12944Nr12,L001,/abs/S000021_S12944Nr12.1.fastq.gz,/abs/S000021_S12944Nr12.2.fastq.gz
```

`status`: **1 = tumour, 0 = normal**. `patient` is the individual (`P11`), never the order id
`S000021` — that collapses the cohort into one person. To avoid typing long paths:

```bash
for f in /abs/path/*.1.fastq.gz; do
    s=$(basename "$f" .1.fastq.gz); s=${s#S000021_}
    printf 'PATIENT,NA,STATUS,%s,L001,%s,%s\n' "$s" "$f" "${f%.1.fastq.gz}.2.fastq.gz"
done
```

**Three things nothing checks** — sarek accepts all of them and completes:

- A patient with **no `status=0` row** routes silently to tumour-only Mutect2 and produces a
  VCF with no `_vs_` in its name (`mutect2` is absent from sarek's `tools_requiring_normal_samples`).
- **A swapped `status`** calls the germline as somatic. The file, the columns and the headers
  all look correct.
- A **missing `fastq_2`** runs that sample single-end.

## Optional sanity checks

Not required, no code — run them by hand if you want them.

```bash
# the intervals BED is canonical iff it is a fixed point of bedtools' own pipeline
bedtools sort -faidx $FAI -i references/target_pad30.bed | bedtools merge -i - \
  | bedtools slop -i - -g $FAI -b 0 | cmp - references/target_pad30.bed && echo BED OK

# free space where docker actually puts image layers (NOT its data-root) — exhausting
# this killed two runs, after 2h46m59s and 44m17s
df -h /var/lib/containerd

# the produced VCF: two genotype columns, populated FILTER, some PASS records
bcftools query -l results/variant_calling/mutect2/*/*.mutect2.filtered.vcf.gz
bcftools query -f '%FILTER\n' results/variant_calling/mutect2/*/*.mutect2.filtered.vcf.gz \
  | sort | uniq -c | sort -rn | head
```

The sample columns are `<patient>_<sample>` — sarek writes the read group as
`SM:${meta.patient}_${meta.sample}` — while the *filename* uses the bare sample ids.

## Output

```
results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz
```

~45 min for one pair on 28 cores with the aligner index in place. The contract this file is
expected to satisfy is in [output.md](output.md).
