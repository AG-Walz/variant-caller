#!/usr/bin/env python3
"""Unit tests for bin/build_samplesheet.py (python3 -m unittest).

Covers: R1/R2 pairing (incl. unpaired-file error), sample-id derivation,
label->status downcast, and EACH of the four validator rules firing with the
right sample/patient named. Uses tmp dirs and synthetic filenames; no network.
"""

import os
import sys
import tempfile
import unittest

# Make bin/ importable regardless of cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_BIN = os.path.join(os.path.dirname(_HERE), "bin")
if _BIN not in sys.path:
    sys.path.insert(0, _BIN)

import build_samplesheet as bss  # noqa: E402


def _touch(path):
    with open(path, "w") as fh:
        fh.write("")


def _make_fastqs(tmpdir, names):
    for n in names:
        _touch(os.path.join(tmpdir, n))


class DiscoverPairsTest(unittest.TestCase):
    def test_dot_pairing_and_sample_id(self):
        with tempfile.TemporaryDirectory() as d:
            _make_fastqs(
                d,
                [
                    "S000021_S12944Nr11.1.fastq.gz",
                    "S000021_S12944Nr11.2.fastq.gz",
                ],
            )
            pairs = bss.discover_pairs(d)
            self.assertEqual(list(pairs), ["S12944Nr11"])
            r = pairs["S12944Nr11"]
            self.assertTrue(r["fastq_1"].endswith("S000021_S12944Nr11.1.fastq.gz"))
            self.assertTrue(r["fastq_2"].endswith("S000021_S12944Nr11.2.fastq.gz"))
            self.assertTrue(os.path.isabs(r["fastq_1"]))

    def test_underscore_r_pairing(self):
        with tempfile.TemporaryDirectory() as d:
            _make_fastqs(d, ["sampA_R1.fastq.gz", "sampA_R2.fastq.gz"])
            pairs = bss.discover_pairs(d, order_prefix="")
            self.assertEqual(list(pairs), ["sampA"])

    def test_underscore_digit_pairing(self):
        with tempfile.TemporaryDirectory() as d:
            _make_fastqs(d, ["sampB_1.fastq.gz", "sampB_2.fastq.gz"])
            pairs = bss.discover_pairs(d, order_prefix="")
            self.assertEqual(list(pairs), ["sampB"])

    def test_sample_id_strips_only_order_prefix(self):
        with tempfile.TemporaryDirectory() as d:
            _make_fastqs(
                d, ["S000021_S12944Nr12.1.fastq.gz", "S000021_S12944Nr12.2.fastq.gz"]
            )
            pairs = bss.discover_pairs(d)
            self.assertEqual(list(pairs), ["S12944Nr12"])

    def test_unpaired_r1_raises(self):
        with tempfile.TemporaryDirectory() as d:
            _make_fastqs(d, ["S000021_S12944Nr11.1.fastq.gz"])
            with self.assertRaises(bss.BuildError) as ctx:
                bss.discover_pairs(d)
            self.assertIn("no R2", str(ctx.exception))
            self.assertIn("S12944Nr11", str(ctx.exception))

    def test_unpaired_r2_raises(self):
        with tempfile.TemporaryDirectory() as d:
            _make_fastqs(d, ["S000021_S12944Nr11.2.fastq.gz"])
            with self.assertRaises(bss.BuildError) as ctx:
                bss.discover_pairs(d)
            self.assertIn("no R1", str(ctx.exception))

    def test_unrecognised_mate_token_raises(self):
        with tempfile.TemporaryDirectory() as d:
            _make_fastqs(d, ["weirdsample.fastq.gz"])
            with self.assertRaises(bss.BuildError) as ctx:
                bss.discover_pairs(d)
            self.assertIn("mate token", str(ctx.exception))


class LoadDeclarationsTest(unittest.TestCase):
    def _write(self, d, text):
        p = os.path.join(d, "decl.tsv")
        with open(p, "w") as fh:
            fh.write(text)
        return p

    def test_header_and_rows(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._write(
                d,
                "sample\tpatient\tlabel\n"
                "S12944Nr11\tP11\ttumour\n"
                "S12944Nr12\tP11\ttumour_adjacent\n",
            )
            decls = bss.load_declarations(p)
            self.assertEqual(decls["S12944Nr11"], ("P11", "tumour"))
            self.assertEqual(decls["S12944Nr12"], ("P11", "tumour_adjacent"))

    def test_no_header_ok(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._write(d, "S1\tP1\ttumour\n")
            decls = bss.load_declarations(p)
            self.assertEqual(decls, {"S1": ("P1", "tumour")})

    def test_duplicate_sample_raises(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._write(d, "S1\tP1\ttumour\nS1\tP1\tcontrol_healthy\n")
            with self.assertRaises(bss.BuildError) as ctx:
                bss.load_declarations(p)
            self.assertIn("S1", str(ctx.exception))


class BuildRowsTest(unittest.TestCase):
    def test_label_downcast(self):
        pairs = {
            "T": {"fastq_1": "/a/T.1", "fastq_2": "/a/T.2"},
            "N": {"fastq_1": "/a/N.1", "fastq_2": "/a/N.2"},
        }
        decls = {"T": ("P1", "tumour"), "N": ("P1", "control_healthy")}
        rows = bss.build_rows(pairs, decls)
        by_sample = {r["sample"]: r for r in rows}
        self.assertEqual(by_sample["T"]["status"], 1)
        self.assertEqual(by_sample["N"]["status"], 0)
        # tumour_adjacent and control_benign also downcast to 0.
        for lbl in ("tumour_adjacent", "control_benign"):
            rows2 = bss.build_rows(
                {"X": {"fastq_1": "/a/x.1", "fastq_2": "/a/x.2"}},
                {"X": ("P9", lbl)},
            )
            self.assertEqual(rows2[0]["status"], 0)

    def test_unknown_label_raises_naming_sample(self):
        pairs = {"S1": {"fastq_1": "/a/1", "fastq_2": "/a/2"}}
        decls = {"S1": ("P1", "bogus_label")}
        with self.assertRaises(bss.BuildError) as ctx:
            bss.build_rows(pairs, decls)
        msg = str(ctx.exception)
        self.assertIn("S1", msg)
        self.assertIn("bogus_label", msg)

    def test_declared_sample_without_files_raises(self):
        pairs = {"S1": {"fastq_1": "/a/1", "fastq_2": "/a/2"}}
        decls = {"S1": ("P1", "tumour"), "S2": ("P1", "control_healthy")}
        with self.assertRaises(bss.BuildError) as ctx:
            bss.build_rows(pairs, decls)
        self.assertIn("S2", str(ctx.exception))

    def test_undeclared_discovered_sample_ignored(self):
        pairs = {
            "T": {"fastq_1": "/a/T.1", "fastq_2": "/a/T.2"},
            "N": {"fastq_1": "/a/N.1", "fastq_2": "/a/N.2"},
            "EXTRA": {"fastq_1": "/a/E.1", "fastq_2": "/a/E.2"},
        }
        decls = {"T": ("P1", "tumour"), "N": ("P1", "control_healthy")}
        rows = bss.build_rows(pairs, decls)
        self.assertEqual({r["sample"] for r in rows}, {"T", "N"})


def _rows(*specs):
    """specs: (sample, patient, status) tuples -> row dicts."""
    out = []
    for sample, patient, status in specs:
        out.append(
            {
                "patient": patient,
                "sex": "NA",
                "status": status,
                "sample": sample,
                "lane": "L001",
                "fastq_1": "/a/%s.1" % sample,
                "fastq_2": "/a/%s.2" % sample,
            }
        )
    return out


class ValidateTest(unittest.TestCase):
    def test_valid_pair_passes(self):
        rows = _rows(("T", "P1", 1), ("N", "P1", 0))
        self.assertEqual(bss.validate(rows), rows)

    def test_rule2_more_than_one_normal_raises(self):
        rows = _rows(("T", "P1", 1), ("N1", "P1", 0), ("N2", "P1", 0))
        with self.assertRaises(bss.BuildError) as ctx:
            bss.validate(rows)
        msg = str(ctx.exception)
        self.assertIn("P1", msg)
        self.assertIn("N1", msg)
        self.assertIn("N2", msg)

    def test_rule3_zero_tumour_raises(self):
        rows = _rows(("N", "P1", 0))
        with self.assertRaises(bss.BuildError) as ctx:
            bss.validate(rows)
        msg = str(ctx.exception)
        self.assertIn("P1", msg)
        self.assertIn("status=1", msg)

    def test_rule4_zero_normal_raises_paired_only(self):
        rows = _rows(("T", "P1", 1))
        with self.assertRaises(bss.BuildError) as ctx:
            bss.validate(rows)
        msg = str(ctx.exception)
        self.assertIn("P1", msg)
        self.assertIn("PAIRED", msg)

    def test_rule4_names_only_offending_patient(self):
        # P1 good pair, P2 tumour-only -> only P2 named.
        rows = _rows(("T1", "P1", 1), ("N1", "P1", 0), ("T2", "P2", 1))
        with self.assertRaises(bss.BuildError) as ctx:
            bss.validate(rows)
        self.assertIn("P2", str(ctx.exception))


class EndToEndTest(unittest.TestCase):
    def test_full_build_and_sort_order(self):
        with tempfile.TemporaryDirectory() as d:
            fq = os.path.join(d, "fastq")
            os.makedirs(fq)
            _make_fastqs(
                fq,
                [
                    "S000021_S12944Nr11.1.fastq.gz",
                    "S000021_S12944Nr11.2.fastq.gz",
                    "S000021_S12944Nr12.1.fastq.gz",
                    "S000021_S12944Nr12.2.fastq.gz",
                ],
            )
            decl = os.path.join(d, "decl.tsv")
            with open(decl, "w") as fh:
                fh.write(
                    "sample\tpatient\tlabel\n"
                    "S12944Nr11\tP11\ttumour\n"
                    "S12944Nr12\tP11\ttumour_adjacent\n"
                )
            out = os.path.join(d, "out.csv")
            rows = bss.build(fq, decl, out)
            # tumour (status 1) sorts before normal (status 0).
            self.assertEqual([r["sample"] for r in rows], ["S12944Nr11", "S12944Nr12"])
            with open(out) as fh:
                lines = [ln.rstrip("\n") for ln in fh]
            self.assertEqual(
                lines[0], "patient,sex,status,sample,lane,fastq_1,fastq_2"
            )
            self.assertEqual(len(lines), 3)  # header + 2
            self.assertTrue(lines[1].startswith("P11,NA,1,S12944Nr11,L001,"))
            self.assertTrue(lines[2].startswith("P11,NA,0,S12944Nr12,L001,"))
            self.assertIn(".fastq.gz", lines[1])


if __name__ == "__main__":
    unittest.main()
