#!/usr/bin/env python3
"""Combine capture-kit BED files into the target BED that sarek scatters calling over.

The four bedtools stages are not interchangeable, and each fails expensively rather than
loudly if it is dropped:

    sort -faidx   orders rows by the reference's contigs, not alphabetically. A name-ordered
                  BED runs for ~30 minutes and then dies in GATK's CalculateContamination.
    merge         collapses overlaps, and emits exactly three columns. sarek reads a fifth
                  column as a per-region runtime estimate: a 6-column BED scattered 107,247
                  ways instead of 83.
    slop -g       pads both ends, clamped to the contig lengths so padding cannot run off
                  the end of a chromosome.
    merge         re-collapses the regions that padding pushed into each other, so no
                  variant is called twice in two different shards.

The output is a fixed point of sort|merge|slop -b 0, which is the sanity check in README.md.
"""

import argparse
import hashlib
import subprocess
import tempfile
from pathlib import Path
from urllib.request import urlopen


def concatenate(sources: list[str], destination: Path) -> None:
    """Write every source, local path or URL, into one file."""
    with destination.open("wb") as combined:
        for source in sources:
            if source.startswith(("http://", "https://")):
                with urlopen(source) as response:
                    combined.write(response.read())
            else:
                combined.write(Path(source).read_bytes())


def bedtools(*arguments, output: Path) -> Path:
    """Run one bedtools subcommand into `output`, aborting if it fails."""
    with output.open("wb") as destination:
        subprocess.run(["bedtools", *map(str, arguments)], stdout=destination, check=True)
    return output


def canonicalise(combined: Path, reference_fai: Path, padding: int, output: Path) -> None:
    """Sort into reference contig order, merge, pad, merge again."""
    with tempfile.TemporaryDirectory() as workspace:
        stage = Path(workspace)
        ordered = bedtools("sort", "-faidx", reference_fai, "-i", combined, output=stage / "sorted.bed")
        merged = bedtools("merge", "-i", ordered, output=stage / "merged.bed")
        padded = bedtools("slop", "-i", merged, "-g", reference_fai, "-b", padding, output=stage / "padded.bed")
        bedtools("merge", "-i", padded, output=output)


def describe(bed: Path) -> str:
    """Region count, total territory and digest — compare these against your last good build."""
    regions = territory = 0
    for line in bed.read_text().splitlines():
        _, start, end = line.split("\t")[:3]
        regions += 1
        territory += int(end) - int(start)
    digest = hashlib.md5(bed.read_bytes()).hexdigest()
    return f"{bed}: {regions} regions, {territory} bp, md5 {digest}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--reference-fai", type=Path, required=True,
                        help="the .fai of the exact FASTA you will call against")
    parser.add_argument("--padding", type=int, required=True,
                        help="bases added to both ends of every region; this cohort uses 30, "
                             "the sequencing vendor's own DRAGEN setting")
    parser.add_argument("--output", type=Path, required=True,
                        help="where to write; put the padding in the name so a params file "
                             "cannot pick up a BED built at a different one")
    parser.add_argument("sources", nargs="+", metavar="SOURCE",
                        help="capture-kit BED files, as paths or URLs, in any mix")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    with tempfile.TemporaryDirectory() as workspace:
        combined = Path(workspace) / "combined.bed"
        concatenate(args.sources, combined)
        canonicalise(combined, args.reference_fai, args.padding, args.output)
    print(describe(args.output))


if __name__ == "__main__":
    main()
