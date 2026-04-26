# Changelog

## [1.3.0](https://github.com/hoobio/pipeline-tools/compare/v1.2.0...v1.3.0) (2026-04-26)


### Features

* WiX 5 MSI build and sign helpers ([#10](https://github.com/hoobio/pipeline-tools/issues/10)) ([92facc7](https://github.com/hoobio/pipeline-tools/commit/92facc7a33ce037c5e6ded0bfc2dd3869d8cfbba))

## [1.2.0](https://github.com/hoobio/pipeline-tools/compare/v1.1.0...v1.2.0) (2026-04-26)


### Features

* **run-wack:** add fail-on-error input as preferred name ([#8](https://github.com/hoobio/pipeline-tools/issues/8)) ([2e49f24](https://github.com/hoobio/pipeline-tools/commit/2e49f24297bb793d3f923ff9432e2892006772a7))

## [1.1.0](https://github.com/hoobio/pipeline-tools/compare/v1.0.2...v1.1.0) (2026-04-26)


### Features

* release-please, MSIX build/sign, WACK, and publish-github-release helpers ([#6](https://github.com/hoobio/pipeline-tools/issues/6)) ([d3da483](https://github.com/hoobio/pipeline-tools/commit/d3da483d1b8349ecde672b6208d9e2854ecbba7c))

## [1.0.2](https://github.com/hoobio/pipeline-tools/compare/v1.0.1...v1.0.2) (2026-04-26)


### Bug Fixes

* **actions:** scrub `github` context references from upload-to-github-release manifest ([a0b9487](https://github.com/hoobio/pipeline-tools/commit/a0b94878da0f8adf88d6fd9ddc50f8d2bab70a1c))

## [1.0.1](https://github.com/hoobio/pipeline-tools/compare/v1.0.0...v1.0.1) (2026-04-26)


### Bug Fixes

* **actions:** require explicit github-token input on upload-to-github-release ([e299794](https://github.com/hoobio/pipeline-tools/commit/e299794181ca471e936ec737fbf66cd3ac9fca56))

## 1.0.0 (2026-04-26)


### Features

* expose masked DT upload-token, optional BOM-processing wait, generic github-release step ([4c117dc](https://github.com/hoobio/pipeline-tools/commit/4c117dc5829242250ae47946f2de9a85709e0e0f))
* initial scaffold with Dependency-Track upload templates and scripts ([5083056](https://github.com/hoobio/pipeline-tools/commit/5083056e6d2960ddf46ec17bf6c201d4504f9dbd))


### Bug Fixes

* **scripts:** replace empty catch block in DT REST helper ([413aae3](https://github.com/hoobio/pipeline-tools/commit/413aae3cf5866cd943582e41042f0e06a42a764a))


### Code Refactoring

* **actions:** drop SBOM generation from the upload-sbom job action ([6bb1b35](https://github.com/hoobio/pipeline-tools/commit/6bb1b35d5110adc6b3f6946ec06310e0233c4e37))


### Continuous Integration

* configure release-please and Conventional-Commits PR title enforcement ([408d556](https://github.com/hoobio/pipeline-tools/commit/408d556add5f056b2e0defb7180e239199ac172e))


### Miscellaneous Chores

* **deps:** bump actions/checkout from 5 to 6 ([#1](https://github.com/hoobio/pipeline-tools/issues/1)) ([f4a99bd](https://github.com/hoobio/pipeline-tools/commit/f4a99bde97b0ff15aa130778f8740aab83fb3f46))
* **deps:** bump actions/upload-artifact from 5 to 7 in /pipeline/github/job/upload-sbom-to-dependency-track ([#2](https://github.com/hoobio/pipeline-tools/issues/2)) ([c8a4ad7](https://github.com/hoobio/pipeline-tools/commit/c8a4ad792a1aa4043378ba7521c5befde9c0da34))
