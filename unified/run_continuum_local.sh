#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "Usage: run-continuum-local <n> <t> <layers> <total_cm> [mixed|linear|nonlinear]" >&2
  exit 1
fi

n="$1"
t="$2"
layers="$3"
total_cm="$4"
mode="${5:-mixed}"

if (( n < 3 * t + 1 )); then
  echo "Invalid params: n=${n}, t=${t}. Must satisfy n >= 3*t+1." >&2
  exit 1
fi

if (( n > 3 * t + 1 )); then
  echo "Note: using n=${n}, t=${t} (n > 3*t+1). This is supported; fault tolerance remains t=${t}."
fi

case "$mode" in
  mixed)
    task="ad-mpc2"
    ;;
  linear)
    task="ad-mpc2-linear"
    ;;
  nonlinear|mul|multiplication)
    task="ad-mpc2-nonlinear"
    ;;
  *)
    echo "Invalid mode: ${mode}. Expected one of: mixed, linear, nonlinear" >&2
    exit 1
    ;;
esac

source /opt/venv/continuum/bin/activate
export PYTHONPATH="/opt/dumbo-mpc/dumbo-mpc/AsyRanTriGen:${PYTHONPATH:-}"

cd /opt/dumbo-mpc/dumbo-mpc/AsyRanTriGen
python3 scripts/run_key_gen_dyn.py --N "$n" --f "$t" --layers "$layers" --total_cm "$total_cm"

cd /opt/dumbo-mpc
exec ./run_local_network_test.sh "$task" "$n" "$layers" "$total_cm"
