# Odin TLSF dependency

Copied from `odin-lang/Odin` `core/mem/tlsf` at nightly revision `a2fb372`
(`dev-2026-09-nightly`), including the upstream BSD-3-Clause license and
copyright notices. NRC imports this copy rather than mutating the installed
compiler's standard library, so builds on other machines receive the same fix.

Local change: if allocating a growth pool's tracking node fails, remove the
fresh pool from the free lists, free its backing buffer and return the original
allocation error. Existing pools and allocations remain usable. The regression
test injects this exact failure twice, then verifies a successful resize and
complete destruction.

Keep the upstream implementation otherwise unchanged when updating this copy.
Run `./test/run_odin_tests.sh vendor/tlsf/` after changes.
