# Third-party components

The [MIT license](LICENSE) covers NRC's own code. It does not replace third-party
licenses or grant rights to model weights. Keep the applicable notices when
redistributing source, binaries or images.

## Included or adapted material

| NRC material | Source | License notice |
| --- | --- | --- |
| `btree/` Odin port | [tidwall/btree](https://github.com/tidwall/btree) | [MIT, Josh Baker](btree/LICENSE) |
| `vendor/tlsf/`, with growth-failure rollback | [Odin core/mem/tlsf, a2fb372](https://github.com/odin-lang/Odin/tree/a2fb372/core/mem/tlsf) | [BSD-3-Clause, Matthew Conte; port by Jeroen van Rijn](vendor/tlsf/LICENSE) |
| Unrolled encoding in `ulid/ulid.odin` | [RobThree/NUlid](https://github.com/RobThree/NUlid) | [MIT, Rob Janssen](ulid/NUlid-LICENSE) |
| Omarchy-derived palettes in `client/css/foundation.css` | [basecamp/omarchy](https://github.com/basecamp/omarchy) | [MIT, David Heinemeier Hansson](client/css/OMARCHY_LICENSE.txt) |
| `nbio/`, adapted for NRC | [laytan/odin-http at matching revision `b5b5492`](https://github.com/laytan/odin-http/tree/b5b5492b499f6f7fdf0909394f15cec930b22a02/nbio) | [MIT, Laytan Laats](nbio/LICENSE) |
| `spsc/`, based on RingBufferV5 | [CppPlayground ring buffer](https://github.com/david-alvarez-rosa/CppPlayground/blob/main/dsa/ring_buffer.cpp) | [MIT, David Álvarez Rosa](spsc/LICENSE) |

NRC's original `nbio` import predates Odin's later `core:nbio` package. The pinned
source above matches the original documentation and Linux ABI definitions; its
MIT notice applies to the imported code, not the later Odin package's license.

## Test-only Hegel dependency

Test runners download [libhegel 0.33.3](https://github.com/hegeldev/hegel-rust/releases/tag/v0.33.3)
directly from upstream into the ignored `.hegel/` cache. The current source tree
does not include its binary, and the NRC server does not require it. The full
development history retained on Amp contains the previously included 0.33.3 and
0.23.2 binaries; the single-commit GitHub snapshot does not.

Release digests and collected crate, Rust runtime and Unicode notices remain in
[vendor/libhegel](vendor/libhegel/README.md). That collection is not an exact
artifact SBOM or a complete licensing clearance: it also records the unresolved
Hypothesis source-port licensing question. If you redistribute Hegel in a bundle
or image, resolve that question and retain the applicable notices; Hegel's own
MIT notice alone does not cover all incorporated material.

## Fonts and fetched dependencies

Inter and IBM Plex Mono use the SIL Open Font License 1.1. The client build copies
their license files into `dist/licenses/`; keep those files with the generated
site. The Omarchy notice is also copied with `css/`.

Go and npm dependencies are recorded in each component's manifests and lockfiles.
They retain their upstream licenses. These include MIT, BSD, ISC and Apache-2.0
terms. If you distribute compiled binaries or bundle third-party browser scripts,
include the licenses and notices for the components actually included. The Go
manifests do not cover native libraries incorporated into Search.

## Search model and native libraries

The Search Dockerfile downloads
[EmbeddingGemma 2 ONNX weights](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX),
released under [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0),
not NRC's MIT license. Retain the applicable license and upstream notices when
redistributing model-containing images. See Google's
[model card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card_2) for
usage and safety guidance. The current Dockerfile is not a complete model
redistribution compliance bundle.

Search also incorporates the MIT-licensed `daulet/tokenizers` wrapper and native
tokenizer dependencies, including Apache-2.0 Hugging Face tokenizers. ONNX Runtime
uses MIT and ships additional
[third-party notices](https://github.com/microsoft/onnxruntime/blob/v1.24.1/ThirdPartyNotices.txt).
Retain the release's license and notice files, not just its shared libraries,
when packaging it. The full native dependency inventory remains to be verified.

## Container images

Base images and operating-system packages have their own licenses. In particular,
the proxy image includes Pandoc (GPL-2.0-or-later) and Typst (Apache-2.0) through
`pandoc/typst`. Redistributing that image requires the applicable notices and
corresponding-source compliance for its copyleft components. Running Pandoc as a
separate program does not by itself relicense NRC's proxy code.

Publishing this source repository is not the same as publishing built images.
Do not label a complete NRC image or the Search model as MIT-only. The repository
does not currently supply a complete per-image license or source-offer bundle.
