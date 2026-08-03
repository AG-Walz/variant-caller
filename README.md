# variant-caller

Tumour/normal FASTQ → one paired somatic VCF per patient, by running stock
[nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0.

Two scripts.

```
scripts/build_bed.py  once per kit   N capture-kit BEDs -> one canonical padded target BED
scripts/run.sh        every run      the nextflow command — a template, edit and go
```

`run.sh` is a literal template in the style of
[fastq-to-fasta](https://github.com/AG-Walz/fastq-to-fasta)'s example scripts: edit the six
variables at the top and run it. Everything sarek needs beyond the target BED comes from
`--genome GATK.GRCh38`. `build_bed.py` takes `--arguments`; run it with `--help`.

**Purpose:** an independent call set, to check whether the sequencing vendor's own run was
done correctly. Not a reproduction of their calls — the reference they delivered was the
wrong genome build, which is what prompted this.

## Requirements

Docker, Java 17+, `bedtools`, and **Nextflow 25.10.x — not 26.x**, which aborts on a valid
paired samplesheet.

```bash
mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools
export PATH=~/envs/vc/bin:$PATH
```

No reference download step. `--genome GATK.GRCh38` in `scripts/run.sh` makes sarek fetch the
GRCh38 bundle — FASTA, `.fai`, `.dict`, the gnomAD germline resource, the BWA index, dbSNP and
known indels — from `s3://ngi-igenomes/igenomes/` on first run, staged into the work directory.
Nothing to install, at the cost of ~10 GB re-staged whenever you start a fresh work dir.

The one thing sarek will not make for you is the target BED:

```bash
T=https://www.twistbioscience.com/content/dam/twistbioscience/resources
./scripts/build_bed.py \
    --reference-fai <your reference>.fai \
    --padding 30 \
    --output references/target_pad30.bed \
    $T/2019-09/Twist_Exome_RefSeq_targets_hg38.bed \
    $T/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed
```

It needs the `.fai` of the genome you will call against, to put the regions in contig order.
Under `--genome GATK.GRCh38` that file is staged by nextflow rather than sitting on disk; the
Broad publish the identical one at
`https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Homo_sapiens_assembly38.fasta.fai`
(160 KB, `curl -O`).

## The whole thing, in order

Run these from the repo root — the paths in `scripts/run.sh` are relative to wherever you
launch, and nothing here quietly changes directory on you.

```bash
# the target BED (above), then your samples
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

`references/target_pad30.bed` and `assets/samplesheet_pilot.csv` for pair P11 are already
there. `nextflow` is **not** on the default PATH on that box, which is what the first line is
for. The first run under `--genome GATK.GRCh38` will stage ~10 GB from S3.

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

Put the padding in the output name and point `--intervals` in `scripts/run.sh` at it — that way a
BED built at one padding cannot be picked up by a run expecting another. This cohort's two Twist
files at 30 bp give 214,494 regions / 49,633,134 bp, md5 `69ed88c5131c8613efe5e20e66954e74`.

### What padding is, and how to pick one

A capture kit's BED lists where the probes bind. Probes do not stop capturing at the target
boundary: a 100 bp read that starts inside the target extends past it, so real coverage runs
some distance either side. Padding widens each region to include that skirt. Too little and you
lose splice-site and near-boundary variants that were sequenced perfectly well; too much and you
call over positions with a handful of reads, adding false positives and runtime.

- **sarek's default: none.** sarek has no padding parameter and passes no `--interval-padding`
  to GATK — grep the pinned clone and `nextflow_schema.json` for it and you get nothing. It
  calls exactly the BED you hand it, so the effective default is 0.
- **fastq-to-fasta used none either** — its human `run_sarek.sh` passes no `--intervals` at all,
  so it calls over the igenomes WGS calling regions, and the mouse scripts pass `--no_intervals`.
  The question never came up there.
- **Why 30 here:** it was the sequencing vendor's own DRAGEN setting, chosen so our padded
  territory matched the 49,599,660 bp they reported, to 0.07 %. That was a *comparability*
  argument — and it no longer applies, because the goal is now an independent call set rather
  than a reproduction of theirs. 30 bp is a defensible number, but it is inherited, not derived.

**To derive one from this dataset**, use the coverage the run now produces (`skip_tools` is no
longer set, so mosdepth runs). Measure how coverage falls off with distance from the target edge
and pad to where it stops being callable:

```bash
# per-base depth in a 200 bp skirt around the unpadded target, bucketed by distance from the edge
bedtools slop -i target_pad0.bed -g $FAI -b 200 \
  | bedtools subtract -a - -b target_pad0.bed \
  | bedtools coverage -a - -b results/preprocessing/recalibrated/*/*.cram -d \
  | awk '{print $(NF-1)"\t"$NF}' | sort -n | datamash -g1 median 2
```

Then pad to the last distance whose median depth still clears your calling threshold — for
somatic work, typically 20–30×. Expect an answer in the 10–50 bp range for a 2×100 bp library;
if it comes out far from 30, that is itself a finding about the vendor's run.

## Watch out

- **A swapped `status` is undetectable** — by sarek, by the output, by anything. Read the
  samplesheet before launching.
- **A patient with no `status=0` row** runs tumour-only, completes, and writes a file *without*
  `_vs_` in its name. Its variants are largely germline.
- **`--genome GATK.GRCh38` supplies a panel of normals** (`1000g_pon.hg38.vcf.gz`, wired in at
  `conf/igenomes.config:76`), and Mutect2 applies it automatically. It changes which calls
  PASS, and it is announced only as a `log.warn`. It also enables BQSR, since dbSNP and known
  indels come with it. Both are wanted here; neither is silent-by-accident, so know they are on.
- **The BED must match the genome `--genome` resolves to.** Build it against that reference's
  `.fai`, in its contig order. A name-ordered BED runs happily for ~30 minutes and then dies
  inside `CalculateContamination`.
- **Docker image layers land in `/var/lib/containerd`**, not in docker's `data-root`. Two runs
  died there on `no space left on device`. Check that filesystem, not the one the repo sits on.
- **Changing a process's `cpus` in `nextflow.config` can cost you the cache.** fastp is threaded
  by `--thread $task.cpus`, and the rendered command line is part of the task hash, so editing
  its `cpus` makes `-resume` re-run it and everything downstream. Memory-only edits are free.

Optional sanity checks:

```bash
FAI=references/Homo_sapiens_assembly38.fasta.fai
BED=references/target_pad30.bed                                 # canonical iff unchanged by:
bedtools sort -faidx $FAI -i $BED | bedtools merge -i - | bedtools slop -i - -g $FAI -b 0 | cmp - $BED
df -h /var/lib/containerd                                       # room for image layers
bcftools query -l  results/variant_calling/mutect2/*/*.vcf.gz   # 2 columns, <patient>_<sample>
bcftools query -f '%FILTER\n' results/variant_calling/mutect2/*/*.vcf.gz | sort | uniq -c | sort -rn
```

## Scope

v1 is paired somatic calling only: no tumour-only mode, no annotation, no BQSR, no QC bundle,
one caller. Annotation happens downstream in
[nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction).
