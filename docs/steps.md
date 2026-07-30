# Steps — the operator runbook

Four commands. Everything else is sarek's or bedtools' job.

```bash
bin/vc.py bed --out references/target_pad30.bed --fai references/Homo_sapiens_assembly38.fasta.fai
cp assets/samplesheet_template.csv assets/samplesheet_pilot.csv   # then edit it
bin/vc.py sheet assets/samplesheet_pilot.csv
bin/vc.py run
```

## 0. Once per box

```bash
git clone --branch 3.9.0 --depth 1 https://github.com/nf-core/sarek.git ../sarek
mamba create -y -p /mnt/volume/bin/envs/vc -c conda-forge -c bioconda \
    nextflow=25.10.4 openjdk=17 bedtools pybedtools pyyaml
export PATH=/mnt/volume/bin/envs/vc/bin:$PATH
```

**Pin the Nextflow version.** sarek 3.9.0 requires `>=25.10.2` (the `!` in its manifest makes
a lower version a hard launch failure), but `curl https://get.nextflow.io | bash` currently
installs **26.04.6**, under which the pinned invocation aborts on a valid paired samplesheet
with *"The sample-sheet only contains normal-samples … expect at least one tumor-sample"*.
Nextflow 25.10 needs **Java 17+**, not 11.

Run long jobs under `tmux`/`screen` and keep the log: `tmux new -d -s vc "bin/vc.py run 2>&1 | tee -a run.log"`.

## 1. References

Five files, plus the aligner index. Download them into `references/` — checksum-verified,
and the published BWA-MEM1 index saves the 1 h 15 min sarek otherwise spends building one
byte-identical to it:

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

Add `--check-integrity=true --checksum=md5=<published>` per file if you want the transfer
verified — `curl -C -` and `wget -c` both silently accept a same-size corrupted file, and a
truncated gnomAD VCF would reach Mutect2, where a missing germline resource makes sarek
publish the **unfiltered** VCF with no error.

To use the downloaded index, uncomment `bwa: references/bwa` in `params/pilot.yaml`. It
changes the alignment tasks' input identity, so do it on a fresh cohort, not mid-run.

## 2. The target BED

```bash
bin/vc.py bed --out references/target_pad30.bed --fai references/Homo_sapiens_assembly38.fasta.fai
```

Downloads the two Twist vendor files (verifying the vendor's published `Content-MD5`), unions,
sorts into **reference contig order**, merges, pads ±30 bp clamped to contig lengths, merges
again, and refuses to write unless the result is a canonical intervals BED.

Expected: **214,494 regions / 49,633,134 bp**, md5 `69ed88c5131c8613efe5e20e66954e74`.

Why 30 bp: it is CeGaT's own DRAGEN setting (`--vc-target-bed-padding 30`), and their coverage
metrics (49,599,660 bp) confirm their calls are reported over the padded territory.

## 3. The samplesheet

Copy the template and edit it — sarek's own 7 columns, absolute paths, **on the box that will
run**:

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
P11,NA,1,S12944Nr11,L001,/abs/S000021_S12944Nr11.1.fastq.gz,/abs/S000021_S12944Nr11.2.fastq.gz
P11,NA,0,S12944Nr12,L001,/abs/S000021_S12944Nr12.1.fastq.gz,/abs/S000021_S12944Nr12.2.fastq.gz
```

`status`: **1 = tumour, 0 = normal**. Exactly one normal per patient, at least one tumour.
`patient` must be the individual (`P11`), **never** the order id `S000021` — that collapses
the cohort into one person.

To avoid typing long paths, generate the rows and then fill in patient and status:

```bash
for f in /abs/path/*.1.fastq.gz; do
    s=$(basename "$f" .1.fastq.gz); s=${s#S000021_}
    printf 'PATIENT,NA,STATUS,%s,L001,%s,%s\n' "$s" "$f" "${f%.1.fastq.gz}.2.fastq.gz"
done
```

Then `bin/vc.py sheet <file>`. **Nothing can detect a swapped `status`** — not this check, not
sarek, not the output assertion — so read the pairing table `run` prints before it launches.

## 4. Run

```bash
bin/vc.py run                      # or: bin/vc.py run --params params/pilot.yaml
```

Pre-flight (five checks sarek does not perform), then `nextflow run ../sarek -params-file
params/pilot.yaml -resume`, then the output-contract assertion on the produced VCF. Every
scientific parameter lives in `params/pilot.yaml`; only Nextflow's own options are in the code.

Deliverable:

```
results/variant_calling/mutect2/<T>_vs_<N>/<T>_vs_<N>.mutect2.filtered.vcf.gz
```

Expect ~45 min for one pair on 28 cores once the aligner index exists (1 h 15 min more if it
does not and you did not download it). The contract is in [output.md](output.md).

## Another patient

Add its two rows to the samplesheet with a new `patient` id and re-run. The target BED and
references are reused. `run` asserts one pair at a time — pass `--tumour/--normal` for the
pair you want checked.
