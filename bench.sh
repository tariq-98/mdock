#!/bin/sh
# Benchmarks a docker context: ./bench.sh <context>
# Prints "metric<TAB>value<TAB>unit" lines.
set -e
CTX=${1:?usage: bench.sh <docker-context>}
D="docker --context $CTX"
WORK=$(mktemp -d /private/tmp/mdock-bench.XXXXXX)
trap 'rm -rf "$WORK"; $D rm -f mdock-bench-iperf >/dev/null 2>&1 || true' EXIT

printf 'FROM alpine:3.22\nRUN apk add --no-cache openssl iperf3 fio\n' | $D build -q -t mdock-bench - >/dev/null
$D pull -q --platform linux/amd64 alpine:3.22 >/dev/null

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# Container start+exit latency (median of 7).
for i in 1 2 3 4 5 6 7; do
  s=$(now); $D run --rm mdock-bench true; e=$(now)
  echo "$e - $s" | bc
done | sort -n | sed -n 4p | { read -r t; emit "container run (median)" "$(echo "$t * 1000" | bc | cut -d. -f1)" ms; }

emit "visible CPUs" "$($D run --rm mdock-bench nproc)" ""

# Multi-core crypto throughput across every CPU the VM has.
v=$($D run --rm mdock-bench sh -c 'openssl speed -seconds 5 -multi $(nproc) sha256 2>/dev/null | awk "/^sha256/{print \$NF}"')
emit "sha256 all cores (16KiB blocks)" "${v%k}" "kB/s"
v=$($D run --rm mdock-bench sh -c 'openssl speed -seconds 5 sha256 2>/dev/null | awk "/^sha256/{print \$NF}"')
emit "sha256 single core" "${v%k}" "kB/s"
v=$($D run --rm --platform linux/amd64 alpine:3.22 sh -c 'apk add -q --no-cache openssl >/dev/null 2>&1; openssl speed -seconds 5 sha256 2>/dev/null | awk "/^sha256/{print \$NF}"')
emit "sha256 single core, amd64 via Rosetta" "${v%k}" "kB/s"

# Container filesystem on the VM disk.
v=$($D run --rm mdock-bench fio --name=r --directory=/tmp --rw=randrw --bs=4k --size=256m --runtime=10 --time_based \
      --ioengine=libaio --direct=1 --iodepth=32 --output-format=terse --minimal | awk -F';' '{print $8 + $49}')
emit "disk 4k random r/w (container fs)" "$v" "IOPS"
v=$($D run --rm mdock-bench fio --name=s --directory=/tmp --rw=write --bs=1m --size=1g --ioengine=libaio --direct=1 \
      --iodepth=8 --end_fsync=1 --output-format=terse --minimal | awk -F';' '{printf "%d", $48 / 1024}')
emit "disk sequential write (container fs)" "$v" "MB/s"

# Bind mounts from macOS: many small files (node_modules-style) and one big file.
s=$(now)
$D run --rm -v "$WORK:/w" mdock-bench sh -c 'mkdir /w/src; i=0; while [ $i -lt 5000 ]; do echo "module $i" > /w/src/f$i.js; i=$((i+1)); done; cat /w/src/*.js | wc -l >/dev/null; rm -rf /w/src'
e=$(now)
emit "bind mount: 5000 small files write+read+rm" "$(echo "($e - $s) * 1000" | bc | cut -d. -f1)" ms
v=$($D run --rm -v "$WORK:/w" mdock-bench fio --name=b --directory=/w --rw=write --bs=1m --size=1g --end_fsync=1 \
      --output-format=terse --minimal | awk -F';' '{printf "%d", $48 / 1024}')
emit "bind mount sequential write" "$v" "MB/s"
v=$($D run --rm -v "$WORK:/w" mdock-bench fio --name=b --directory=/w --rw=read --bs=1m --size=1g \
      --output-format=terse --minimal | awk -F';' '{printf "%d", $7 / 1024}')
emit "bind mount sequential read" "$v" "MB/s"

# macOS -> container over a published port (the path a browser or API client takes).
$D run -d --name mdock-bench-iperf -p 15201:5201 mdock-bench iperf3 -s >/dev/null
sleep 2
v=$(iperf3 -c 127.0.0.1 -p 15201 -t 5 -J 2>/dev/null | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"]/1e6))' || echo 0)
emit "localhost -> container (published port)" "$v" "Mbit/s"
v=$(iperf3 -c 127.0.0.1 -p 15201 -t 5 -R -J 2>/dev/null | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"]/1e6))' || echo 0)
emit "container -> localhost (published port)" "$v" "Mbit/s"
