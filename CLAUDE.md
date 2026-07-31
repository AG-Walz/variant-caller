# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

`variant-caller` v1 turns tumour/normal **FASTQ** + a **samplesheet** into **one paired
somatic VCF per patient**, by shelling out to a single pinned `nextflow run` of a sibling
clone of stock **nf-core/sarek 3.9.0** at `../sarek`. It does not `include` sarek modules,
fork it, or reimplement calling. There is no `main.nf`, no `modules/`, no `workflows/`.

```
README.md                        how to run it — the only user-facing document
params/pilot.yaml                every sarek parameter, with the reason for each
nextflow.config                  resource overrides for the run box (resources only)
assets/samplesheet_template.csv  copy, edit, point params/pilot.yaml at it
```

`docs/` is **untracked on purpose** (2026-07-31): it still exists on disk with the long-form
introduction, output contract, roadmap and runbook, but it is not published. Keep the README
as the single entry point; do not re-add `docs/` to git without being asked.

**THERE IS NO CODE IN THIS REPOSITORY, and that is deliberate** (2026-07-30, on the user's
explicit instruction: "I want minimal code, simply join the bed files in a one liner and
assuming the samplesheet stands run the sarek with the chosen settings"). Do not reintroduce
scripts. The target BED is a bedtools one-liner in `README.md`; the run is
`nextflow run ../sarek -params-file params/pilot.yaml`. Dependencies: bedtools, curl,
Nextflow 25.10.x, Java 17+, Docker.

## What is NOT checked any more, and how each fails

All five were previously enforced and were deleted with the code. Every one fails SILENTLY or
expensively, so if a run produces something surprising, start here. The README documents
each as an optional one-line check:

- **The intervals contract.** A canonical BED is a fixed point of
  `sort -faidx | merge | slop -b 0`. Measured on the BED that killed a run:
  `gatk BedToIntervalList` exits 0 and silently reorders it, `nextflow -preview` reports
  success in 30.4 s, `bedtools sort | diff` catches 1 of 5 hazards. Known gap: a zero-length
  interval passes (GATK rejects it loudly, so it is not silent).
- **The tumour/normal cardinality rules.** mutect2 is absent from sarek's
  `tools_requiring_normal_samples`, so a patient with no `status=0` row runs **tumour-only and
  completes**. `status: 1.00` parses as a BigDecimal; an absent status column defaults every
  row to 0. csvtk/mlr can compute the tally but cannot fail on it; PEP/eido validated a
  tumour-only sheet as "Validation successful".
- **`--germline_resource` existence.** The only Mutect2 reference param with no
  `"exists": true` in sarek's schema, and without it sarek publishes the **unfiltered** VCF.
- **Free space on `/var/lib/containerd`.** docker 29.x writes image layers there regardless of
  `data-root`; two pilot runs died on it after 2h47m and 44m.
- **The VCF output contract.** `bcftools query -l` and a `%FILTER` tally cover most of it;
  a swapped tumour/normal is not detectable by any of it.

nf-schema does validate `--input`, `--intervals`, `--fasta`, `--fasta_fai`, `--dict` and every
per-row FASTQ path, aborting before any task — so those failures at least remain loud.

## Key domain facts (do not re-derive)

- **The target BED must be in the reference's contig order**, never lexicographic. `sort -k1,1`
  and `bedtools sort` without `-faidx` both put chr19 before chr2 and chrM before chrX; sarek
  reads `--intervals` in the order given and GATK's `GatherPileupSummaries` assumes dictionary
  order, so such a BED dies in `CalculateContamination` ~30 min in. `sort -V` is not a fix.
- **The BED must be exactly 3 columns.** `create_intervals_bed` reads column 5 as a per-region
  runtime estimate: a 6-column BED yields 107,247 shards instead of 83.
- Canonical BED at the default padding: **214,494 regions / 49,633,134 bp**, md5
  `69ed88c5131c8613efe5e20e66954e74`. **Padding is a parameter, `PAD`, defaulting to 30** — set
  on the BED command line, recorded in `params/pilot.yaml` via the filename `target_pad<n>.bed`.
  30 bp is CeGaT's own DRAGEN setting and their coverage metrics (49,599,660 bp) match our
  padded territory to 0.07 %, so changing it ends comparability with their calls.
- **`--trim_nextseq` alone is a silent no-op** — FASTP is gated on
  `trim_fastq || split_fastq || umi_location`.
- **`--igenomes_ignore true` is load-bearing.** The schema default `--genome GATK.GRCh38`
  injects a 1000g panel-of-normals, a `.64.alt` file and WGS intervals, announced only as
  `log.warn`.
- **`--nucleotides_per_second 1000`** gives 83 Mutect2 shards; the default 200000 gives **one**.
- **sarek writes the read group as `SM:<patient>_<sample>`**, so the VCF's genotype columns are
  patient-prefixed while the FILE is named from the bare sample ids. Passing the bare ids to
  the bare ids to a by-name check fails a perfectly good run.
- **`patient` must be the individual (`P11`), never the order id `S000021`.**
- **A swapped `status` is undetectable** by anything here or in sarek. Read the samplesheet
  before launching; nothing downstream will tell you.
- Nextflow must be **25.10.x**: `get.nextflow.io` now installs 26.04.6, under which the pinned
  command aborts on a valid paired samplesheet.
- The published **BWA-MEM1 index** at `gs://gcp-public-data--broad-references/hg38/v0/
  Homo_sapiens_assembly38.fasta.64.*` is byte-identical to the one sarek spends 1h14m building.

## Scope

**v1:** FASTQ + samplesheet → one paired somatic Mutect2 VCF per patient. That is all.
**Not v1:** tumour-only mode, annotation/VEP, multiple callers, BQSR, QC bundle, a GUI, a kit
registry. **v3** (recorded, not started): replace CeGaT exome Levels 2–5 — see the local, untracked
`docs/roadmap.md`; sarek has no ROH support at all.

## Where to work

Only inside this repo. The siblings `../sarek`, `../fastq-to-fasta`, `../docs` are read-only
reference — never modify them. The full audit behind these decisions is
`../docs/bed-to-sarek-annotated.md`.
