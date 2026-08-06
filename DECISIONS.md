# Decisions

Why this pipeline is shaped the way it is. Each entry is a choice that was made deliberately, with
the reason it was made. Rationale in depth, measurements and open questions are kept outside this
repository.

## Architecture

**Call from raw reads, not from the vendor's VCF** (2026-07-23, reversing 2026-07-22). The original
design ingested CeGaT's delivered call set. It was replaced by calling from FASTQ so the pipeline
owns its own evidence and can be re-run, re-tuned and audited.

**Run stock nf-core/sarek 3.9.0 from the hub; do not fork or reimplement it.**
`nextflow run nf-core/sarek -r 3.9.0` resolves and caches it; there is no local clone to keep in
sync. We supply parameters, not code.

**Two files: one Python utility and a launch template** (2026-08-03). The repository had grown to
2,606 lines of scripts, validators and tests; on 2026-07-30 all of it was deleted. `scripts/` came
back the same day, then shrank twice more as sarek turned out to already do the work.

Both files are literal editable templates, because AG-Walz's own fastq-to-fasta launches sarek
exactly that way and because it is the shortest form that still names every value. `build_bed.sh`
was briefly Python with `argparse`, following nf-core's `bin/` convention; it went back to shell
when the whole job turned out to be `cat | bedtools sort | merge | slop | merge` — 20 lines against
114, byte-identical output.

There are only two because building the target BED is the only thing sarek will not do: it builds
`.fai`, `.dict`, the germline `.tbi` and the BWA index itself, and `--genome` fetches the rest, but
nothing in it turns capture-kit BEDs into a contig-ordered, 3-column target. `build_bed.sh` makes
that contract true by construction rather than asserting it. The validators and tests did not come
back.

**The published tool for joining BED files is `cat`** (measured 2026-08-03). BEDOPS
`bedops --everything` is documented as exactly that operator, but no BEDOPS tool can read a
`.fai`-ordered BED — they abort at the chr9/chr10 boundary — and `sort-bed` reorders
lexicographically, which is the failure that kills a run. `bedtk merge a.bed b.bed` silently
ignores every file after the first. bioframe reproduces the target exactly but hides the
load-bearing `-faidx` behind an implicit pandas property.

**Five guarantees were given up with that code**, each of which fails silently or expensively — the
samplesheet cardinality rules, the intervals contract, the germline-resource check, the container
disk check, and the VCF output contract. The README lists each as an optional one-line check.

## Calling

**Mutect2, paired tumour-vs-normal, one VCF per patient.** Chosen over Strelka2 for a genuine
`##tumor_sample` header, `AF` in FORMAT, and one file per pair. Pairing comes from the samplesheet
`status` column, never from filenames.

**Paired only. No tumour-only mode.** A patient without a normal is not a fallback case — sarek will
run it silently and produce a call set that is largely germline.

**GRCh38 via `--genome GATK.GRCh38`** (2026-08-03, reversing the local-references decision). Every
reference — FASTA, `.fai`, `.dict`, the gnomAD germline resource, the BWA index, dbSNP and known
indels — comes from `s3://ngi-igenomes/igenomes/`, staged per work directory. This deletes the
whole reference-acquisition step.

It was previously refused, because igenomes also injects a 1000g panel-of-normals
(`conf/igenomes.config:76`), a `.64.alt` file, and WGS intervals, each announced only as a
`log.warn`. That objection was about *comparability with the vendor's calls*, and the goal changed:
we now want an independent call set to check whether their run was done correctly, not a
reproduction of it. A PoN and BQSR make the call set better evidence, not worse. `--intervals`
still overrides the WGS intervals.

**BQSR on** (2026-08-03, reversing "BQSR off"). It was off because no dbSNP or known-indels
resource was materialised locally; igenomes supplies both, so the reason is gone.

**No annotation, no VEP, no normalisation.** The VCF is emitted as FilterMutectCalls leaves it;
annotation happens downstream in nf-core/epitopeprediction.

## The target

**The BED is built from the capture kit vendor's own files**, not from the delivered target file
(which was the wrong genome build) and not from the vendor's per-region counts (kept only as a
cross-check). At the default padding it is 214,494 regions / 49,633,134 bp, md5
`69ed88c5131c8613efe5e20e66954e74`.

**Padding is a required argument, `build_bed.py --padding`, and this cohort uses 30 bp** — the
sequencing vendor's own DRAGEN setting, chosen so our padded territory matched the 49,599,660 bp
they reported, to 0.07 %. **That was a comparability argument and it no longer holds** (2026-08-03):
the goal is an independent call set, so 30 bp is inherited rather than derived. sarek itself has no
padding parameter and passes no `--interval-padding`, so its effective default is 0, and
fastq-to-fasta never used a padded target at all. Deriving a value from this dataset's own
coverage fall-off is an open question — see the README. The output filename carries the value, so
the BED and `--intervals` cannot drift apart silently.

**Rows must be in the reference's contig order, and the file must be exactly three columns.** Both
are correctness requirements, not style: name-ordered rows kill the run 30 minutes in, and a fourth
and fifth column are read by sarek as a per-region runtime estimate.

**chrM is in the target** (2026-07-31, reversing an early exclusion). The mitochondrial panel was
part of the kit the sequencing vendor ordered, and their own calls include chrM records. Caveat:
mitochondrial variants are heteroplasmic and GATK's `--mitochondria-mode` is *not* used, so these
calls are indicative rather than validated.

## Inputs

**Sample roles are declared, never inferred.** The vendor's own delivered VCFs order their genotype
columns normal-then-tumour inside a file named tumour-then-normal, so filename conventions cannot be
trusted. A swapped `status` is undetectable by sarek, by the output, or by anything downstream.

**`patient` is the individual, never the sequencing order id** — using the order id collapses the
cohort into one person and pairs tumours against other patients' normals.

**Clinical labels are the GUI's input contract** (2026-07-31). A future GUI takes
`tumour` / `tumour_adjacent` / `control_healthy` / `control_benign` from a dropdown and derives
sarek's binary `status` itself. That makes the swap above impossible rather than undetectable. CLI
users type `status` directly; a CLI operator is assumed to be trusted.

## Operations

**Nextflow is pinned to 25.10.x.** sarek 3.9.0 requires `>=25.10.2`, but the current installer ships
26.04.6, under which the pinned invocation aborts on a valid paired samplesheet.

**Every parameter is inline in `scripts/run.sh`; there is no params file** (2026-08-03, reversing
the `-params-file` decision taken the same day). Once `--genome GATK.GRCh38` supplied the six
reference paths and the QC suppression was dropped, only five tuned settings were left, and five
flags do not need a file. The rationale that the YAML's comments used to carry now lives in
DECISIONS.md and the README, which is where a reader looks anyway.

**bwa-mem1, from igenomes** (2026-08-03). `--genome GATK.GRCh38` points `bwa` at a prebuilt index
directory, so the 1h14m50s `BWAMEM1_INDEX` build does not happen. Note that index includes a
`.64.alt` file, which makes BWA-MEM alt-aware — a different alignment from the pilot's.

**The run sets `NXF_OPTS=-Djava.net.preferIPv6Addresses=true`** (2026-08-03). sarek's own config
includes the nf-core institutional config over https; the JVM prefers IPv4, and on an IPv6-only
host that include fails and takes the run with it before any parameter is read. `NXF_OFFLINE=true`
skips the include but then fails schema validation, so it is not an alternative.

## Open

**No panel of normals.** The pilot's calls were produced without one, and adding one changes which
calls pass. Deliberately left open for the remaining patients rather than inherited from a plan
written before the pilot ran. If adopted, pass `--pon` explicitly.

**No QC and no BQSR in the pilot**, and concordance against the vendor's call set has never been
measured. All reversible, all decisions for the remaining patients rather than for the pilot.
