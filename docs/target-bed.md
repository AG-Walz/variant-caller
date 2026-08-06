# The target BED

`--intervals` is the one input sarek will not build for you. It restricts calling to the regions
your capture kit actually sequenced, and it is what `scripts/build_bed.sh` produces.

## Building it

Download your kit's BED files, list them in `BEDS`, set the rest, run it:

```bash
BEDS="references/Twist_Exome_RefSeq_targets_hg38.bed references/Twist_MitoPanel_chrM_all_hg38_target.bed"
FAI=references/Homo_sapiens_assembly38.fasta.fai
PADDING=30
OUTPUT=references/target_pad30.bed
```

Any number of files, in any order — they are concatenated, sorted and merged. Put the padding in
the output name so a BED built at one padding cannot be picked up by a run expecting another, and
point `--intervals` in `run.sh` at it.

This cohort's two Twist files at 30 bp: **214,494 regions / 49,633,134 bp**, md5
`69ed88c5131c8613efe5e20e66954e74`.

## What the four stages are for

Each fails expensively rather than loudly if you drop it.

| stage | why |
|---|---|
| `bedtools sort -faidx` | orders rows by the **reference's** contigs, not alphabetically. `sort -k1,1`, `sort -V`, and `bedtools sort` without `-faidx` all put chr10 before chr2. sarek feeds `--intervals` to GATK in the order given and `GatherPileupSummaries` assumes dictionary order, so a name-ordered BED runs for ~30 minutes and then dies in `CalculateContamination` |
| `bedtools merge` | collapses the overlaps two kit files share, and emits exactly **3 columns**. sarek's `create_intervals_bed` reads column 5 as a per-region runtime estimate: a 6-column BED scattered 107,247 ways instead of 83 |
| `bedtools slop -g` | pads both ends. `-g` supplies contig lengths, clamping padding at the end of a chromosome instead of running off into coordinates that do not exist |
| `bedtools merge` | padding pushes neighbouring regions into each other; without a second merge the file overlaps itself and the same variant is called twice in two shards |

The result is a fixed point — re-running `sort -faidx | merge | slop -b 0` reproduces it byte for
byte. That is the sanity check in [output.md](output.md).

The `.fai` must be the one for the genome `--genome` resolves to. It is 160 KB and the Broad
publish it at
`https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Homo_sapiens_assembly38.fasta.fai`.

## Why `cat` and not a BED package

Measured, not assumed:

- **BEDOPS `bedops --everything`** is documented verbatim as *"equivalent to concatenating and
  sorting BED elements from multiple files"* — but no BEDOPS tool can read a `.fai`-ordered BED
  (they abort at the chr9→chr10 boundary), and `sort-bed` reorders lexicographically, giving md5
  `2c43eb9d…`: the exact failure above.
- **`bedtk merge a.bed b.bed`** silently ignores every file after the first. It emitted 215,623
  rows with zero chrM records — the whole mitochondrial panel gone, exit code 0.
- **bioframe** reproduces the target exactly and would remove the bedtools dependency, but hides
  the load-bearing `-faidx` behind an implicit pandas property and rewrites an unknown contig to
  `NaN` instead of naming it.
- **`curl -fsSL url_a url_b`** returns the exit status of the *last* transfer only. A dead first
  URL produced a valid, correctly ordered, 3-column BED containing chrM alone, exit 0.

## Padding

A kit's BED lists where the probes bind. Probes do not stop capturing at the target boundary: a
100 bp read starting inside the target extends past it, so real coverage runs some distance either
side. Padding widens each region to include that skirt. Too little and you lose splice-site and
near-boundary variants that were sequenced perfectly well; too much and you call over positions
with a handful of reads.

**sarek's default is none.** It has no padding parameter and passes no `--interval-padding` to
GATK — it calls exactly the BED you hand it, so the effective default is 0. AG-Walz's
fastq-to-fasta never used a padded target either: its human `run_sarek.sh` passes no `--intervals`
at all, and the mouse scripts pass `--no_intervals`.

**This cohort uses 30 bp.** Measured on this kit:

| padding | regions | territory |
|---|---|---|
| 0 bp | 215,624 | 36,731,808 bp |
| 10 bp | 215,196 | 41,038,921 bp |
| **30 bp** | **214,494** | **49,633,134 bp** |
| 50 bp | 204,794 | 58,081,423 bp |

CeGaT reported **49,599,660 bp** — matching 30 bp to 0.07 %, and 35 % more territory than 0 bp.
So they called with roughly 30 bp of padding.

That was originally chosen for comparability with their calls, which is no longer the goal. The
argument that replaced it is coverage: **a validation call set has to be at least as inclusive as
the thing it is validating.** Call at 0 bp and you cover 12.9 Mb less than they did, so every
variant they reported in that skirt looks like a false positive of theirs when it is really a
blind spot of yours. Splice acceptor and donor sites also sit 1–10 bp outside the coding exons a
kit targets.

### Deriving your own number

To stop inheriting theirs, use the coverage this run produces — QC is no longer skipped, so
mosdepth runs. Measure how depth falls off with distance from the unpadded target edge:

```bash
bedtools slop -i target_pad0.bed -g $FAI -b 200 \
  | bedtools subtract -a - -b target_pad0.bed \
  | bedtools coverage -a - -b results/preprocessing/recalibrated/*/*.cram -d \
  | awk '{print $(NF-1)"\t"$NF}' | sort -n | datamash -g1 median 2
```

Pad to the last distance whose median depth still clears your calling threshold — typically 20–30×
for somatic work. Expect 10–50 bp for a 2×100 bp library. If it lands far from 30, that is itself
a finding about the vendor's run.
