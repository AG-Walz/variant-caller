# variant-caller

Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0.

Three scripts and a params file. `params/pilot.yaml` holds every sarek setting with the reason
for each; `scripts/` holds the three commands you actually type.

```
scripts/setup.py      once per box   toolchain check, the sarek clone, the reference files
scripts/build_bed.py  once per kit   N capture-kit BEDs -> one canonical padded target BED
scripts/run.sh        every run      the pinned `nextflow run` — a template, edit and go
```

The two utilities take `--arguments`; run either with `--help` to see what it wants. The
launcher is a template in the style of
[fastq-to-fasta](https://github.com/AG-Walz/fastq-to-fasta)'s example scripts: copy it, edit
the paths, run it. The only value hardcoded in the utilities is sarek's tag, `3.9.0`, because
that is what the pipeline is validated against. Which reference files to fetch is data too, in
`assets/references.txt`: edit it, or pass your own list, to use a different build or an
internal mirror.

## Requirements

`bedtools`, `curl`, `aria2c`, Docker, Java 17+, and **Nextflow 25.10.x — not 26.x**, which
aborts on a valid paired samplesheet.

```bash
mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools aria2
export PATH=~/envs/vc/bin:$PATH
```

## The whole thing, in order

Run these from the repo root — `params/pilot.yaml` names its paths relative to wherever you
launch, and nothing here quietly changes directory on you.

```bash
# ~30 min: clone sarek 3.9.0 and download the 11.8 GB of GRCh38 reference data listed in the file
./scripts/setup.py --file-list assets/references.txt --references-dir references --sarek-dir ../sarek

# ~1 min: this cohort's two Twist kit files, padded 30 bp, into the name params/pilot.yaml expects
T=https://www.twistbioscience.com/content/dam/twistbioscience/resources
./scripts/build_bed.py \
    --reference-fai references/Homo_sapiens_assembly38.fasta.fai \
    --padding 30 \
    --output references/target_pad30.bed \
    $T/2019-09/Twist_Exome_RefSeq_targets_hg38.bed \
    $T/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed

# your samples
cp assets/samplesheet_template.csv assets/samplesheet_pilot.csv && $EDITOR $_

# ~40 s: validate every parameter and path, launching nothing
./scripts/run.sh -preview

# the run itself
./scripts/run.sh
```

Already have the kit BEDs on disk? Pass paths instead of URLs — `build_bed.py` takes either,
in any mix, in any number.

→ `results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz`

Roughly 17 h for one tumour/normal pair from FASTQ on 28 cores, of which ~45 min is Mutect2;
the rest is trimming, alignment and duplicate marking. `scripts/run.sh` always passes
`-resume`, so an interrupted run continues where it stopped.

### On peptimine_highmem1, exactly

```bash
export PATH=/mnt/volume/bin/miniconda/bin:$PATH     # nextflow 25.10.4 + openjdk 21 live here
cd /mnt/volume/nacho/variant-caller
./scripts/run.sh -preview && ./scripts/run.sh
```

That is the whole thing on that box: `setup.sh` and `build_bed.sh` have both already been
satisfied there — the reference bundle, the BWA index, `references/target_pad30.bed`,
`../sarek` at tag 3.9.0 and `assets/samplesheet_pilot.csv` for pair P11 are all in place.
`nextflow` is **not** on the default PATH there, which is what the first line is for.

Two things about that box specifically. `/` is 96 GB at 83 % and `/var/lib/containerd` holds
60 GB of it, so check `df -h /var/lib/containerd` before a long run. And it routes IPv6 only —
which is why `run.sh` sets `NXF_OPTS`; without it sarek cannot fetch the nf-core config it
includes over https and the run dies before reading a single parameter.

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

```bash
./scripts/build_bed.py \
    --reference-fai references/Homo_sapiens_assembly38.fasta.fai \
    --padding 50 \
    --output references/target_pad50.bed \
    kit_targets.bed https://vendor/panel.bed
```

Put the padding in the output name and point `intervals:` in `params/pilot.yaml` at it — that
way a BED built at one padding cannot be picked up by a params file expecting another.

30 bp is this cohort's padding because it is the sequencing vendor's own DRAGEN setting, and
their coverage metrics then match our padded territory to 0.07 % — changing it ends
comparability with their calls. This cohort's two Twist files at 30 bp give 214,494 regions /
49,633,134 bp, md5 `69ed88c5131c8613efe5e20e66954e74`; the script prints all three so you can
compare against your last good build.

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
