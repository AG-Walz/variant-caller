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
    "git": "clone_sarek() shells out to it",
    "bedtools": "the four stages of build_bed.py",
    "aria2c": "parallel, resumable, checksum-verifying downloader",
}

INSTALL_HINT = (
    "mamba create -y -p ~/envs/vc -c conda-forge -c bioconda "
    "nextflow=25.10.4 openjdk=17 bedtools aria2 git\n"
    "export PATH=~/envs/vc/bin:$PATH\n"
    "docker is a host daemon, not a conda package — install it separately"
)


def check_required_tools() -> None:
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


def read_download_list(list_file: Path) -> list[tuple[str, str, str | None]]:
    """Parse `URL <tab> destination [<tab> md5]` lines, ignoring blanks and comments."""
    entries = []
    for line in list_file.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # The md5 is optional so that a mirror publishing no digest still works; unpacking
        # it as a required third field would break every two-column list.
        url, destination, *checksum = line.split()
        entries.append((url, destination, checksum[0] if checksum else None))
    return entries


def download_file(url: str, destination: Path, md5: str | None = None) -> None:
    """Fetch one file, resuming a partial download and re-fetching a corrupt one."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["aria2c",
         # Eight parallel connections to the one file: the difference between minutes and
         # an hour on the two 3.2 GB downloads.
         "--max-connection-per-server=8", "--split=8",
         # Resume a partial file instead of starting over, which is what makes re-running
         # this script after an interruption cost only what is missing.
         "--continue=true",
         # ...but --continue alone trusts SIZE. A reference corrupted in place is
         # size-complete, so aria2c declares it finished at 0 B/s and every run afterwards
         # is quietly wrong. With the digest it notices and re-downloads; on a genuinely
         # bad file it exits 32 and check=True aborts here rather than 17 hours later.
         *([f"--checksum=md5={md5}"] if md5 else []),
         "--dir", str(destination.parent), "--out", destination.name, url],
        check=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--file-list", type=Path, required=True,
                        help="lines of `URL <tab> destination [<tab> md5]`, "
                             "e.g. assets/references.txt")
    parser.add_argument("--references-dir", type=Path, required=True,
                        help="where the downloaded files land; destinations are relative to it")
    parser.add_argument("--sarek-dir", type=Path, required=True,
                        help=f"where to clone nf-core/sarek {SAREK_VERSION}, e.g. ../sarek")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    check_required_tools()
    clone_sarek(args.sarek_dir)
    for url, destination, md5 in read_download_list(args.file_list):
        download_file(url, args.references_dir / destination, md5)
    print(f"\nsetup complete: sarek at {args.sarek_dir}, "
          f"files from {args.file_list} in {args.references_dir}/")


if __name__ == "__main__":
    main()
