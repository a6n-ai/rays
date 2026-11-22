#!/usr/bin/env bash
# Head-to-head download speed: Rays against aria2, curl and wget on the same file.
#   scripts/bench-vs.sh [url] [rounds]
# Every round runs each tool once, in the same order, so network drift hits all of them; one warm-up round
# is not counted. Prints each run and the median MB/s per tool. Needs aria2c and wget (brew install aria2 wget).
set -euo pipefail
cd "$(dirname "$0")/.."
url="${1:-https://sin-speed.hetzner.com/100MB.bin}"
rounds="${2:-5}"

cargo build -q --release -p dl-engine --example bench
bench=target/release/examples/bench
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tools=("Rays (adaptive, up to 16)" "aria2 -x16 -s16" "aria2 (defaults)" "curl" "wget")
run() { # tool index; downloads into $tmp, then deletes the file
  case "$1" in
    0) RAYS_BENCH_NO_WARMUP=1 "$bench" "$url" 16 1 >/dev/null ;;
    1) aria2c -q -x16 -s16 -k1M --allow-overwrite=true --file-allocation=none -d "$tmp" -o f "$url" ;;
    2) aria2c -q --allow-overwrite=true --file-allocation=none -d "$tmp" -o f "$url" ;;
    3) curl -sfSL -o "$tmp/f" "$url" ;;
    4) wget -q -O "$tmp/f" "$url" ;;
  esac
  # A tool that exits early without the whole file must not count as a fast run (Rays' bench checks its own).
  local got=0
  [ "$1" -eq 0 ] || got=$(stat -f%z "$tmp/f" 2>/dev/null || echo 0)
  rm -f "$tmp/f" "$tmp/f.aria2"
  [ "$1" -eq 0 ] || [ "$got" = "$size" ]
}
# A 1-byte range GET, since some speed-test servers drop HEAD requests.
size=$(curl -sfSL -r 0-0 -o /dev/null -w '%header{content-range}' "$url" | sed 's#.*/##')
[ "${size:-0}" -gt 0 ] 2>/dev/null || { echo "no size (Content-Range) for $url" >&2; exit 1; }

results="$tmp/results"
for round in $(seq 0 "$rounds"); do
  for i in "${!tools[@]}"; do
    start=$(python3 -c 'import time; print(time.time())')
    run "$i" || { echo "round $round ${tools[$i]}: failed"; rm -f "$tmp/f"; continue; }
    mbps=$(python3 -c "import time; print(f'{$size / (time.time() - $start) / 1e6:.1f}')")
    if [ "$round" -eq 0 ]; then echo "warm-up ${tools[$i]}: $mbps MB/s"; continue; fi
    echo "round $round ${tools[$i]}: $mbps MB/s"
    echo "$i $mbps" >> "$results"
  done
done

echo "median (min to max) of $rounds rounds, $((size / 1000000)) MB from $url:"
for i in "${!tools[@]}"; do
  awk -v i="$i" '$1==i {print $2}' "$results" | sort -n | awk -v name="${tools[$i]}" \
    '{v[NR]=$1} END {m = NR%2 ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2; printf "  %-26s %6.1f MB/s  (%.1f to %.1f)\n", name, m, v[1], v[NR]}'
done
