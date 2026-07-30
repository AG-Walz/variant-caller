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


VCF_HEAD = """##fileformat=VCFv4.2
##tumor_sample={t}
##normal_sample={n}
##contig=<ID=chr1,length=1000>
##FORMAT=<ID=AF,Number=A,Type=Float,Description="af">
##FILTER=<ID=weak,Description="w">
#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\t{t}\t{n}
"""
VCF_ROW = "chr1\t{pos}\t.\tA\tT\t.\t{filt}\t.\tAF\t0.5\t0.0\n"


class OutputContract(unittest.TestCase):
    """A finished run does not tell you it is correct: tumour-only routing, a zero-PASS call
    set and swapped columns all produce plausible files."""

    @classmethod
    def setUpClass(cls):
        try:
            import pysam  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("pysam not installed")

    def _vcf(self, tmp, name="P11_A_vs_P11_B.mutect2.filtered.vcf.gz", t="P11_A", n="P11_B",
             rows=(("100", "PASS"), ("200", "weak")), head=None):
        import pysam
        plain = Path(tmp) / "x.vcf"
        body = (head if head is not None else VCF_HEAD).format(t=t, n=n)
        body += "".join(VCF_ROW.format(pos=p, filt=f) for p, f in rows)
        plain.write_text(body)
        out = str(Path(tmp) / name)
        pysam.tabix_compress(str(plain), out, force=True)
        return out

    def test_good(self):
        with tempfile.TemporaryDirectory() as t:
            errs, n, npass = vc.check_vcf(self._vcf(t), "P11_A", "P11_B")
            self.assertEqual((errs, n, npass), ([], 2, 1))

    def test_bare_ids_get_the_prefix_hint(self):
        with tempfile.TemporaryDirectory() as t:
            errs, _, _ = vc.check_vcf(self._vcf(t), "A", "B")
            self.assertTrue(any("HINT" in e and "P11" in e for e in errs), errs)

    def test_rejects(self):
        cases = {
            "no _vs_ in the filename": dict(name="tumouronly.mutect2.filtered.vcf.gz"),
            "zero PASS records": dict(rows=(("100", "weak"), ("200", "weak"))),
            "FILTER empty on every record": dict(rows=(("100", "."), ("200", "."))),
            "no records at all": dict(rows=()),
        }
        for name, kw in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as t:
                errs, _, _ = vc.check_vcf(self._vcf(t, **kw), "P11_A", "P11_B")
                self.assertTrue(errs, f"{name} should be rejected")

    def test_rejects_missing_header_tags_and_af(self):
        head = VCF_HEAD.replace("##normal_sample={n}\n", "").replace(
            '##FORMAT=<ID=AF,Number=A,Type=Float,Description="af">\n',
            '##FORMAT=<ID=DP,Number=1,Type=Integer,Description="d">\n')
        with tempfile.TemporaryDirectory() as t:
            errs, _, _ = vc.check_vcf(self._vcf(t, head=head), "P11_A", "P11_B")
            self.assertTrue(any("normal_sample" in e for e in errs), errs)
            self.assertTrue(any("AF" in e for e in errs), errs)


if __name__ == "__main__":
    unittest.main()
