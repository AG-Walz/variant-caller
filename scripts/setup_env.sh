#!/usr/bin/env bash
#
# setup_env.sh — one-time environment bootstrap for a fresh box.
# ------------------------------------------------------------------
# Puts in place the two things this repo cannot function without and can
# install without root:
#
#   1. the sibling nf-core/sarek clone at tag 3.9.0 (run_pilot.sh resolves it
#      as ../sarek, by path -- this repo wraps sarek, it does not vendor it);
#   2. Nextflow, at the version sarek 3.9.0 hard-requires.
#
# It deliberately does NOT install Java or Docker. Both are system packages
# needing root and a policy decision on a shared box, so this script detects
# them and tells you the command to run instead of running it for you.
#
# Idempotent: safe to re-run. Anything already correct is left alone.
#
# Verify the result with:  tests/check_environment.sh
#
# Override via the environment:
#   SAREK_REF=3.9.0                 tag/branch of nf-core/sarek to check out
#   SAREK_DIR=../sarek              where the clone goes
#   PREFIX=$HOME/.local/bin         where the nextflow launcher is installed
#   SKIP_SAREK=1 / SKIP_NEXTFLOW=1  skip either half

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SAREK_REF="${SAREK_REF:-3.9.0}"
SAREK_URL="${SAREK_URL:-https://github.com/nf-core/sarek.git}"
SAREK_DIR="${SAREK_DIR:-${REPO_DIR}/../sarek}"
PREFIX="${PREFIX:-$HOME/.local/bin}"

# sarek 3.9.0 pins `nextflowVersion = '!>=25.10.2'` -- the '!' makes a lower
# version a hard launch failure, not a warning. Nextflow 25.10 needs Java 17+.
MIN_NEXTFLOW="25.10.2"
MIN_JAVA_MAJOR=17

info() { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '    \033[33mNOTE\033[0m  %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Return 0 if $1 >= $2, comparing dotted version strings.
version_ge() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

java_major() {
    # "openjdk version \"17.0.11\"" -> 17 ; "1.8.0_402" -> 8
    local raw
    raw="$(java -version 2>&1 | head -n1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
    [ -n "$raw" ] || return 1
    case "$raw" in
        1.*) printf '%s\n' "$raw" | cut -d. -f2 ;;
        *)   printf '%s\n' "$raw" | cut -d. -f1 ;;
    esac
}

nextflow_version() {
    # "nextflow version 25.10.2.5972" -> 25.10.2.5972
    nextflow -v 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n1
}

# --- 1. Java (detect only) ------------------------------------------------
info "Checking Java (needed by Nextflow ${MIN_NEXTFLOW}+; not installed by this script)"
if command -v java >/dev/null 2>&1 && major="$(java_major)" && [ -n "$major" ]; then
    if [ "$major" -ge "$MIN_JAVA_MAJOR" ]; then
        ok "java ${major} (>= ${MIN_JAVA_MAJOR})"
    else
        die "java ${major} is too old; Nextflow ${MIN_NEXTFLOW} needs Java ${MIN_JAVA_MAJOR}+.
       Debian/Ubuntu:  sudo apt-get update && sudo apt-get install -y openjdk-17-jre-headless
       RHEL/CentOS:    sudo yum install -y java-17-openjdk-headless
       Then re-run this script."
    fi
else
    die "java not found. Nextflow ${MIN_NEXTFLOW} needs Java ${MIN_JAVA_MAJOR}+.
       Debian/Ubuntu:  sudo apt-get update && sudo apt-get install -y openjdk-17-jre-headless
       RHEL/CentOS:    sudo yum install -y java-17-openjdk-headless
       Then re-run this script."
fi

# --- 2. Docker (detect only) ----------------------------------------------
info "Checking Docker (the pilot runs with -profile docker; not installed by this script)"
if ! command -v docker >/dev/null 2>&1; then
    warn "docker is NOT on PATH. Install the Docker engine before running the pipeline."
elif ! docker info >/dev/null 2>&1; then
    warn "docker is installed but not usable by this user (daemon down, or you are not in the
          'docker' group). 'docker ps' must work WITHOUT sudo before the pipeline can run."
else
    ok "docker usable by this user"
fi

# --- 3. The sibling sarek clone -------------------------------------------
if [ "${SKIP_SAREK:-0}" = "1" ]; then
    info "Skipping sarek clone (SKIP_SAREK=1)"
elif [ -d "$SAREK_DIR/.git" ]; then
    info "sarek clone already present at $SAREK_DIR"
    have="$(git -C "$SAREK_DIR" describe --tags --always 2>/dev/null || echo unknown)"
    if [ "$have" = "$SAREK_REF" ]; then
        ok "checked out at ${SAREK_REF}"
    else
        warn "checked out at '${have}', not '${SAREK_REF}'. Left untouched -- this clone may be
          deliberately modified. To move it yourself:  git -C '$SAREK_DIR' checkout ${SAREK_REF}"
    fi
    if [ -n "$(git -C "$SAREK_DIR" status --porcelain 2>/dev/null)" ]; then
        warn "the clone has local modifications; the pipeline you run is NOT stock ${SAREK_REF}."
    fi
else
    [ ! -e "$SAREK_DIR" ] || die "$SAREK_DIR exists but is not a git clone. Move it aside first."
    info "Cloning nf-core/sarek ${SAREK_REF} -> $SAREK_DIR"
    command -v git >/dev/null 2>&1 || die "git is not installed."
    git clone "$SAREK_URL" "$SAREK_DIR"
    git -C "$SAREK_DIR" checkout --quiet "$SAREK_REF"
    ok "cloned and checked out at $(git -C "$SAREK_DIR" describe --tags --always)"
fi

# --- 4. Nextflow ----------------------------------------------------------
if [ "${SKIP_NEXTFLOW:-0}" = "1" ]; then
    info "Skipping Nextflow install (SKIP_NEXTFLOW=1)"
else
    info "Checking Nextflow (sarek ${SAREK_REF} requires >= ${MIN_NEXTFLOW})"
    current=""
    command -v nextflow >/dev/null 2>&1 && current="$(nextflow_version || true)"

    if [ -n "$current" ] && version_ge "$current" "$MIN_NEXTFLOW"; then
        ok "nextflow ${current} at $(command -v nextflow)"
    else
        if [ -n "$current" ]; then
            info "nextflow ${current} is older than ${MIN_NEXTFLOW}; installing a current one"
        else
            info "nextflow not found; installing"
        fi
        command -v curl >/dev/null 2>&1 || die "curl is required to download Nextflow."
        mkdir -p "$PREFIX"
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        ( cd "$tmp" && curl -fsSL https://get.nextflow.io | bash >/dev/null )
        [ -f "$tmp/nextflow" ] || die "the Nextflow installer did not produce a launcher."
        install -m 0755 "$tmp/nextflow" "$PREFIX/nextflow"
        ok "installed -> $PREFIX/nextflow"

        case ":${PATH}:" in
            *":${PREFIX}:"*) : ;;
            *) warn "$PREFIX is not on your PATH. Add it:
          echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
        esac

        installed="$("$PREFIX/nextflow" -v 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n1)"
        [ -n "$installed" ] && version_ge "$installed" "$MIN_NEXTFLOW" \
            && ok "nextflow ${installed} (>= ${MIN_NEXTFLOW})" \
            || warn "installed Nextflow reports '${installed:-unknown}'; verify it is >= ${MIN_NEXTFLOW}."
    fi
fi

# --- Done -----------------------------------------------------------------
cat <<EOF

Bootstrap complete. Verify everything, including what this script does not install:

    tests/check_environment.sh

Then the per-box data steps (none of them are in git):

    scripts/fetch_references.sh
    bin/build_target_bed.sh <counts.gc-corrected.gz> references/target_pad30.bed
    bin/build_samplesheet.py --declarations assets/pilot_declarations.tsv \\
        --fastq-dir <FASTQ dir on this box> --out assets/samplesheet_pilot.csv

Full runbook: docs/steps.md
EOF
