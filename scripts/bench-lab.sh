#!/usr/bin/env bash
# Rays against aria2 and curl on the fault-injecting lab server (engine/examples/lab.rs), so each scenario is the
# same for every tool and free of real-line noise.
#   scripts/bench-lab.sh [runs] [MiB] [scenario...]
# Each run downloads one file per tool; the order rotates every run; one warm-up run is not counted. Prints the
# median (and slowest to fastest) seconds per tool, with the server's requests, 503s, peak transfers and wasted
# bytes for the median run's tool. Every finished file is checked against the lab's SHA-256 after the clock stops;
# a mismatch counts as a failed run. Needs aria2c (brew install aria2).
# RAYS_OLD=<path to another build of the bench example> times it as "Rays before" against Rays and aria2 -x16 only,
# for engine A/B tests.
set -euo pipefail
cd "$(dirname "$0")/.."
runs="${1:-5}"
mib="${2:-64}"
shift 2 || true
port=8766
size=$((mib << 20))
url="http://127.0.0.1:$port/$size.bin"

# name|lab flags. Rates are bytes per second.
all_scenarios=(
  "clean|--link-rate 50000000"
  "unthrottled|"
  "capped-per-connection|--conn-rate 2000000 --link-rate 50000000"
  "one-in-three-slow|--conn-rate 4000000 --slow-every 3 --slow-rate 256000 --link-rate 50000000"
  "high-latency|--latency 150 --conn-rate 4000000 --link-rate 50000000"
  "server-allows-2|--max-conns 2 --conn-rate 4000000 --link-rate 50000000"
  "drops-every-8MB|--drop-after 8388608 --conn-rate 8000000 --link-rate 50000000"
  "random-drops|--drop-percent 2 --conn-rate 8000000 --link-rate 50000000"
)
scenarios=()
if [ $# -gt 0 ]; then
  for want in "$@"; do for s in "${all_scenarios[@]}"; do [ "${s%%|*}" = "$want" ] && scenarios+=("$s"); done; done
else
  scenarios=("${all_scenarios[@]}")
fi

cargo build -q --release -p dl-engine --example lab --example bench
lab=target/release/examples/lab
bench=target/release/examples/bench
tmp="$(mktemp -d)"
trap 'pkill -f "examples/lab --port $port" 2>/dev/null || true; rm -rf "$tmp"' EXIT

tools=("Rays" "aria2 -x16" "aria2" "curl" "Rays before")
ids=(0 1 2 3)
if [ -n "${RAYS_OLD:-}" ]; then ids=(0 4 1); fi
run() { # tool index; 0 when the tool finished, leaving its file at $tmp/f (except "Rays before")
  case "$1" in
    0) RAYS_BENCH_NO_WARMUP=1 RAYS_BENCH_OUT="$tmp/f" "$bench" "$url" 16 1 >/dev/null ;;
    1) aria2c -q -x16 -s16 -k1M --allow-overwrite=true --file-allocation=none -d "$tmp" -o f "$url" ;;
    2) aria2c -q --allow-overwrite=true --file-allocation=none -d "$tmp" -o f "$url" ;;
    # curl's own --retry restarts from the first offset, so each try is a new curl that resumes with -C -.
    3) local n=0; until curl -sfS -C - -o "$tmp/f" "$url" 2>/dev/null; do n=$((n + 1)); [ "$n" -lt 1000 ] || return 1; sleep 1; done ;;
    4) RAYS_BENCH_NO_WARMUP=1 "$RAYS_OLD" "$url" 16 1 >/dev/null ;;
  esac || { rm -f "$tmp/f" "$tmp/f.aria2"; return 1; }
}
verify() { # tool index; 0 when $tmp/f has the lab's SHA-256. An older bench build deletes its file itself.
  [ "$1" -eq 4 ] && return 0
  local got
  got=$(shasum -a 256 "$tmp/f" 2>/dev/null | cut -d' ' -f1)
  rm -f "$tmp/f" "$tmp/f.aria2"
  [ "$got" = "$want" ]
}
now() { python3 -c 'import time; print(time.time())'; }

for scenario in "${scenarios[@]}"; do
  name="${scenario%%|*}"
  pkill -f "examples/lab --port $port" 2>/dev/null || true
  # shellcheck disable=SC2086 # the flags are meant to split
  "$lab" --port "$port" ${scenario#*|} >/dev/null 2>&1 &
  disown
  until curl -s "http://127.0.0.1:$port/stats" >/dev/null; do sleep 0.1; done
  want=$(curl -s "http://127.0.0.1:$port/sha256/$size")
  results="$tmp/$name"
  : > "$results"
  for r in $(seq 0 "$runs"); do
    for k in "${!ids[@]}"; do
      i=${ids[$(( (k + r) % ${#ids[@]} ))]}
      curl -s "http://127.0.0.1:$port/reset" >/dev/null
      start=$(now)
      if run "$i"; then
        secs=$(python3 -c "import time; print(f'{time.time() - $start:.2f}')")
        verify "$i" || secs=fail
      else
        secs=fail
      fi
      stats=$(curl -s "http://127.0.0.1:$port/stats")
      [ "$r" -eq 0 ] || echo "$i $secs $stats" >> "$results"
    done
  done
  echo "== $name ($mib MiB, $runs runs; lab ${scenario#*|})"
  for i in "${ids[@]}"; do
    python3 - "$results" "$i" "${tools[$i]}" "$size" <<'PY'
import json, statistics, sys
path, idx, name, size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rows = [l.split(" ", 2) for l in open(path) if l.split(" ", 1)[0] == idx]
ok = sorted(((float(s), json.loads(j)) for _, s, j in rows if s != "fail"), key=lambda r: r[0])
fails = sum(1 for _, s, _ in rows if s == "fail")
if not ok:
    print(f"  {name:12} all {fails} runs failed")
    sys.exit()
secs = [s for s, _ in ok]
med, st = ok[len(ok) // 2]
note = f", {fails} failed" if fails else ""
print(f"  {name:12} {statistics.median(secs):6.2f} s ({secs[0]:.2f} to {secs[-1]:.2f}){note}  "
      f"{size / statistics.median(secs) / 1e6:6.1f} MB/s  requests {st['requests']}, 503s {st['rejected']}, "
      f"peak {st['peak']}, wasted {max(0, st['bytes'] - size) / 1e6:.1f} MB")
PY
  done
done
