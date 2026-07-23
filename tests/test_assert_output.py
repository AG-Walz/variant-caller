#!/usr/bin/env python3
"""Unit tests for bin/assert_output.py.

Builds TINY synthetic VCFs with the gzip module (gzip-written .vcf.gz is readable
back by gzip -- no bgzip needed). One GOOD vcf passes; each BAD variant trips
exactly one contract check. Run:  python3 -m unittest -v
"""

import gzip
import importlib.util
import os
import sys
import tempfile
import unittest

# Import bin/assert_output.py by path (bin/ is not a package).
_HERE = os.path.dirname(os.path.abspath(__file__))
_MOD_PATH = os.path.join(_HERE, os.pardir, "bin", "assert_output.py")
_spec = importlib.util.spec_from_file_location("assert_output", _MOD_PATH)
assert_output = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(assert_output)

assert_vcf = assert_output.assert_vcf
ContractError = assert_output.ContractError

TUMOUR = "S12944Nr11"
NORMAL = "S12944Nr12"
GOOD_NAME = "S12944Nr11_vs_S12944Nr12.mutect2.filtered.vcf.gz"


def build_vcf(
    tumor_tag=TUMOUR,
    normal_tag=NORMAL,
    columns=(TUMOUR, NORMAL),
    contigs=("chr1", "chr2"),
    formats=("GT:AF:DP", "GT:AF:DP"),
    filters=("PASS", "weak_evidence"),
    include_tumor_tag=True,
    include_normal_tag=True,
    include_contig=True,
    include_chrom=True,
):
    """Assemble VCF text with knobs to break one thing at a time."""
    lines = ["##fileformat=VCFv4.2"]
    if include_tumor_tag:
        lines.append(f"##tumor_sample={tumor_tag}")
    if include_normal_tag:
        lines.append(f"##normal_sample={normal_tag}")
    lines.append('##FORMAT=<ID=AF,Number=A,Type=Float,Description="Allele fraction">')
    if include_contig:
        for c in contigs:
            lines.append(f"##contig=<ID={c},length=1000000>")
    if include_chrom:
        header = ["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT"]
        header.extend(columns)
        lines.append("\t".join(header))
    # data records -- one per FILTER value given
    for i, filt in enumerate(filters):
        fmt = formats[i] if i < len(formats) else formats[-1]
        rec = [
            contigs[0] if contigs else "chr1",
            str(1000 + i),
            ".",
            "A",
            "T",
            ".",
            filt,
            "DP=50",
            fmt,
            "0/1:0.25:40",
            "0/0:0.01:38",
        ]
        lines.append("\t".join(rec))
    return "\n".join(lines) + "\n"


def write_gz(dirpath, name, text):
    path = os.path.join(dirpath, name)
    with gzip.open(path, "wt", encoding="utf-8") as fh:
        fh.write(text)
    return path


class AssertOutputTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def _write(self, name, text):
        return write_gz(self.dir, name, text)

    # --- the GOOD case ----------------------------------------------------
    def test_good_vcf_passes(self):
        p = self._write(GOOD_NAME, build_vcf())
        # sibling .tbi present so no warning noise
        open(p + ".tbi", "w").close()
        summary = assert_vcf(p, TUMOUR, NORMAL)
        self.assertEqual(summary["records"], 2)
        self.assertEqual(summary["n_pass"], 1)
        self.assertEqual(summary["tumour"], TUMOUR)
        self.assertEqual(summary["normal"], NORMAL)

    def test_good_vcf_passes_without_tbi(self):
        # missing .tbi must WARN, not fail
        p = self._write(GOOD_NAME, build_vcf())
        summary = assert_vcf(p, TUMOUR, NORMAL)
        self.assertEqual(summary["records"], 2)

    # --- CHECK 1: filename ------------------------------------------------
    def test_bad_filename_no_vs(self):
        p = self._write("S12944Nr11.mutect2.filtered.vcf.gz", build_vcf())
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("filename", str(cm.exception))

    def test_bad_filename_wrong_suffix(self):
        p = self._write("S12944Nr11_vs_S12944Nr12.mutect2.vcf.gz", build_vcf())
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("filename", str(cm.exception))

    # --- CHECK 6: FILTER uniformly '.' ------------------------------------
    def test_filter_all_dots(self):
        p = self._write(GOOD_NAME, build_vcf(filters=(".", ".")))
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("filter", str(cm.exception).lower())

    # --- CHECK 4: wrong column names --------------------------------------
    def test_wrong_column_names(self):
        # columns disagree with CLI/headers
        p = self._write(
            GOOD_NAME,
            build_vcf(columns=("WRONG_T", "WRONG_N"),
                      tumor_tag="WRONG_T", normal_tag="WRONG_N"),
        )
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("columns", str(cm.exception).lower())

    def test_swapped_tumour_normal_roles(self):
        # sets agree but tumor/normal roles are swapped vs declared
        p = self._write(
            GOOD_NAME,
            build_vcf(tumor_tag=NORMAL, normal_tag=TUMOUR),
        )
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("columns", str(cm.exception).lower())

    # --- CHECK 4: only one sample column ----------------------------------
    def test_only_one_sample_column(self):
        text = build_vcf(columns=(TUMOUR,))
        # build_vcf lays down 2 genotype fields per record; trim to 1 to match.
        fixed = []
        for line in text.splitlines():
            if line.startswith("#") or "\t" not in line:
                fixed.append(line)
                continue
            cols = line.split("\t")
            if len(cols) > 10:  # a data record with 2 GT cols
                cols = cols[:10]
            fixed.append("\t".join(cols))
        p = self._write(GOOD_NAME, "\n".join(fixed) + "\n")
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("columns", str(cm.exception).lower())

    # --- CHECK 3: missing ##tumor_sample ----------------------------------
    def test_missing_tumor_sample_header(self):
        p = self._write(GOOD_NAME, build_vcf(include_tumor_tag=False))
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("header-tags", str(cm.exception).lower())

    # --- CHECK 5: no AF in FORMAT -----------------------------------------
    def test_no_af_in_format(self):
        p = self._write(GOOD_NAME, build_vcf(formats=("GT:DP", "GT:DP")))
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("format-af", str(cm.exception).lower())

    # --- CHECK 7: non-chr contigs -----------------------------------------
    def test_non_chr_contigs(self):
        p = self._write(GOOD_NAME, build_vcf(contigs=("1", "2")))
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("contigs", str(cm.exception).lower())

    def test_no_contig_lines(self):
        p = self._write(GOOD_NAME, build_vcf(include_contig=False))
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, NORMAL)
        self.assertIn("contigs", str(cm.exception).lower())

    # --- sample-arg guard -------------------------------------------------
    def test_identical_tumour_normal_args(self):
        p = self._write(GOOD_NAME, build_vcf())
        with self.assertRaises(ContractError) as cm:
            assert_vcf(p, TUMOUR, TUMOUR)
        self.assertIn("sample-args", str(cm.exception).lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
