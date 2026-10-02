#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run=${FANOUT_CASE_RUNNER:-$script_dir/run_fanout_capacity_case.sh}
sequence=${FANOUT_SEQUENCE_START:-100}

one() {
  "$run" "$1" "$2" "$3" "$sequence" "$4"
  sequence=$((sequence + 1))
}

# These are the conservative 3/3-stable points measured on the documented
# 24-core reference runner. Alternate implementation order within each topology.
one nrc 1 capacity-rep1 3125
one uws 1 capacity-rep1 3000
one uws 1 capacity-rep2 3000
one nrc 1 capacity-rep2 3125
one nrc 1 capacity-rep3 3125
one uws 1 capacity-rep3 3000

one uws 2 capacity-rep1 3125
one nrc 2 capacity-rep1 3250
one nrc 2 capacity-rep2 3250
one uws 2 capacity-rep2 3125
one uws 2 capacity-rep3 3125
one nrc 2 capacity-rep3 3250

one nrc 4 capacity-rep1 3000
one uws 4 capacity-rep1 3125
one uws 4 capacity-rep2 3125
one nrc 4 capacity-rep2 3000
one nrc 4 capacity-rep3 3000
one uws 4 capacity-rep3 3125
