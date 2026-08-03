#!/usr/bin/env bash
# Copy this file, edit the paths, run it from the directory those paths are relative to.
# What each parameter means and why it is set that way: params/pilot.yaml.
# Add -preview to validate every path in ~40 s without launching a task.

# sarek's config includes an nf-core config over https, fetched by the JVM, which prefers
# IPv4. On an IPv6-only host that fetch fails and takes the run with it. NXF_OFFLINE=true
# is not an alternative: it skips the include, then fails schema validation.
export NXF_OPTS="-Djava.net.preferIPv6Addresses=true"

nextflow run ../sarek \
  -profile docker \
  -c nextflow.config \
  -params-file params/pilot.yaml \
  -resume \
  "$@"   # anything you add on the command line, e.g. -preview
