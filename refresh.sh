#!/usr/bin/env bash
# CF edge IP sweep: verify candidate IPs against our own hostname (real SNI),
# keep only those that answer HTTP 200 (drops error-1034 "Edge IP Restricted"),
# publish a diverse pool to all.txt for the edge Worker to consume.
set -euo pipefail

DOMAIN="${DOMAIN:-cf.edge8k.top}"
OUT="all.txt"
CAP=150          # max IPs published
PER_SEG=8        # max IPs kept per /24 to keep the pool diverse
CONCURRENCY=6    # keep low: high concurrency against CF produces false failures
TIMEOUT=6

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- 1) candidates = existing pool + random samples across every healthy CF /24
: > "$WORK/cands"
if [ -f "$OUT" ]; then
  grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$OUT" >> "$WORK/cands" || true
fi

SEGS=(
  104.16 104.17 104.18 104.19 104.20 104.21 104.22 104.23 104.24 104.25 104.26 104.27
  172.64 172.65 172.66 172.67 172.68 172.69 172.70 172.71
)
SEG24=(188.114.96 188.114.97 188.114.98 188.114.99)

for seg in "${SEGS[@]}"; do
  for _ in 1 2 3 4 5 6 7 8; do
    echo "$seg.$((RANDOM % 256)).$((RANDOM % 256))" >> "$WORK/cands"
  done
done
for seg in "${SEG24[@]}"; do
  for _ in 1 2 3 4 5 6 7 8; do
    echo "$seg.$((RANDOM % 256))" >> "$WORK/cands"
  done
done

sort -u "$WORK/cands" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' > "$WORK/cands.uniq"
echo "candidates: $(wc -l < "$WORK/cands.uniq" | tr -d ' ')"

# ---- 2) verify: force the candidate IP but keep the real hostname/SNI
test_ip() {
  ip="$1"
  out=$(curl -s -m "$TIMEOUT" -o /dev/null -w "%{http_code} %{time_total}" \
        --resolve "$DOMAIN:443:$ip" "https://$DOMAIN/cdn-cgi/trace" 2>/dev/null || echo "000 9.9")
  code=${out%% *}
  tt=${out##* }
  [ "$code" = "200" ] && echo "$tt $ip"
}
export -f test_ip
export DOMAIN TIMEOUT

xargs -P "$CONCURRENCY" -I{} bash -c 'test_ip "$@"' _ {} < "$WORK/cands.uniq" > "$WORK/passed" || true

# ---- 3) pick a diverse set: cap per /24, then fill up to CAP
sort -n "$WORK/passed" | awk '{print $2}' | awk '!seen[$0]++' | awk -F. \
  -v cap="$PER_SEG" '{ s=$1"."$2"."$3; n[s]++; if (n[s] <= cap) print $0 }' \
  | head -n "$CAP" > "$WORK/new.txt"

count=$(wc -l < "$WORK/new.txt" | tr -d ' ')
passed=$(wc -l < "$WORK/passed" | tr -d ' ')
echo "passed 200: $passed   publishing: $count"
if [ "$count" -lt 10 ]; then
  echo "too few usable IPs, keeping existing pool"; exit 1
fi

cp "$WORK/new.txt" "$OUT"
echo "segments: $(awk -F. '{print $1"."$2"."$3}' "$OUT" | sort | uniq -c | sort -rn | head -n 8 | tr '\n' ' ')"
echo "done"
