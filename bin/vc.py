#!/usr/bin/env python3
"""vc — the whole variant-caller CLI: build the target BED, check a samplesheet, run sarek.

Three subcommands, one file, one language:

    vc.py bed    --out references/target_pad30.bed --fai references/*.fasta.fai
    vc.py sheet  assets/samplesheet_pilot.csv
    vc.py run    [--params params/pilot.yaml]

Everything sarek or bedtools can do is delegated to them. What is left is the four
things measured to have no published equivalent, each marked WHY below.

Requires: bedtools + pybedtools, and (for `run`) nextflow + docker.
    mamba install -c conda-forge -c bioconda bedtools pybedtools
"""
import argparse
import base64
import csv
import hashlib
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TWIST = "https://www.twistbioscience.com/content/dam/twistbioscience/resources"
KIT = {  # the kit is "Twist Human Core Exome + RefSeq + Mitochondrial Panel" (report p.3).
    "refseq": f"{TWIST}/2019-09/Twist_Exome_RefSeq_targets_hg38.bed",
    "mito": f"{TWIST}/2020-04/Twist_MitoPanel_chrM_all_hg38_target.bed",
}
COLUMNS = ["patient", "sex", "status", "sample", "lane", "fastq_1", "fastq_2"]


def die(msg):
    sys.exit(f"ERROR: {msg}")


def _bt():
    try:
        import pybedtools
    except ImportError:
        die("pybedtools is required: mamba install -c conda-forge -c bioconda bedtools pybedtools")
    if not shutil.which("bedtools"):
        die("the bedtools binary is required: mamba install -c bioconda bedtools")
    return pybedtools


# --------------------------------------------------------------------------- bed
def is_canonical(bed, fai):
    """A legal sarek --intervals BED is a FIXED POINT of sort|merge|slop-0.

    WHY OURS: nothing published performs this check. Measured on the file that killed a
    run in CALCULATECONTAMINATION after 29m46s: `gatk BedToIntervalList` exits 0 and
    silently writes a reordered copy, and `nextflow run -preview` reports success in
    30.4 s. Running the file through bedtools' own pipeline and seeing whether anything
    changed rejects it — along with 6-column BEDs (which sarek reads as runtime estimates:
    107,247 shards instead of 83), out-of-bounds ends, unmerged overlaps, duplicate and
    book-ended rows, unknown contigs, negative starts and space-delimited input.
    KNOWN GAP: a zero-length interval passes here; the builder cannot produce one and GATK
    rejects it loudly in the first interval task, so it is not a silent failure.
    """
    pybedtools = _bt()
    b = pybedtools.BedTool(str(bed))
    try:
        return str(b) == str(b.sort(faidx=str(fai)).merge().slop(g=str(fai), b=0))
    except Exception as e:
        # Anything that cannot even be parsed or sorted is, by definition, not canonical.
        # bedtools raises BEDToolsError for a contig absent from the .fai (its message names
        # the contig, worth surfacing); pybedtools raises IndexError on a space-delimited or
        # otherwise malformed row, where the bedtools CLI would exit non-zero.
        print(str(e).strip().splitlines()[-1], file=sys.stderr)
        return False


def _fetch(url, dest):
    """Download a vendor BED and verify it against the Content-MD5 the CDN publishes."""
    with urllib.request.urlopen(url, timeout=180) as r:
        body, want = r.read(), r.headers.get("Content-MD5")
    if not body:
        die(f"downloaded an empty file from {url}")
    got = hashlib.md5(body).hexdigest()
    if want and bytes.fromhex(got) != base64.b64decode(want):
        die(f"md5 mismatch for {url} (got {got}) — the kit file changed")
    dest.write_bytes(body)


def cmd_bed(a):
    pybedtools = _bt()
    work = Path(pybedtools.helpers.get_tempdir())
    refseq = Path(a.refseq) if a.refseq else work / "refseq.bed"
    mito = Path(a.mito) if a.mito else work / "mito.bed"
    if not a.refseq:
        _fetch(KIT["refseq"], refseq)
    if not a.mito:
        _fetch(KIT["mito"], mito)

    # cat  = union of two DISJOINT files (refseq has 24 contigs and no chrM)
    # sort = REFERENCE contig order, not lexicographic — the flag whose absence cost a run
    # slop = pad, CLAMPED to contig lengths from the .fai (chrM would otherwise exceed its
    #        16,569 bp and GATK rejects out-of-bounds intervals)
    # merge= padding fuses 1,130 neighbouring targets that sit 1-60 bp apart
    out = (pybedtools.BedTool(str(refseq))
           .cat(str(mito), postmerge=False)
           .sort(faidx=str(a.fai)).merge()
           .slop(g=str(a.fai), b=a.pad).merge())

    n = out.count()
    bp = sum(len(f) for f in out)
    if n < a.min_regions:  # an empty or truncated BED passes every other check
        die(f"only {n} regions (expected >= {a.min_regions}); the vendor files look wrong")
    tmp = out.saveas()
    if not is_canonical(tmp.fn, a.fai):
        die(f"refusing to write {a.out}: the result is not a canonical intervals BED")
    shutil.move(tmp.fn, a.out)
    print(f"wrote {a.out} — {n} regions / {bp} bp (pad {a.pad}, order from {Path(a.fai).name})",
          file=sys.stderr)


# ------------------------------------------------------------------------- sheet
def check_sheet(path):
    """The three things sarek does NOT enforce. Returns a list of error strings.

    WHY OURS, all measured: (1) tumour-only is legal and SILENT — mutect2 is absent from
    sarek's `tools_requiring_normal_samples`, so a patient with no status=0 row completes
    and yields a non-paired VCF; (2) `status: 1.00` parses as a BigDecimal and previews
    clean, and an ABSENT status column defaults every row to 0; (3) a missing fastq_2 runs
    that sample single-end. csvtk/mlr can compute the tally but cannot fail on it, and
    PEP/eido validated a tumour-only sheet as "Validation successful".
    """
    errs, tum, nor = [], {}, {}
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)          # handles quoting, CRLF and column order
        missing = [c for c in COLUMNS if c not in (reader.fieldnames or [])]
        if missing:
            return [f"missing column(s): {', '.join(missing)}"]
        for i, row in enumerate(reader, start=2):
            if all((v or "").strip() == "" for v in row.values()):
                continue
            for c in COLUMNS:
                if not (row[c] or "").strip():
                    errs.append(f"line {i}: {c} is empty — v1 is paired-end, fastq_2 included")
            if row["status"] not in ("0", "1"):
                errs.append(f'line {i}: status is "{row["status"]}", must be exactly 0 or 1')
                continue
            (tum if row["status"] == "1" else nor).setdefault(row["patient"], []).append(row["sample"])
    if not (tum or nor):
        errs.append("no data rows")
    for p in sorted(set(tum) | set(nor)):
        if len(nor.get(p, [])) != 1:
            errs.append(f"patient {p}: {len(nor.get(p, []))} status=0 rows, need exactly ONE "
                        f"(v1 has no tumour-only and no normal-selection mode)")
        if not tum.get(p):
            errs.append(f"patient {p}: 0 status=1 rows, need at least one tumour")
    return errs


def _require_valid_sheet(path, hint=""):
    errs = check_sheet(path)
    for e in errs:
        print(e, file=sys.stderr)
    if errs:
        die(f"{path} is not a valid v1 samplesheet{hint}")


def cmd_sheet(a):
    _require_valid_sheet(a.samplesheet)
    print(f"{a.samplesheet}: OK", file=sys.stderr)


# --------------------------------------------------------------------------- run
def _params(path):
    import yaml  # only `run` needs it, so a box that just builds a BED does not
    return yaml.safe_load(Path(path).read_text())


def cmd_run(a):
    os.chdir(REPO)   # -resume and every relative path in the params file resolve from here
    ref = Path("references")

    # (1) Nextflow performs NO container-engine check: measured, a full -preview emits zero
    #     `docker run` lines, so a dead daemon surfaces only at the first task.
    if subprocess.run(["docker", "info"], capture_output=True).returncode:
        die("docker is not usable (daemon down, or this user is not in the 'docker' group)")
    # (2) Image LAYERS land on /var/lib/containerd, not on docker's data-root: docker 29.x
    #     uses the containerd snapshotter. Two runs died here after 2h46m59s and 44m17s.
    free_gb = shutil.disk_usage(a.layer_dir).free // 2**30
    if free_gb < a.min_layer_gb:
        die(f"only {free_gb}G free on {a.layer_dir}; the 7 container pulls need >= {a.min_layer_gb}G.\n"
            "       Reclaim with: docker container prune -f && docker image prune -a -f")
    # (3) germline_resource is the ONLY Mutect2 reference param with no "exists" in sarek's
    #     schema, and without it sarek publishes the UNFILTERED VCF with no error.
    for f in ("af-only-gnomad.hg38.vcf.gz", "af-only-gnomad.hg38.vcf.gz.tbi"):
        if not (ref / f).is_file():
            die(f"missing {ref / f} — see docs/inputs.md")
    # (4) the intervals contract, on whatever BED is actually on disk
    if not is_canonical(ref / "target_pad30.bed", ref / "Homo_sapiens_assembly38.fasta.fai"):
        die("the intervals BED is not canonical. Rebuild it: bin/vc.py bed "
            f"--out {ref}/target_pad30.bed --fai {ref}/Homo_sapiens_assembly38.fasta.fai")
    # (5) the tumour/normal semantics sarek does not police
    params = _params(a.params)
    sheet = params["input"]
    _require_valid_sheet(sheet, " (template: assets/samplesheet_template.csv)")

    # NOTHING can detect a swapped status — not this script, not sarek, not assert_output.py
    # (a swap still yields a _vs_ file with two correctly-named columns). Print it so the
    # error is visible rather than invisible.
    with open(sheet, newline="") as fh:
        rows = list(csv.DictReader(fh))
    print("Samplesheet pairing (1 = tumour, 0 = normal):", file=sys.stderr)
    for r in rows:
        print(f"  {r['patient']:<6} {r['sample']:<14} status {r['status']}", file=sys.stderr)

    subprocess.run(["nextflow", "run", str(a.sarek), "-profile", "docker",
                    "-c", "nextflow.config", "-params-file", str(a.params),
                    "-w", "work", "-resume"], check=True)

    outdir = Path(params["outdir"])
    name = f"{a.tumour}_vs_{a.normal}.mutect2.filtered.vcf.gz"
    # Searching by the '_vs_' name is itself a check: a tumour-only run produces no such file.
    hits = list((outdir / "variant_calling").rglob(name))
    if not hits:
        die(f"expected {name} under {outdir}/variant_calling — not found.\n"
            "       A run that silently routed to tumour-only mode produces no '_vs_' file.")
    # sarek names the FILE from the bare sample ids but the VCF's genotype columns from the
    # read group SM:<patient>_<sample>. Both are needed; passing the bare ids fails a good run.
    patient = rows[0]["patient"]
    subprocess.run([sys.executable, str(REPO / "bin" / "assert_output.py"),
                    "--tumour", f"{patient}_{a.tumour}", "--normal", f"{patient}_{a.normal}",
                    str(hits[0])], check=True)


# --------------------------------------------------------------------------- cli
def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("bed", help="build the target BED from the kit vendor's files")
    b.add_argument("--out", required=True)
    b.add_argument("--fai", required=True, help="reference .fasta.fai: contig ORDER and LENGTHS")
    b.add_argument("--refseq")
    b.add_argument("--mito")
    b.add_argument("--pad", type=int, default=30, help="CeGaT's own DRAGEN setting")
    b.add_argument("--min-regions", type=int, default=200_000)
    b.set_defaults(func=cmd_bed)

    s = sub.add_parser("sheet", help="validate a samplesheet")
    s.add_argument("samplesheet")
    s.set_defaults(func=cmd_sheet)

    r = sub.add_parser("run", help="preflight, launch sarek, assert the output")
    r.add_argument("--params", default="params/pilot.yaml")
    r.add_argument("--sarek", default=REPO.parent / "sarek")
    r.add_argument("--tumour", default="S12944Nr11")
    r.add_argument("--normal", default="S12944Nr12")
    r.add_argument("--layer-dir", default="/var/lib/containerd")
    r.add_argument("--min-layer-gb", type=int, default=30)
    r.set_defaults(func=cmd_run)

    a = p.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
