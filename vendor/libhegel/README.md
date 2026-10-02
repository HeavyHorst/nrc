# libhegel test dependency and notices

The current source tree does not include a libhegel binary. Test runners download
the pinned 0.33.3 Linux amd64 release directly from upstream, verify its SHA256
and cache it under `.hegel/libhegel-0.33.3/`. Run `test/fetch_libhegel.sh` to prepare
the cache without compiling tests. The server does not use Hegel.

The binaries in the table below remain reachable through the full development
history retained on Amp, not the single-commit GitHub snapshot. This directory
retains their collected notices. Hegel publishes an [MIT grant](0.33.3/LICENSE),
but incorporated material has separate terms and the native-source licensing
question below remains unresolved. Do not treat the collection as complete
redistribution clearance.

| Hegel release | Binary SHA256 | Rust runtime |
| --- | --- | --- |
| [0.33.3](https://github.com/hegeldev/hegel-rust/releases/tag/v0.33.3) | `1ceb1636f3dd8e939fef88e99e3417b9da23675c7847e4cb22717ca8834c699b` | [Rust 1.98.0 notices](RUST_1.98.0_NOTICES.html) |
| [0.23.2](https://github.com/hegeldev/hegel-rust/releases/tag/v0.23.2) | `7facb737e45fb210f47a70a51b86b6d58f2367f911aea81c2b75e8e58189e818` | [Rust 1.96.0 notices](RUST_1.96.0_NOTICES.html) |

## Crates

[DEPENDENCY_NOTICES.md](DEPENDENCY_NOTICES.md) preserves the licenses, copyright
notices and attribution files collected from 140 crates.io archives. Every archive
was checked against its SHA256 in the tagged Hegel or matching Rust lockfiles:
[0.33.3](https://github.com/hegeldev/hegel-rust/blob/v0.33.3/Cargo.lock) and
[0.23.2](https://github.com/hegeldev/hegel-rust/blob/v0.23.2/Cargo.lock), plus
[Rust 1.98.0](https://github.com/rust-lang/rust/blob/88d9e12ae178fab0fb5cc050a94da85685d449ea/library/Cargo.lock)
and [Rust 1.96.0](https://github.com/rust-lang/rust/blob/ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96/library/Cargo.lock).

The collection covers the conservative dependency closures: 60 crates for 0.33.3
and 96 for 0.23.2, plus 30 and 40 registry crates in the matching Rust
standard-library lockfiles, with overlap. It includes optional features, other
targets and build tools, not just code incorporated into Linux binaries.
MPL-2.0 `cbindgen` is a build dependency in Hegel 0.23.2; `fortanix-sgx-abi`
is for Rust's separate SGX target, not these GNU/Linux binaries. Their presence
in the notice collection does not make Hegel's GNU/Linux runtime MPL-licensed.
Preserve copyright notices and additional terms such as Unicode's data license;
where licenses offer a choice, the permissive alternatives remain available.

Some crates omit monorepo license files. Their notices were recovered from the
archive-recorded upstream revisions. For `dashu-base` 0.4.1, that revision was
unavailable; the full texts come from a surviving upstream commit explicitly
releasing the same crate version. This exception is recorded in the collection.
The non-Linux `vex-sdk` archive records a dirty upstream working tree; its license
was recovered at the recorded revision without asserting exact tree identity.
These provenance limits do not change the published crates' license declarations.

## Native source provenance

Hegel's [statistics module](https://github.com/hegeldev/hegel-rust/blob/v0.33.3/hegel-c/src/native/statistics.rs)
labels functions as ports of `hypothesis.internal.statistics`. The compared
[Hypothesis source](https://github.com/HypothesisWorks/hypothesis/blob/c1836416f2c1c0970c8f9b042d040570cb1e4dff/hypothesis-python/src/hypothesis/internal/statistics.py)
has an MPL-2.0 header. The comparison revision is not a proven exact import
revision. The Cargo archive collection does not cover code incorporated directly
into Hegel's own source. Separate permission may exist; its basis and any required
notices or source provision have not been established here. Clarify this before
redistributing a Hegel binary. Downloading it for local tests does not establish
redistribution rights or remove the copies in NRC's Git history.

## Rust runtime

The runtime versions were identified from `/rustc/<commit>` paths embedded in
each binary and matched to official Rust release manifests. The notice files are
unmodified `COPYRIGHT-library.html` files from the corresponding official compiler
distributions, including the standard library's own embedded dependencies.

| Rust release | Embedded commit | Official compiler archive SHA256 |
| --- | --- | --- |
| [1.98.0](https://static.rust-lang.org/dist/2026-08-20/rustc-1.98.0-x86_64-unknown-linux-gnu.tar.xz) | `88d9e12ae178fab0fb5cc050a94da85685d449ea` | `0e37cb339f447fc44d6d781073bacacebfdc5612f2600e4c7e84c266f5f3aced` |
| [1.96.0](https://static.rust-lang.org/dist/2026-05-28/rustc-1.96.0-x86_64-unknown-linux-gnu.tar.xz) | `ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96` | `7d7fa1d0cfb0fab71a956bb78f41107202c17f30ab56c45288e869a37fd9633d` |

## Unicode data and system libraries

Both Hegel releases embed category and normalization tables derived from the
[Unicode 15.1.0 Character Database](https://www.unicode.org/Public/15.1.0/ucd/ReadMe.txt),
copyright 2023 Unicode, Inc. These are transformed tables, not unchanged UCD files.
The [Unicode License V3](UNICODE-LICENSE.txt), retrieved 2026-10-02, is included.
Unicode's [current terms, section 3.3](https://www.unicode.org/terms_of_use.html)
apply that license to its data files unless a specific exception is identified.

The binaries dynamically depend on system libraries including glibc and
`libgcc_s`; these libraries are not included in this directory. If you
package them in an image or bundle, their redistribution obligations apply too.

This is a source-based notice collection checked against binary-visible version
markers, not an exact SBOM of every object linked into the upstream artifacts.
It does not cover NRC's other binaries, the Search model or container images.
