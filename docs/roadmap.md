# Roadmap — v1, v2, v3

Where this repo is going. **v1 is what exists**; v2 and v3 are recorded scope, not commitments
of date. The authoritative decision record for v1 is
[`decisions-v5-fastq-first.md`](../../docs/decisions-v5-fastq-first.md) in the sibling `docs/`
workspace folder.

---

## v1 — shipped (unverified until the pilot runs)

FASTQ + declared sample labels → **one paired somatic Mutect2 VCF per patient**, by wrapping a
sibling nf-core/sarek 3.9.0 clone with one pinned minimal invocation. Nothing else. See
[`README.md`](../README.md) for the full "does NOT do" list.

## v2 — accepted, not started

Deferred deliberately while v1 proves the mechanics:

- **Interactive samplesheet builder** (D′): a table listing discovered FASTQ pairs where the user
  picks each label from the four-value enum. v1 ships the batch declarations-TSV form instead.
- Kit registry / bait BED / hybrid-capture QC; tumour-only mode; preference-ordered normal
  selection; own nf-core module assembly behind the same output contract.

---

## v3 — replace CeGaT's exome bioinformatics, Levels 2–5

**Goal (set by the supervisor, 2026-07-24).** Consume **Level 1** output only — FASTQ and CSV —
and replace CeGaT's bioinformatic analysis **up to Level 5** with our own metapipeline. Level
definitions are CeGaT's, from their
[exome sequencing service page](https://cegat.com/research-pharma-solutions/sequencing-services/exome-sequencing/).

### The levels, and what they mean for us

| Level | CeGaT delivers | Ours in v3? |
|---|---|---|
| **1** | demultiplexing + adapter trimming (FASTQ), metrics (CSV), MultiQC (HTML) | **Input, not output.** Demultiplexing stays with the vendor. |
| **2** | mapping (BAM), metrics (CSV) | ✅ produce |
| **3** | SNV + indel calling (VCF), **ROH calling (BED + CSV)**, metrics (CSV) | ✅ produce |
| **4** | annotation of SNVs and indels (JSON + TSV), human only | ✅ produce |
| **5** | CNV calling (VCF + GFF3) + metrics (CSV), human only — **or** variant comparison across samples, e.g. trio filtering (VCF + TSV) | ✅ produce **both**, not one |

CeGaT offers Level 5 as *one of* the two. The supervisor wants both.

### What the wrapped sarek already covers

- **Level 2** — bwa-mem2 mapping. sarek emits CRAM by default; `--save_mapped` plus
  `--save_output_as_bam` gives BAM. Metrics come from samtools stats, mosdepth and MultiQC,
  **all three of which v1 currently switches off** via `--skip_tools`. Re-enabling them is
  configuration, not new code.
- **Level 3 (SNV/indel)** — `haplotypecaller` for germline, `mutect2` / `strelka` / `freebayes`
  for somatic. Already available through `--tools`.
- **Level 4** — `vep` (with `--vep_out_format json|tab|vcf`), plus `snpeff`, `snpsift`, `bcfann`.
  Both required output formats are reachable.
- **Level 5 (CNV)** — `ascat`, `cnvkit`, `controlfreec` are all present as modules.

### The real gaps — things sarek cannot do today

1. **ROH calling is absent from sarek entirely.** Verified against the 3.9.0 clone:
   `modules/nf-core/bcftools/` contains `annotate concat isec merge mpileup norm sort stats view`
   and **no `roh`**, and the `--tools` enum has no ROH entry. The fix is a `bcftools roh` step in
   our wrapper (the module exists upstream in nf-core/modules), run on the **germline** VCF, with
   BED and CSV emitters. This is the one Level 1–5 capability that is genuinely missing rather
   than merely unconfigured.
2. **CNV output formats.** None of ASCAT / CNVkit / Control-FREEC emits **GFF3**, and their native
   outputs (`.cns`/`.cnr`, ASCAT tables) are not VCF. Both conversions are ours to write.
3. **Variant comparison / trio filtering.** Not in sarek. `bcftools isec` and `bcftools merge`
   exist as modules, but the comparison and filtering logic is ours.
4. **Metrics CSV schema.** sarek's samtools/mosdepth/MultiQC outputs are not CeGaT's CSV schema.
   Matching *content* is a design decision; matching the *format* is a mapping layer.
5. **Annotation JSON schema.** CeGaT's JSON comes from Illumina Nirvana; VEP's `--json` has a
   different schema. Same file extension, different contract.

### Consequences for decisions already taken

These are flagged, **not** resolved — v3 reopens them and they need explicit re-decision:

- **Germline calling enters scope.** Decision 7 chose Mutect2 partly *because* `--tools mutect2`
  does no germline calling. Level 3 SNV/indel plus ROH are germline products, so v3 needs
  `haplotypecaller` alongside the somatic caller. The v1 rationale is not wrong, it is narrower
  than v3's target.
- **Annotation moves in-pipeline.** Decisions 4 and 8 put annotation downstream in
  epitopeprediction PR #362. If Level 4 is ours, that boundary has to be re-drawn so annotation
  is not done twice, differently.
- **QC stops being skippable.** v1 skips `fastqc,mosdepth,samtools,multiqc,bcftools,vcftools`
  because "v1 produces one VCF, not a report bundle". Levels 2 and 3 require the metrics, so
  that flag shrinks considerably.
- **The output contract grows.** `assert_output.py` guards exactly one file. v3 delivers BAM,
  VCFs, BED, CSV, JSON, TSV and GFF3 across four levels — each needs its own assertion, or the
  contract idea needs generalising.

### Open questions

- **Which CeGaT product are we replacing?** The Level 1–5 list describes their **exome** service,
  and "variant comparison, e.g. trio filtering" is family/germline-shaped. The UrCa data we hold
  is tumour/normal **somatic** (their *CTP somatic* product, per the project report). Germline
  exome, somatic, or both?
- **Is our Level 1 input actually trimmed?** The UrCa project report states *"trimming of the
  reads has not been performed"*, so this delivery arrived **untrimmed** despite Level 1 nominally
  including adapter trimming. v3 must either trim itself (as v1 now does via `--trim_fastq`) or
  verify per-delivery.
- **How close is "replace"?** Byte-comparable outputs, concordant variant calls, or the same
  analytical scope in our own formats? This determines whether gaps 4 and 5 are real work or not.
