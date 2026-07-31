# variant-caller

Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0.

There is no code here. `params/pilot.yaml` holds every setting, the target BED is one
`bedtools` command, and the run is one `nextflow` command.

## Requirements

`bedtools`, `curl`, Docker, Java 17+, and **Nextflow 25.10.x — not 26.x**, which aborts on a
valid paired samplesheet. Plus a sibling sarek clone:

```bash
git clone --branch 3.9.0 --depth 1 https://github.com/nf-core/sarek.git ../sarek
mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools
export PATH=~/envs/vc/bin:$PATH
```

## 1. References — once per box

```bash
B=https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0
G=https://storage.googleapis.com/gatk-best-practices/somatic-hg38
mkdir -p references/bwa
aria2c -x8 -s8 -c -d references $B/Homo_sapiens_assembly38.fasta{,.fai} $B/Homo_sapiens_assembly38.dict
aria2c -x8 -s8 -c -d references $G/af-only-gnomad.hg38.vcf.gz{,.tbi}
for e in amb ann bwt pac sa; do
  aria2c -x8 -s8 -c -d references/bwa -o Homo_sapiens_assembly38.$e $B/Homo_sapiens_assembly38.fasta.64.$e
done   # the published BWA index; skips a 1h15m build. Then uncomment `bwa:` in params/pilot.yaml
```

## 2. Target BED — once per reference

```bash
PAD="${PAD:-30}"                  # padding in bp; 30 matches the sequencing vendor's own setting
FAI=references/Homo_sapiens_assembly38.fasta.fai
T=https://www.twistbioscience.com/content/dam/twistbioscience/resources
cat <(curl -sL $T/2019-09/Twist_Exome_RefSeq_targets_hg38.bed) \
    <(curl -sL $T/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed) \
  | bedtools sort -faidx $FAI | bedtools merge -i - \
  | bedtools slop -i - -g $FAI -b "$PAD" | bedtools merge -i - > "references/target_pad${PAD}.bed"
```

At `PAD=30`: 214,494 regions / 49,633,134 bp, md5 `69ed88c5131c8613efe5e20e66954e74`.
Change `PAD` and point `intervals:` in `params/pilot.yaml` at the new filename.

## 3. Samplesheet

Copy `assets/samplesheet_template.csv`, edit it, point `input:` in `params/pilot.yaml` at it.
Absolute paths, on the machine that runs. **`status`: 1 = tumour, 0 = normal**, exactly one
normal per patient. `patient` is the individual, never the sequencing order id.

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
P11,NA,1,S12944Nr11,L001,/abs/Nr11.1.fastq.gz,/abs/Nr11.2.fastq.gz
P11,NA,0,S12944Nr12,L001,/abs/Nr12.1.fastq.gz,/abs/Nr12.2.fastq.gz
```

To avoid typing long paths, generate the rows and fill in patient and status:

```bash
for f in /abs/path/*.1.fastq.gz; do
  s=$(basename "$f" .1.fastq.gz)
  printf 'PATIENT,NA,STATUS,%s,L001,%s,%s\n' "$s" "$f" "${f%.1.fastq.gz}.2.fastq.gz"
done
```

## 4. Run

```bash
nextflow run ../sarek -profile docker -c nextflow.config -params-file params/pilot.yaml -w work -resume
```

→ `results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz`, ~45 min for
one pair on 28 cores.

## Watch out

- **Keep `-faidx` and `-g`** in step 2. Without `-faidx` the BED is ordered by contig *name* and
  the run dies 30 minutes in inside `CalculateContamination`. `-g` clamps padding to contig ends.
- **A swapped `status` is undetectable** — by sarek, by the output, by anything. Read the
  samplesheet before launching.
- **A patient with no `status=0` row** runs tumour-only, completes, and writes a file *without*
  `_vs_` in its name. Its variants are largely germline.
- **Without `af-only-gnomad.hg38.vcf.gz`** sarek publishes the *unfiltered* VCF and does not
  complain; it does not check that this path exists.
- **Docker image layers land in `/var/lib/containerd`**, not in docker's `data-root`. Two runs
  died there on `no space left on device`. Check that filesystem, not the one the repo sits on.

Optional sanity checks:

```bash
BED="references/target_pad${PAD:-30}.bed"                       # canonical iff unchanged by:
bedtools sort -faidx $FAI -i $BED | bedtools merge -i - | bedtools slop -i - -g $FAI -b 0 | cmp - $BED
df -h /var/lib/containerd                                       # room for image layers
bcftools query -l  results/variant_calling/mutect2/*/*.vcf.gz   # 2 columns, <patient>_<sample>
bcftools query -f '%FILTER\n' results/variant_calling/mutect2/*/*.vcf.gz | sort | uniq -c | sort -rn
```

## Scope

v1 is paired somatic calling only: no tumour-only mode, no annotation, no BQSR, no QC bundle,
one caller. Annotation happens downstream in
[nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction).
