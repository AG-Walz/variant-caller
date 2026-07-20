# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing released yet. The pipeline is in design; this repository currently holds
documentation only.

### Added

- Initial repository scaffold: `README.md`, `CHANGELOG.md`, `.gitignore`.
- User-facing documentation under `docs/`: introduction, inputs, usage, output.

### Notes

- Scope is deliberately narrow: **sequencing reads in, raw somatic VCF out.**
  Filtering, normalisation, VEP annotation and peptide generation are handled by
  [nf-core/epitopeprediction](https://github.com/nf-core/epitopeprediction) and are
  not duplicated here.
- Sample labels are `tumour`, `control_healthy`, `control_benign`, `tumour_adjacent`.
