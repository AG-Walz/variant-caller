#!/usr/bin/env bash
# Copy this file, edit the four paths below, run it from the directory they are relative to.
# Add -preview to validate every path in ~40 s without launching a task.
#
# The three --flags are the settings that change per cohort. Everything else is tuned and
# explained in params/run.yaml; CLI beats -params-file beats nextflow.config, so a flag you
# add here wins over the file.

# sarek's config includes an nf-core config over https, fetched by the JVM, which prefers
# IPv4. On an IPv6-only host that fetch fails and takes the run with it. NXF_OFFLINE=true
# is not an alternative: it skips the include, then fails schema validation.
export NXF_OPTS="-Djava.net.preferIPv6Addresses=true"

nextflow run ../sarek \
  -profile docker \
  -c nextflow.config \
  -params-file params/run.yaml \
  -resume \
  --input assets/samplesheet_pilot.csv \
  --outdir results \
  --intervals references/target_pad30.bed \
  "$@"   # anything you add on the command line, e.g. -preview
