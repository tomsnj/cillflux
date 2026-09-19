#!/usr/bin/env python3
"""Recover capture dates for files with no EXIF, from patterns in the filename.
Usage: fix-dates.py <dir> <noexif-list> [--apply]
Only applies a date it can derive unambiguously and that is plausible."""
import re, os, sys, datetime
from collections import Counter

d, listfile = sys.argv[1], sys.argv[2]
apply_ = "--apply" in sys.argv
os.chdir(d)
names = [l.strip() for l in open(listfile) if l.strip()]

def plausible(dt):
    return dt and 2005 <= dt.year <= 2026

def derive(n):
    # 1. YYYYMMDD_HHMMSS  (e.g. Resized_20181008_213715.jpg)
    m = re.search(r'(?<!\d)(20\d{2})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(?!\d)', n)
    if m:
        try: return datetime.datetime(*map(int, m.groups())), 'YYYYMMDD_HHMMSS'
        except ValueError: pass
    # 1b. YYYY-MM-DD HH.MM.SS  (e.g. 2012-10-13 11.18.28.jpg)
    m = re.search(r'(?<!\d)(20\d{2})-(\d{2})-(\d{2})[ _](\d{2})[.\-](\d{2})[.\-](\d{2})(?!\d)', n)
    if m:
        try: return datetime.datetime(*map(int, m.groups())), 'YYYY-MM-DD HH.MM.SS'
        except ValueError: pass
    # 2. YYYYMMDDHHMMSS with optional 3-digit ms (e.g. barn external_03_20180917071511768.jpg)
    m = re.search(r'(?<!\d)(20\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{3})?(?!\d)', n)
    if m:
        try: return datetime.datetime(*map(int, m.groups()[:6])), 'YYYYMMDDHHMMSS'
        except ValueError: pass
    # 3. 13-digit epoch ms (e.g. FB_IMG_1484571007988.jpg)
    m = re.search(r'(?<!\d)(\d{13})(?!\d)', n)
    if m:
        try: return datetime.datetime.fromtimestamp(int(m.group(1))/1000, datetime.UTC).replace(tzinfo=None), 'epoch-ms'
        except (ValueError, OSError): pass
    return None, None

fixed, skipped = [], []
for n in names:
    if not os.path.exists(n):
        skipped.append((n, 'missing')); continue
    dt, how = derive(n)
    if not plausible(dt):
        skipped.append((n, 'no derivable date')); continue
    if apply_:
        ts = dt.timestamp(); os.utime(n, (ts, ts))
    fixed.append((n, dt.strftime('%Y-%m-%d %H:%M'), how))

print(f"{'APPLIED' if apply_ else 'DRY RUN'} - would fix {len(fixed)} of {len(names)}")
for n, dt, how in fixed[:10]:
    print(f"   {n[:46]:48s} -> {dt}  [{how}]")
if len(fixed) > 10: print(f"   ... and {len(fixed)-10} more")
print(f"\nby method: {dict(Counter(h for _,_,h in fixed))}")
print(f"left alone: {len(skipped)}  {dict(Counter(r for _,r in skipped))}")
