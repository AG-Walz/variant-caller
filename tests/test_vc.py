"""Contract tests for bin/vc.py — the intervals contract and the samplesheet rules.

Synthetic fixtures only: no reference data, no counts file, no network. Run with
    python3 -m unittest discover -s tests
`is_canonical` needs bedtools+pybedtools and skips itself where they are absent, so the
samplesheet half still runs anywhere.
"""
import csv
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
import vc  # noqa: E402

# A .fai whose order is deliberately NOT lexicographic, exactly like GRCh38's.
FAI = "chr1\t1000\nchr2\t1000\nchr9\t1000\nchr10\t1000\nchr19\t1000\nchrX\t1000\nchrM\t500\n"
HEADER = ",".join(vc.COLUMNS)
ROW_T = "P11,NA,1,A,L001,/a.1.fq.gz,/a.2.fq.gz"
ROW_N = "P11,NA,0,B,L001,/b.1.fq.gz,/b.2.fq.gz"


def _write(tmp, name, text):
    p = Path(tmp) / name
    p.write_text(text)
    return str(p)


class Intervals(unittest.TestCase):
    """Every case that must be rejected has cost, or could cost, a real run."""

    @classmethod
    def setUpClass(cls):
        try:
            vc._bt()
        except SystemExit:
            raise unittest.SkipTest("bedtools/pybedtools not installed")

    def _check(self, bed):
        with tempfile.TemporaryDirectory() as t:
            return vc.is_canonical(_write(t, "b.bed", bed), _write(t, "f.fai", FAI))

    def test_canonical_accepted(self):
        self.assertTrue(self._check("chr1\t0\t10\nchr2\t0\t10\nchr10\t0\t10\nchrM\t0\t10\n"))

    def test_rejects(self):
        for name, bed in [
            ("lexicographic contig order", "chr1\t0\t10\nchr10\t0\t10\nchr2\t0\t10\n"),
            ("chrM before chrX (the sort -V trap)", "chr1\t0\t10\nchrM\t0\t10\nchrX\t0\t10\n"),
            ("starts backwards within a contig", "chr1\t500\t600\nchr1\t100\t200\n"),
            ("end past the contig length", "chrM\t0\t600\n"),
            ("unmerged overlap", "chr1\t0\t100\nchr1\t50\t150\n"),
            ("book-ended rows", "chr1\t0\t100\nchr1\t100\t200\n"),
            ("duplicate rows", "chr1\t0\t100\nchr1\t0\t100\n"),
            ("6 columns (sarek reads col 5)", "chr1\t0\t10\t.\t500\t+\n"),
            ("contig absent from the .fai", "chr1\t0\t10\nchrZZ\t0\t10\n"),
            ("negative start", "chr1\t-5\t10\n"),
            ("space-delimited", "chr1 0 10\n"),
        ]:
            with self.subTest(name):
                self.assertFalse(self._check(bed))


class Samplesheet(unittest.TestCase):
    """sarek enforces none of these: measured, a tumour-only sheet runs to completion."""

    def _errs(self, body):
        with tempfile.TemporaryDirectory() as t:
            return vc.check_sheet(_write(t, "s.csv", body))

    def test_accepts(self):
        for name, body in [
            ("one pair", f"{HEADER}\n{ROW_T}\n{ROW_N}\n"),
            ("CRLF", f"{HEADER}\r\n{ROW_T}\r\n{ROW_N}\r\n"),
            ("two patients", f"{HEADER}\n{ROW_T}\n{ROW_N}\n"
                             "P12,NA,1,C,L001,/c.1.fq.gz,/c.2.fq.gz\n"
                             "P12,NA,0,D,L001,/d.1.fq.gz,/d.2.fq.gz\n"),
            ("reordered columns", "status,patient,sex,sample,lane,fastq_1,fastq_2\n"
                                  "1,P11,NA,A,L001,/a.1.fq.gz,/a.2.fq.gz\n"
                                  "0,P11,NA,B,L001,/b.1.fq.gz,/b.2.fq.gz\n"),
        ]:
            with self.subTest(name):
                self.assertEqual(self._errs(body), [])

    def test_rejects(self):
        for name, body, needle in [
            ("tumour-only (routes silently in sarek)", f"{HEADER}\n{ROW_T}\n", "status=0"),
            ("two normals", f"{HEADER}\n{ROW_T}\n{ROW_N}\n"
                            "P11,NA,0,C,L001,/c.1.fq.gz,/c.2.fq.gz\n", "exactly ONE"),
            ("no tumour", f"{HEADER}\n{ROW_N}\n", "at least one tumour"),
            ("float status (sarek accepts it)", f"{HEADER}\nP11,NA,1.00,A,L001,/a.1,/a.2\n{ROW_N}\n",
             "must be exactly 0 or 1"),
            ("missing fastq_2", f"{HEADER}\nP11,NA,1,A,L001,/a.1.fq.gz,\n{ROW_N}\n", "fastq_2 is empty"),
            ("header only", f"{HEADER}\n", "no data rows"),
            ("missing status column", "patient,sex,sample,lane,fastq_1,fastq_2\n"
                                      "P11,NA,A,L001,/a.1,/a.2\n", "missing column"),
        ]:
            with self.subTest(name):
                errs = self._errs(body)
                self.assertTrue(errs, f"{name} should be rejected")
                self.assertTrue(any(needle in e for e in errs), f"{name}: got {errs}")


if __name__ == "__main__":
    unittest.main()
