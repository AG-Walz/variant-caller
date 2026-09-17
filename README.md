# variant-caller

Tumour/normal FASTQ in, one paired somatic VCF per patient plus one germline VCF per normal, by
running [nf-core/sarek](https://github.com/nf-core/sarek) 3.9.0 with Mutect2, Strelka and
HaplotypeCaller. Optionally, each tumour called alone against the reference as well.
There is no pipeline code here — sarek does the work.

## Requirements

Docker, Java 17+, `curl`, `bedtools`, `bcftools`, and **Nextflow 25.10.x — not 26.x**, which aborts
on a valid paired samplesheet. `get.nextflow.io` installs 26.x by default, so pin it:

```bash
mamba create -y -p ~/envs/vc -c conda-forge -c bioconda nextflow=25.10.4 openjdk=17 bedtools bcftools
export PATH=~/envs/vc/bin:$PATH
```

sarek downloads the reference genome itself on the first run. You need **~60 GB free on
`/var/lib/containerd`** — docker puts image layers there regardless of its `data-root` — and a few
hundred GB where you launch.

Then lower `executor { cpus; memory }` in `nextflow.config` to match your machine. It ships sized
for a 28-core, 500 GB box, and a smaller one will over-commit and die.

## Run it

Launch from the repo root — the paths in both scripts are relative to where you start.

**1. Build the target BED**, once per capture kit. Download the reference index and every BED file
your kit ships (many ship two, exome plus mito). Then open `scripts/build_bed.sh`, list them all in
`BEDS`, set `FAI`, `PADDING` and `OUTPUT`, and run it.

```bash
mkdir -p references
curl -fL -o references/Homo_sapiens_assembly38.fasta.fai \
  https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Homo_sapiens_assembly38.fasta.fai
curl -fL -o references/kit1.bed '<your capture kit target BED>'
./scripts/build_bed.sh
```

It prints a region count and a total in bases. That is the only signal it worked, because it does
not stop on errors — a whole-exome kit at 30 bp lands near 200,000 regions and 45–55 Mb, so a few
hundred regions means only part of your input was read.

**2. Write the samplesheet.** Copy the template and edit it: one row per FASTQ pair per lane,
absolute paths. **Nothing checks that you got the tumour/normal roles right** —
see [docs/reference.md](docs/reference.md#the-samplesheet).

```bash
cp assets/samplesheet_template.csv assets/samplesheet.csv
```

**3. Run.** Open `scripts/run.sh` and point `SAMPLESHEET`, `INTERVALS`, `OUTDIR` and `WORKDIR` at
your files. `INTERVALS` is the `OUTPUT` that step 1 wrote. `TOOLS` lists the callers, and the three
`*_VS_*` switches pick what gets called: tumour against normal, each tumour against the reference,
each normal against the reference. The first and last are on by default.

```bash
./scripts/run.sh -preview   # checks that every path exists; run this first
./scripts/run.sh
```

`-preview` does not check the samplesheet's roles or the BED's contig order. Nothing does.

Expect roughly 17 hours per tumour/normal pair on a 28-core machine. The `_VS_REF` switches add a
second sarek run that starts from the aligned reads, so they add calling time only. `-resume` is
always on, so an interrupted run picks up where it stopped — provided you relaunch from the same
directory. The second run needs that too.

Your somatic VCF: `results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz`.
Your germline VCF: `results/vs_reference/variant_calling/haplotypecaller/<N>/<N>.haplotypecaller.filtered.vcf.gz`.
Whether the numbers in them look right: [docs/reference.md](docs/reference.md#checking-a-run).

Everything else: **[docs/reference.md](docs/reference.md)**.

No annotation. Which caller can call what against the reference is in the docs.
