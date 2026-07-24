#!/usr/bin/env python3
"""Assert the variant-caller v1 output contract on a Mutect2 filtered VCF.

Pure python3 stdlib only (gzip, argparse, os, sys) -- NO bcftools / pysam / tabix.
A .vcf.gz written by bgzip OR by python's gzip module is readable here, so this tool
never needs an external decompressor.

Contract checked (fail fast, first failure names the check):
  1. filename basename contains '_vs_' and ends '.mutect2.filtered.vcf.gz'
  2. a sibling '<vcf>.tbi' exists (WARN only, never fails -- the index is not VCF text)
  3. header carries ##tumor_sample=<X> and ##normal_sample=<Y>
  4. the #CHROM line has EXACTLY 2 sample columns, and the three sets agree:
        {tumour, normal} from CLI  ==  {X, Y} from headers  ==  the two #CHROM columns
  5. FORMAT column contains 'AF' on at least one record
  6. FILTER column is NOT uniformly '.' across data records (>=1 PASS or named filter)
  7. at least one ##contig= line, and contigs look like GRCh38 (chr-prefixed; chr1 present)

On success prints a concise PASS summary and exits 0. On failure exits 1 with a message
naming the first failed check.
"""

import argparse
import gzip
import os
import sys


class ContractError(AssertionError):
    """Raised when the VCF violates the v1 output contract."""


def _open_text(path):
    # gzip.open in text mode reads both bgzip and python-gzip outputs.
    return gzip.open(path, "rt", encoding="utf-8", errors="replace")


def assert_vcf(path, tumour, normal):
    """Validate the output contract. Raise ContractError on the first failed check.

    Returns a dict summary on success: {records, n_pass, tumour, normal}.
    """
    cli_samples = {tumour, normal}
    if len(cli_samples) != 2:
        raise ContractError(
            "CHECK sample-args: --tumour and --normal must differ "
            f"(got tumour={tumour!r}, normal={normal!r})"
        )

    base = os.path.basename(path)

    # --- CHECK 1: filename ------------------------------------------------
    if "_vs_" not in base:
        raise ContractError(
            f"CHECK filename: basename {base!r} does not contain '_vs_' "
            "(a paired somatic VCF is named <tumour>_vs_<normal>...)"
        )
    if not base.endswith(".mutect2.filtered.vcf.gz"):
        raise ContractError(
            f"CHECK filename: basename {base!r} does not end "
            "'.mutect2.filtered.vcf.gz'"
        )

    # --- CHECK 2: sibling .tbi (warn only) --------------------------------
    tbi = path + ".tbi"
    if not os.path.exists(tbi):
        sys.stderr.write(
            f"WARNING: tabix index not found next to VCF ({tbi}); "
            "the VCF text passes but an index should exist.\n"
        )

    hdr_tumor = None
    hdr_normal = None
    chrom_samples = None
    has_contig = False
    contig_names = []
    saw_format_af = False
    filters_seen = set()
    n_records = 0
    n_pass = 0

    with _open_text(path) as fh:
        for line in fh:
            if line.startswith("##"):
                if line.startswith("##tumor_sample="):
                    hdr_tumor = line.strip().split("=", 1)[1]
                elif line.startswith("##normal_sample="):
                    hdr_normal = line.strip().split("=", 1)[1]
                elif line.startswith("##contig="):
                    has_contig = True
                    # ##contig=<ID=chr1,length=...>
                    body = line.strip()
                    idpos = body.find("ID=")
                    if idpos != -1:
                        rest = body[idpos + 3:]
                        # terminate at ',' or '>'
                        name = rest.split(",", 1)[0].split(">", 1)[0]
                        contig_names.append(name)
                continue

            if line.startswith("#CHROM"):
                fields = line.rstrip("\n").split("\t")
                # Standard VCF: 8 fixed cols; FORMAT at index 8; samples from 9.
                if len(fields) <= 9 or fields[8] != "FORMAT":
                    raise ContractError(
                        "CHECK columns: #CHROM line lacks a FORMAT column with "
                        f"sample columns after it (found {len(fields)} fields)"
                    )
                chrom_samples = fields[9:]
                continue

            # data record
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 8:
                continue
            n_records += 1
            filt = cols[6]
            filters_seen.add(filt)
            if filt == "PASS":
                n_pass += 1
            fmt = cols[8] if len(cols) > 8 else ""
            if "AF" in fmt.split(":"):
                saw_format_af = True

    # --- CHECK 3: header sample tags --------------------------------------
    if hdr_tumor is None:
        raise ContractError("CHECK header-tags: ##tumor_sample= line is missing")
    if hdr_normal is None:
        raise ContractError("CHECK header-tags: ##normal_sample= line is missing")

    # --- CHECK 4: exactly two sample columns; three sets agree ------------
    if chrom_samples is None:
        raise ContractError("CHECK columns: no #CHROM header line found")
    if len(chrom_samples) != 2:
        raise ContractError(
            f"CHECK columns: expected EXACTLY 2 sample columns, found "
            f"{len(chrom_samples)}: {chrom_samples} "
            "(a tumour-only run also has columns -- this must be the paired VCF)"
        )
    chrom_set = set(chrom_samples)
    hdr_set = {hdr_tumor, hdr_normal}
    if chrom_set != cli_samples:
        raise ContractError(
            "CHECK columns: #CHROM sample columns "
            f"{sorted(chrom_set)} != declared {sorted(cli_samples)} "
            "(--tumour/--normal)"
        )
    if hdr_set != cli_samples:
        raise ContractError(
            "CHECK columns: header ##tumor_sample/##normal_sample "
            f"{sorted(hdr_set)} != declared {sorted(cli_samples)}"
        )
    # role-exact: header tumor tag must equal declared tumour, normal to normal.
    if hdr_tumor != tumour:
        raise ContractError(
            f"CHECK columns: ##tumor_sample={hdr_tumor!r} does not match "
            f"declared --tumour {tumour!r}"
        )
    if hdr_normal != normal:
        raise ContractError(
            f"CHECK columns: ##normal_sample={hdr_normal!r} does not match "
            f"declared --normal {normal!r}"
        )

    if n_records == 0:
        raise ContractError(
            "CHECK records: no data records found -- an empty VCF cannot satisfy "
            "the AF / FILTER checks"
        )

    # --- CHECK 5: AF in FORMAT --------------------------------------------
    if not saw_format_af:
        raise ContractError(
            "CHECK format-af: no data record has 'AF' in its FORMAT column"
        )

    # --- CHECK 6: FILTER not uniformly '.' --------------------------------
    if filters_seen == {"."}:
        raise ContractError(
            "CHECK filter: FILTER column is uniformly '.' across all records "
            "(FilterMutectCalls did not run -- likely the UNFILTERED VCF; check "
            "--germline_resource was passed)"
        )

    # --- CHECK 6b: at least one PASS record -------------------------------
    # A VCF where FilterMutectCalls rejected EVERY record satisfies every
    # structural check above, yet downstream `bcftools view -f PASS` yields an
    # empty file with no error. That silent-empty path is the one the decision
    # record calls out, so zero PASS is a contract failure, not a warning.
    if n_pass == 0:
        raise ContractError(
            "CHECK filter-pass: FILTER is populated but NO record is PASS "
            f"({n_records} records, filters seen: {sorted(filters_seen)}) -- "
            "downstream 'bcftools view -f PASS' would silently yield zero "
            "variants"
        )

    # --- CHECK 7: GRCh38 contigs ------------------------------------------
    if not has_contig:
        raise ContractError("CHECK contigs: no ##contig= line found in header")
    if not any(c.startswith("chr") for c in contig_names):
        raise ContractError(
            "CHECK contigs: no chr-prefixed contig found "
            f"(first contigs: {contig_names[:5]}) -- expected GRCh38"
        )
    if "chr1" not in contig_names:
        raise ContractError(
            "CHECK contigs: 'chr1' not among ##contig IDs "
            f"(first contigs: {contig_names[:5]}) -- expected GRCh38"
        )

    return {
        "records": n_records,
        "n_pass": n_pass,
        "tumour": tumour,
        "normal": normal,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Assert the variant-caller v1 output contract on a "
        "Mutect2 filtered somatic VCF."
    )
    parser.add_argument("vcf", help="path to the *.mutect2.filtered.vcf.gz")
    parser.add_argument("--tumour", required=True, help="declared tumour sample id")
    parser.add_argument("--normal", required=True, help="declared normal sample id")
    args = parser.parse_args(argv)

    try:
        summary = assert_vcf(args.vcf, args.tumour, args.normal)
    except ContractError as exc:
        sys.stderr.write(f"FAIL: {exc}\n")
        return 1
    except FileNotFoundError:
        sys.stderr.write(f"FAIL: VCF not found: {args.vcf}\n")
        return 1

    print(
        "PASS: output contract satisfied  "
        f"records={summary['records']} PASS={summary['n_pass']} "
        f"tumour={summary['tumour']} normal={summary['normal']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
