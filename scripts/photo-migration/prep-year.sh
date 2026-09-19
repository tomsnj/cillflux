#!/usr/bin/env bash
# Verify, extract and EXIF-check a directory of Amazon Photos zips.
#
#   prep-year.sh /path/to/dir     explicit directory
#   prep-year.sh 2018             <AMAZON_BASE>/2018
#
# AMAZON_BASE defaults to $HOME/amazon-shawna (the 2026-09 migration
# layout). Override it for a different library or host:
#
#   AMAZON_BASE=/mnt/storage1/home/stecktf_a/amazon-tom prep-year.sh 2018
set -uo pipefail
shopt -s nullglob

[ $# -ge 1 ] || { echo "usage: $(basename "$0") <dir|year>" >&2; exit 2; }
ARG="$1"
BASE="${AMAZON_BASE:-$HOME/amazon-shawna}"
if [ -d "$ARG" ]; then D="$ARG"; else D="$BASE/$ARG"; fi
[ -d "$D" ] || { echo "no such directory: $D" >&2; exit 1; }
cd "$D" || exit 1
echo "=== dir: $D ==="

zips=( *.zip )
[ ${#zips[@]} -gt 0 ] || { echo "no .zip files in $D" >&2; exit 1; }

echo "=== CRC ==="; tot=0; bad=0
for z in "${zips[@]}"; do
  if unzip -t "$z" >/dev/null 2>&1; then
    n=$(unzip -l "$z" | tail -1 | awk '{print $2}'); tot=$((tot+n)); echo "OK $z ($n)"
  else echo "BAD $z"; bad=1; fi
done
echo "entries=$tot bad=$bad"
[ "$bad" -eq 0 ] || exit 1

mkdir -p files
for z in "${zips[@]}"; do unzip -q -o "$z" -d files/; done

extracted=$(find files -type f | wc -l)
echo "=== extracted ==="; echo "$extracted"; du -sh files
# entries > extracted means duplicate filenames across zips - usually a
# batch downloaded twice, occasionally two genuinely different photos
# sharing a name. Compare checksums before assuming it is benign.
if [ "$tot" -ne "$extracted" ]; then
  echo "!! entries=$tot but extracted=$extracted (diff $((tot-extracted)))"
  echo "!! duplicate filenames across zips - check before importing"
fi

echo "=== extensions ==="
find files -type f | sed 's/.*\.//' | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn

# Files with no date in the name depend on EXIF. Note this check greps
# for a date string and produces FALSE NEGATIVES - Immich reads plenty
# it misses. Treat the output as "worth a look", not "these are broken".
echo "=== EXIF check on non-date-named ==="
cd files || exit 1
miss=0; n=0
while IFS= read -r f; do
  n=$((n+1))
  strings -n 8 "$f" 2>/dev/null | grep -qoE '[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
    || { echo "  NO EXIF: [$f]"; miss=$((miss+1)); }
done < <(find . -type f -printf '%P\n' | grep -vE '^[0-9]{8}_[0-9]{6}')
echo "checked=$n without_exif=$miss"
echo "PREP COMPLETE"
