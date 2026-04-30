# TODO

## P0 - clean clone works

- [x] Make `make build` clone the required `llama.cpp` checkouts when `vendor/` is empty.
- [x] Ensure every target that redirects into `logs/` creates that directory first.
- [x] Add a lightweight setup check that reports missing command-line tools, models, and builds.
- [x] Keep privacy scans green before every public push.

## P1 - public user experience

- [x] Tighten README quickstart so a new user understands online vs offline steps.
- [x] Remove local-machine-only references from docs and replace them with generic examples.
- [x] Add a short requirements section for macOS, Xcode command line tools, CMake, Git, curl, jq, and Python 3.
- [x] Document how to use model paths directly when LM Studio is not installed.

## P2 - validation

- [x] Add a non-model shell test that runs `bash -n` over scripts and checks Makefile help.
- [ ] Add a dry-run mode for model symlinking and startup preflight.
- [ ] Add a CI workflow for static checks that does not download models or build large dependencies.

## P3 - release hygiene

- [ ] Add a license after choosing the intended license.
- [ ] Add a changelog or release notes for `v0.0.1`.
- [ ] Decide whether raw benchmark text outputs should stay tracked or move to generated artifacts.
- [ ] Add contribution notes for model path changes and benchmark submissions.
