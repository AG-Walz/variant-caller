# variant-caller

Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0.

Three scripts and a params file. `params/pilot.yaml` holds every sarek setting with the reason
for each; `scripts/` holds the three commands you actually type.

```
scripts/setup.sh      once per box   toolchain check + the GRCh38 bundle + the BWA index
scripts/build_bed.sh  once per kit   N capture-kit BEDs -> one canonical padded target BED
scripts/run.sh        every run      the pinned `nextflow run ../sarek`
```

## Requirements

`bedtools`, `curl`, `aria2c`, Docker, Java 17+, and **Nextflow 25.10.x — not 26.x**, which
aborts on a valid paired samplesheet.

```bash
mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools aria2
export PATH=~/envs/vc/bin:$PATH
```

## The whole thing, in order

```bash
./scripts/setup.sh                                  # ~30 min: clones ../sarek, downloads ~6.5 GB
./scripts/build_bed.sh                              # ~1 min: the two Twist kit BEDs, PAD=30
cp assets/samplesheet_template.csv assets/samplesheet_pilot.csv && $EDITOR $_
./scripts/run.sh -preview                           # ~40 s: validates every path, runs nothing
./scripts/run.sh                                    # the run itself
```

→ `results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz`

Roughly 17 h for one tumour/normal pair from FASTQ on 28 cores, of which ~45 min is Mutect2;
the rest is trimming, alignment and duplicate marking. `scripts/run.sh` always passes
`-resume`, so an interrupted run continues where it stopped.

### On peptimine_highmem1, exactly

```bash
export PATH=/mnt/volume/bin/miniconda/bin:$PATH     # nextflow 25.10.4 + openjdk 21 live here
cd /mnt/volume/nacho/variant-caller
git pull                                            # brings in scripts/ and params/
./scripts/build_bed.sh                              # references/ is already populated there
./scripts/run.sh -preview && ./scripts/run.sh
```

`setup.sh` is not needed on that box: the reference bundle, `../sarek` at tag 3.9.0 and
`assets/samplesheet_pilot.csv` are already in place. Only the BWA index is missing, and
`setup.sh` is the way to get it — until then comment out `bwa:` in `params/pilot.yaml` and
sarek rebuilds it in 1h15m.

## The samplesheet

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

## A different capture kit or padding

`build_bed.sh` takes any number of BED files or URLs and defaults to the two Twist files this
kit was ordered from. `PAD` defaults to 30 bp, the sequencing vendor's own DRAGEN setting —
their coverage metrics match our padded territory to 0.07 %, so changing it ends comparability
with their calls.

```bash
PAD=50 ./scripts/build_bed.sh kit_targets.bed https://vendor/panel.bed
```

The output filename carries the padding (`references/target_pad50.bed`); point `intervals:` in
`params/pilot.yaml` at it. At `PAD=30` with the defaults: 214,494 regions / 49,633,134 bp, md5
`69ed88c5131c8613efe5e20e66954e74`.

## Watch out

- **A swapped `status` is undetectable** — by sarek, by the output, by anything. Read the
  samplesheet before launching.
- **A patient with no `status=0` row** runs tumour-only, completes, and writes a file *without*
  `_vs_` in its name. Its variants are largely germline.
- **Without `af-only-gnomad.hg38.vcf.gz`** sarek publishes the *unfiltered* VCF and does not
  complain; it does not check that this path exists.
- **Docker image layers land in `/var/lib/containerd`**, not in docker's `data-root`. Two runs
  died there on `no space left on device`. Check that filesystem, not the one the repo sits on.
- **Changing a process's `cpus` in `nextflow.config` can cost you the cache.** fastp is threaded
  by `--thread $task.cpus`, and the rendered command line is part of the task hash, so editing
  its `cpus` makes `-resume` re-run it and everything downstream. Memory-only edits are free.

Optional sanity checks:

```bash
FAI=references/Homo_sapiens_assembly38.fasta.fai
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
