#!/usr/bin/env bash
# Verify, extract and EXIF-check one Amazon year directory.
set -uo pipefail
Y="$1"; D="$HOME/amazon-shawna/$Y"
cd "$D" || exit 1
echo "=== CRC ==="; tot=0; bad=0
for z in *.zip; do
  if unzip -t "$z" >/dev/null 2>&1; then
    n=$(unzip -l "$z" | tail -1 | awk '{print $2}'); tot=$((tot+n)); echo "OK $z ($n)"
  else echo "BAD $z"; bad=1; fi
done
echo "entries=$tot bad=$bad"
[ "$bad" -eq 0 ] || exit 1
mkdir -p files
for z in *.zip; do unzip -q -o "$z" -d files/; done
echo "=== extracted ==="; find files -type f | wc -l; du -sh files
echo "=== extensions ==="; find files -type f | sed 's/.*\.//' | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn
echo "=== EXIF check on non-date-named ==="
cd files || exit 1
miss=0; n=0
while IFS= read -r f; do
  n=$((n+1))
  strings -n 8 "$f" 2>/dev/null | grep -qoE '[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
    || { echo "  NO EXIF: [$f]"; miss=$((miss+1)); }
done < <(find . -maxdepth 1 -type f -printf '%f\n' | grep -vE '^[0-9]{8}_[0-9]{6}')
echo "checked=$n without_exif=$miss"
echo "PREP COMPLETE"
