# Decisions

Why this pipeline is shaped the way it is. Each entry is a choice that was made deliberately, with
the reason it was made. Rationale in depth, measurements and open questions are kept outside this
repository.

## Architecture

**Call from raw reads, not from the vendor's VCF** (2026-07-23, reversing 2026-07-22). The original
design ingested CeGaT's delivered call set. It was replaced by calling from FASTQ so the pipeline
owns its own evidence and can be re-run, re-tuned and audited.

**Wrap stock nf-core/sarek 3.9.0; do not fork or reimplement it.** The clone lives beside this repo
at `../sarek`, unmodified, pinned to tag 3.9.0. We supply parameters, not code.

**There is no code in this repository** (2026-07-30). It had grown to 2,606 lines of scripts,
validators and tests; all of it was deleted. The target BED is one `bedtools` pipeline and the run is
one `nextflow` command. The rule that survived: delete anything sarek, bedtools or nf-schema already
does, and only write something where a published tool measurably cannot do the job.

**Five guarantees were given up with that code**, each of which fails silently or expensively — the
samplesheet cardinality rules, the intervals contract, the germline-resource check, the container
disk check, and the VCF output contract. The README lists each as an optional one-line check.

## Calling

**Mutect2, paired tumour-vs-normal, one VCF per patient.** Chosen over Strelka2 for a genuine
`##tumor_sample` header, `AF` in FORMAT, and one file per pair. Pairing comes from the samplesheet
`status` column, never from filenames.

**Paired only. No tumour-only mode.** A patient without a normal is not a fallback case — sarek will
run it silently and produce a call set that is largely germline.

**GRCh38 (GATK bundle), materialised locally, with `--igenomes_ignore true`.** Every reference path
is explicit. The schema default `--genome GATK.GRCh38` is refused because it silently injects a
1000g panel-of-normals, a `.64.alt` file and WGS intervals, each announced only as a `log.warn`.

**BQSR off**, which is also why no dbSNP or known-indels resource is needed.

**No annotation, no VEP, no normalisation.** The VCF is emitted as FilterMutectCalls leaves it;
annotation happens downstream in nf-core/epitopeprediction.

## The target

**The BED is built from the capture kit vendor's own files**, not from the delivered target file
(which was the wrong genome build) and not from the vendor's per-region counts (kept only as a
cross-check). At the default padding it is 214,494 regions / 49,633,134 bp, md5
`69ed88c5131c8613efe5e20e66954e74`.

**Padding is a parameter, `PAD`, defaulting to 30 bp** — the sequencing vendor's own DRAGEN setting.
Their coverage metrics match our padded territory to 0.07 %, so changing it ends comparability with
their calls. The output filename carries the value, so the BED and `params/pilot.yaml` cannot drift
apart silently.

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

**Every parameter lives in `params/pilot.yaml`, not on the command line.** A truncated paste of the
old flag list once produced an orphaned run; a file cannot be half-pasted.

**bwa-mem1 today; bwa-mem2 at the next fresh cohort** (2026-07-31). The published BWA-MEM1 index is
byte-identical to what sarek builds, so it is a download rather than a 1h15m build. bwa-mem2 is
roughly twice as fast but has no public index and would invalidate every cached alignment — a cohort
boundary decision.

## Open

**No panel of normals.** The pilot's calls were produced without one, and adding one changes which
calls pass. Deliberately left open for the remaining patients rather than inherited from a plan
written before the pilot ran. If adopted, pass `--pon` explicitly.

**No QC and no BQSR in the pilot**, and concordance against the vendor's call set has never been
measured. All reversible, all decisions for the remaining patients rather than for the pilot.
