#!/usr/bin/env bash
# Wait until a year's zip transfer looks complete, then prep it.
# Usage: watch-prep.sh <year> <expected_zip_count>
set -uo pipefail
Y="$1"; WANT="$2"; D="$HOME/amazon-shawna/$Y"
SCRIPT="$(dirname "$0")/prep-year.sh"

for i in $(seq 1 720); do          # up to 12h at 60s
  n=$(ls "$D"/*.zip 2>/dev/null | wc -l)
  if [ "$n" -ge "$WANT" ]; then
    # settle check: sizes stable across 60s means transfer finished
    a=$(du -sb "$D" 2>/dev/null | cut -f1)
    sleep 60
    b=$(du -sb "$D" 2>/dev/null | cut -f1)
    if [ "$a" = "$b" ]; then
      echo "$(date +%H:%M:%S)  $n/$WANT zips, size stable at $b bytes - prepping"
      exec "$SCRIPT" "$Y"
    fi
    echo "$(date +%H:%M:%S)  $n/$WANT zips but still growing ($a -> $b)"
    continue
  fi
  echo "$(date +%H:%M:%S)  waiting: $n/$WANT zips"
  sleep 60
done
echo "TIMED OUT waiting for $WANT zips in $D"
exit 2
