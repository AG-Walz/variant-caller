#!/usr/bin/env python3
"""Clone nf-core/sarek and download the reference files a run needs.

Which files those are is data, not code — see assets/references.txt. Every download resumes
where it stopped and an existing sarek clone is left alone, so re-running this is cheap.
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

# The pipeline is validated against this tag, and only this tag. Every measurement in
# DECISIONS.md was made on it, so it is deliberately not an option.
SAREK_VERSION = "3.9.0"

REQUIRED_TOOLS = {
    "nextflow": "the workflow engine — must be 25.10.x, since 26.x aborts on a valid samplesheet",
    "java": "nextflow runs on the JVM; 17 or newer",
    "docker": "every tool sarek calls runs in a container, so nothing else is installed here",
    "bedtools": "used by build_bed.py",
    "aria2c": "parallel, resumable downloader; curl cannot resume the 3.2 GB files as cleanly",
    "curl": "used by build_bed.py to fetch capture-kit BEDs by URL",
}

INSTALL_HINT = (
    "mamba create -y -p ~/envs/vc -c conda-forge -c bioconda "
    "nextflow=25.10.4 openjdk=17 bedtools aria2\n"
    "export PATH=~/envs/vc/bin:$PATH"
)


def check_tools() -> None:
    """Report every missing tool at once, so they can be installed in one go."""
    missing = {tool: why for tool, why in REQUIRED_TOOLS.items() if not shutil.which(tool)}
    if missing:
        for tool, why in missing.items():
            print(f"missing: {tool:10} {why}", file=sys.stderr)
        sys.exit(f"\ninstall them with:\n{INSTALL_HINT}")


def clone_sarek(directory: Path) -> None:
    """Shallow-clone the pinned tag, unless the directory already exists."""
    if directory.exists():
        print(f"sarek already at {directory}, leaving it alone")
        return
    subprocess.run(
        ["git", "clone", "--branch", SAREK_VERSION, "--depth", "1",
         "https://github.com/nf-core/sarek.git", str(directory)],
        check=True,
    )


def read_file_list(list_file: Path) -> list[tuple[str, str]]:
    """Parse `URL <tab> destination` lines, ignoring blanks and comments."""
    entries = []
    for line in list_file.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        url, destination = line.split()
        entries.append((url, destination))
    return entries


def download(url: str, destination: Path) -> None:
    """Fetch one file, resuming a partial download rather than restarting it."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["aria2c", "--max-connection-per-server=8", "--split=8", "--continue=true",
         "--dir", str(destination.parent), "--out", destination.name, url],
        check=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--file-list", type=Path, required=True,
                        help="lines of `URL <tab> destination`, e.g. assets/references.txt")
    parser.add_argument("--references-dir", type=Path, required=True,
                        help="where the downloaded files land; destinations are relative to it")
    parser.add_argument("--sarek-dir", type=Path, required=True,
                        help=f"where to clone nf-core/sarek {SAREK_VERSION}, e.g. ../sarek")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    check_tools()
    clone_sarek(args.sarek_dir)
    for url, destination in read_file_list(args.file_list):
        download(url, args.references_dir / destination)
    print(f"\nsetup complete: sarek at {args.sarek_dir}, "
          f"files from {args.file_list} in {args.references_dir}/")


if __name__ == "__main__":
    main()
