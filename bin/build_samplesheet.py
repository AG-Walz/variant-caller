#!/usr/bin/env python3
"""Build a nf-core/sarek samplesheet from discovered FASTQs + declared labels.

variant-caller v1 (paired somatic only). Pure python3 stdlib (no pandas).

Pipeline:
  1. Discover *.fastq.gz in --fastq-dir and pair R1/R2 by mate token
     (.1/.2 ; _R1/_R2 ; _1/_2) into one sample each. Sample id is derived by
     stripping the order prefix (default 'S000021_') and the mate token.
  2. Join to --declarations (TSV: sample<TAB>patient<TAB>label).
  3. Validate label against the 4-value enum, downcast label -> status
     (tumour -> 1, else 0).
  4. Enforce the four v1 validator rules (each names the offending sample/patient).
  5. Write the sarek CSV: patient,sex,status,sample,lane,fastq_1,fastq_2
     (sex=NA, lane=L001, absolute FASTQ paths, deterministic sort).

Importable: discover_pairs, load_declarations, build_rows, validate.
"""

import argparse
import csv
import os
import re
import sys

DEFAULT_ORDER_PREFIX = "S000021_"

# Declared labels and their downcast to sarek's binary status.
# tumour -> 1 ; everything else -> 0.
VALID_LABELS = {
    "tumour": 1,
    "tumour_adjacent": 0,
    "control_healthy": 0,
    "control_benign": 0,
}

FASTQ_SUFFIX = ".fastq.gz"

# Mate-token matchers, tried in order. Each captures (base, mate) where mate is
# '1' or '2'. _R form is tried before the bare _ form so that "_R1" is not
# mis-parsed. The dot form ('.1'/'.2') is the UrCa convention.
_MATE_PATTERNS = (
    re.compile(r"^(?P<base>.+)_R(?P<mate>[12])$"),
    re.compile(r"^(?P<base>.+)\.(?P<mate>[12])$"),
    re.compile(r"^(?P<base>.+)_(?P<mate>[12])$"),
)

CSV_HEADER = ["patient", "sex", "status", "sample", "lane", "fastq_1", "fastq_2"]
SEX = "NA"
LANE = "L001"


class BuildError(Exception):
    """Raised for any discovery/validation failure. Message names the culprit."""


def _split_mate(stem):
    """Return (base, mate) for a filename stem (no .fastq.gz), or None."""
    for pat in _MATE_PATTERNS:
        m = pat.match(stem)
        if m:
            return m.group("base"), m.group("mate")
    return None


def _derive_sample_id(base, order_prefix):
    """Strip the order prefix from a paired base to get the sample id."""
    if order_prefix and base.startswith(order_prefix):
        return base[len(order_prefix):]
    return base


def discover_pairs(fastq_dir, order_prefix=DEFAULT_ORDER_PREFIX):
    """Discover *.fastq.gz in fastq_dir and pair R1/R2 into samples.

    Returns dict: sample_id -> {"fastq_1": abspath_R1, "fastq_2": abspath_R2}.
    Raises BuildError on an unpaired R1 or R2, or a duplicate mate.
    """
    if not os.path.isdir(fastq_dir):
        raise BuildError("fastq-dir does not exist or is not a directory: %s" % fastq_dir)

    # base -> {mate -> abspath}
    grouped = {}
    for name in sorted(os.listdir(fastq_dir)):
        if not name.endswith(FASTQ_SUFFIX):
            continue
        stem = name[: -len(FASTQ_SUFFIX)]
        split = _split_mate(stem)
        if split is None:
            raise BuildError(
                "cannot determine R1/R2 mate token for FASTQ: %s "
                "(expected one of .1/.2, _R1/_R2, _1/_2)" % name
            )
        base, mate = split
        path = os.path.abspath(os.path.join(fastq_dir, name))
        slot = grouped.setdefault(base, {})
        if mate in slot:
            raise BuildError(
                "duplicate R%s FASTQ for base '%s': %s and %s"
                % (mate, base, os.path.basename(slot[mate]), name)
            )
        slot[mate] = path

    pairs = {}
    for base in sorted(grouped):
        mates = grouped[base]
        if "1" not in mates:
            raise BuildError(
                "unpaired FASTQ: R2 present but no R1 for base '%s' (%s)"
                % (base, os.path.basename(mates["2"]))
            )
        if "2" not in mates:
            raise BuildError(
                "unpaired FASTQ: R1 present but no R2 for base '%s' (%s)"
                % (base, os.path.basename(mates["1"]))
            )
        sample = _derive_sample_id(base, order_prefix)
        if sample in pairs:
            raise BuildError(
                "two FASTQ bases collapse to the same sample id '%s' after "
                "stripping order prefix '%s'" % (sample, order_prefix)
            )
        pairs[sample] = {"fastq_1": mates["1"], "fastq_2": mates["2"]}
    return pairs


def load_declarations(path):
    """Load a declarations TSV (sample<TAB>patient<TAB>label).

    An optional header row ('sample\\tpatient\\tlabel') is skipped. Blank lines
    and '#' comments are ignored. Returns dict: sample -> (patient, label).
    Raises BuildError on malformed rows or a duplicate sample.
    """
    if not os.path.isfile(path):
        raise BuildError("declarations file does not exist: %s" % path)

    decls = {}
    with open(path, newline="") as fh:
        for lineno, raw in enumerate(fh, start=1):
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 3:
                raise BuildError(
                    "declarations line %d is malformed (need 3 tab-separated "
                    "columns sample/patient/label): %r" % (lineno, line)
                )
            sample, patient, label = (f.strip() for f in fields[:3])
            if lineno == 1 and (sample, patient, label) == ("sample", "patient", "label"):
                continue  # header
            if not sample or not patient or not label:
                raise BuildError(
                    "declarations line %d has an empty field: %r" % (lineno, line)
                )
            if sample in decls:
                raise BuildError(
                    "declarations declares sample '%s' more than once" % sample
                )
            decls[sample] = (patient, label)
    if not decls:
        raise BuildError("declarations file has no usable rows: %s" % path)
    return decls


def build_rows(pairs, declarations):
    """Merge discovered pairs with declarations into sarek rows.

    For each declared sample: require FASTQs to exist, validate the label enum
    (rules 1 & 3 of the SPEC), and downcast label -> status (rule 4->status
    mapping). Discovered samples absent from declarations are ignored.

    Returns a list of row dicts (unsorted). Raises BuildError, naming the sample.
    """
    rows = []
    for sample in sorted(declarations):
        patient, label = declarations[sample]
        if label not in VALID_LABELS:
            raise BuildError(
                "sample '%s' has unknown label '%s' (allowed: %s)"
                % (sample, label, ", ".join(sorted(VALID_LABELS)))
            )
        if sample not in pairs:
            raise BuildError(
                "declared sample '%s' (patient '%s') has no FASTQ files in the "
                "fastq-dir" % (sample, patient)
            )
        status = VALID_LABELS[label]
        rows.append(
            {
                "patient": patient,
                "sex": SEX,
                "status": status,
                "sample": sample,
                "lane": LANE,
                "fastq_1": pairs[sample]["fastq_1"],
                "fastq_2": pairs[sample]["fastq_2"],
                "label": label,
            }
        )
    return rows


def validate(rows):
    """Enforce the four v1 patient-level validator rules.

    (2) exactly ONE status=0 row per patient (>1 = hard error);
    (3) at least one status=1 row per patient;
    (4) reject any patient with ZERO status=0 rows (v1 is paired-only).
    Rule (1)/label-enum is enforced in build_rows.

    Raises BuildError naming the offending patient. Returns rows unchanged.
    """
    if not rows:
        raise BuildError("no samples to validate (empty samplesheet)")

    by_patient = {}
    for row in rows:
        by_patient.setdefault(row["patient"], []).append(row)

    for patient in sorted(by_patient):
        prows = by_patient[patient]
        normals = [r["sample"] for r in prows if r["status"] == 0]
        tumours = [r["sample"] for r in prows if r["status"] == 1]

        # Rule 4: zero status=0 -> reject (paired-only, no tumour-only mode).
        if len(normals) == 0:
            raise BuildError(
                "patient '%s' has ZERO status=0 (normal/control) rows; v1 is "
                "PAIRED somatic only and has no tumour-only mode "
                "(tumour samples: %s)" % (patient, ", ".join(sorted(tumours)) or "none")
            )
        # Rule 2: more than one status=0 -> hard error (resolver is v2).
        if len(normals) > 1:
            raise BuildError(
                "patient '%s' has %d status=0 (normal/control) rows (samples: "
                "%s); exactly ONE is required in v1"
                % (patient, len(normals), ", ".join(sorted(normals)))
            )
        # Rule 3: at least one status=1 tumour.
        if len(tumours) == 0:
            raise BuildError(
                "patient '%s' has ZERO status=1 (tumour) rows; at least one is "
                "required (normal sample: %s)" % (patient, normals[0])
            )
    return rows


def _sort_key(row):
    # patient asc, then status desc (tumour=1 first), then sample asc.
    return (row["patient"], -int(row["status"]), row["sample"])


def write_csv(rows, out_path):
    """Write the sarek samplesheet CSV, deterministically sorted."""
    ordered = sorted(rows, key=_sort_key)
    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(CSV_HEADER)
        for row in ordered:
            writer.writerow(
                [
                    row["patient"],
                    row["sex"],
                    row["status"],
                    row["sample"],
                    row["lane"],
                    row["fastq_1"],
                    row["fastq_2"],
                ]
            )
    return ordered


def build(fastq_dir, declarations_path, out_path, order_prefix=DEFAULT_ORDER_PREFIX):
    """End-to-end build. Returns the written (sorted) rows."""
    pairs = discover_pairs(fastq_dir, order_prefix=order_prefix)
    decls = load_declarations(declarations_path)
    rows = build_rows(pairs, decls)
    validate(rows)
    return write_csv(rows, out_path)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build a nf-core/sarek samplesheet from FASTQs + declared labels."
    )
    parser.add_argument("--fastq-dir", required=True, help="directory of *.fastq.gz")
    parser.add_argument(
        "--declarations",
        required=True,
        help="TSV: sample<TAB>patient<TAB>label (optional header row)",
    )
    parser.add_argument("--out", required=True, help="output samplesheet CSV path")
    parser.add_argument(
        "--order-prefix",
        default=DEFAULT_ORDER_PREFIX,
        help="filename order prefix to strip (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    try:
        rows = build(args.fastq_dir, args.declarations, args.out, args.order_prefix)
    except BuildError as exc:
        parser.exit(status=2, message="ERROR: %s\n" % exc)

    sys.stderr.write(
        "wrote %d rows to %s (%d patient(s))\n"
        % (rows.__len__(), args.out, len({r["patient"] for r in rows}))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
