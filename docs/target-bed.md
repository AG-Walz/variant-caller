# The target BED

`--intervals` is the one input sarek will not build for you. It restricts calling to the regions
your capture kit actually sequenced, and `scripts/build_bed.sh` produces it.

## Building it

Download your kit's BED files, then edit the top of `scripts/build_bed.sh` and run it:

```bash
BEDS="references/kit1.bed references/kit2.bed"
FAI=references/Homo_sapiens_assembly38.fasta.fai
PADDING=30
OUTPUT=references/target_pad30.bed
```

Any number of files, in any order — they are concatenated, sorted and merged. Keep the padding in
the output name, so a BED built at one padding cannot be picked up by a run expecting another, and
point `INTERVALS` in `run.sh` at it.

The `.fai` must belong to the genome `--genome` resolves to. It is 160 KB, published by the Broad at
`https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Homo_sapiens_assembly38.fasta.fai`.

`build_bed.sh` has no `set -e`, and the `>` redirect creates the output before the pipeline runs —
so a missing `bedtools`, or a kit URL that served a redirect stub, gives you a near-empty BED and a
blank summary line rather than an error. Nothing downstream rejects an empty target, so check the
region count it prints.

Do not substitute another tool for the `cat`: BEDOPS and `sort-bed` reorder lexicographically,
`bedtk merge` silently ignores every file after the first (exit 0, the whole mito panel gone), and
one `curl` given several URLs returns only the last transfer's status.

## What the four stages are for

Each fails expensively rather than loudly if you drop it.

| stage | why |
|---|---|
| `bedtools sort -faidx` | orders rows by the **reference's** contigs. `sort -k1,1` and `bedtools sort` without `-faidx` are lexicographic and put chr10 before chr2; `sort -V` fixes that but still does not reproduce the `.fai`'s placement of chrM, chrX, chrY and the alt contigs. sarek feeds `--intervals` to GATK in the order given and `GatherPileupSummaries` assumes dictionary order, so a wrongly ordered BED runs ~30 minutes and then dies in `CalculateContamination` |
| `bedtools merge` | collapses the overlaps two kit files share, and emits exactly **3 columns**. sarek's `create_intervals_bed` reads column 5 as a per-region runtime estimate: a 6-column BED scattered 107,247 ways instead of 83 |
| `bedtools slop -g` | pads both ends. `-g` supplies contig lengths, clamping the padding at the end of a chromosome instead of running off into coordinates that do not exist |
| `bedtools merge` | padding pushes neighbouring regions into each other; without a second merge the file overlaps itself and the same variant is called twice in two shards |

The result is a fixed point — re-running `sort -faidx | merge | slop -b 0` reproduces it byte for
byte. That is the sanity check in [output.md](output.md).

## Padding

A kit's BED lists where the probes bind, but probes do not stop capturing at the target boundary:
a 100 bp read starting inside the target extends past it, so real coverage runs some distance
either side. Padding widens each region to include that skirt. Too little and you lose splice-site
and near-boundary variants that were sequenced perfectly well; too much and you call over positions
with a handful of reads.

**sarek's default is none.** It has no padding parameter and passes no `--interval-padding` to
GATK, so it calls exactly the BED you hand it.

**30 bp is a reasonable starting point.** On a Twist exome + mito kit it gives 214,494 regions and
49,633,134 bp, against 215,624 regions and 36,731,808 bp unpadded — 35 % more territory:

| padding | regions | territory |
|---|---|---|
| 0 bp | 215,624 | 36,731,808 bp |
| 10 bp | 215,196 | 41,038,921 bp |
| **30 bp** | **214,494** | **49,633,134 bp** |
| 50 bp | 204,794 | 58,081,423 bp |

If you are checking someone else's call set, your target has to be at least as inclusive as
theirs. Call at 0 bp against a target they padded and you cover ~13 Mb less, so every variant they
reported in that skirt looks like a false positive of theirs when it is really a blind spot of
yours. Splice acceptor and donor sites also sit 1–10 bp outside the coding exons a kit targets.

To derive your own number rather than inherit one, run mosdepth (`--by`, `--fasta`; it reads the
CRAMs sarek publishes) over successive bands outside the unpadded target, and pad to the last band
whose median depth still clears your calling threshold — typically 20–30× for somatic work. Expect
10–50 bp for a 2×100 bp library.
