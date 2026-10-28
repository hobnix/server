#!/usr/bin/env python3
"""Capacity forecast and wear parsing for the health check (stdlib only, no I/O of its own besides stdin/stdout).

  forecast.py days-to-full [--min-days N] [--min-samples N] [--window DAYS]
      stdin: lines "time TAB used TAB size" (scripts/state.sh usage <key>), oldest first.
      stdout: the whole days until the volume is full at the trend of the window (a least-squares line through
      the readings), or "-" when it is not growing, when there is too little history (fewer than --min-samples
      readings or less than --min-days between first and last) or when the line is not trustworthy.
  forecast.py growth-pct-per-day [same options]
      the growth in percent of the size per day (one decimal), or "-".
  forecast.py wear
      stdin: the output of `smartctl -A` (or -a). stdout: the percent of the SSD's life used (0 to 100), or "-"
      when the disk reports none. NVMe: "Percentage Used". SATA: the normalised value of Wear_Leveling_Count,
      Media_Wearout_Indicator, SSD_Life_Left or Percent_Lifetime_Remain (100 = new, counting down).
  forecast.py cache-age-hours NOW OLDEST
      hours between two epoch seconds (the cache-mover backlog), one decimal, "-" on bad input.
Exit status is always 0 on a well-formed call; the caller decides what to report.
"""
import re
import sys


def read_samples(lines):
    out = []
    for ln in lines:
        p = ln.split()
        if len(p) >= 3:
            try:
                out.append((int(p[0]), int(p[1]), int(p[2])))
            except ValueError:
                pass
    return out


def fit(samples, window_days=60):
    """(slope in bytes per second, last used, last size, span in seconds, n) over the window, or None."""
    if not samples:
        return None
    samples = sorted(samples)
    t_end = samples[-1][0]
    s = [x for x in samples if x[0] >= t_end - window_days * 86400]
    n = len(s)
    if n < 2:
        return None
    t0 = s[0][0]
    xs = [x[0] - t0 for x in s]
    ys = [x[1] for x in s]
    mx = sum(xs) / n
    my = sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
    return slope, s[-1][1], s[-1][2], xs[-1], n


def days_to_full(samples, min_days=3, min_samples=6, window_days=30):
    """Whole days until used reaches size, or None when not growing or not enough history."""
    f = fit(samples, window_days)
    if f is None:
        return None
    slope, used, size, span, n = f
    if n < min_samples or span < min_days * 86400:
        return None
    if slope <= 0:
        return None
    free = size - used
    if free <= 0:
        return 0
    return int(free / slope // 86400)


def growth_pct_per_day(samples, min_days=3, min_samples=6, window_days=30):
    f = fit(samples, window_days)
    if f is None:
        return None
    slope, used, size, span, n = f
    if n < min_samples or span < min_days * 86400 or size <= 0:
        return None
    return slope * 86400 * 100.0 / size


def wear_used(text):
    """Percent of the life used from `smartctl -A` text, or None."""
    m = re.search(r"^Percentage Used:\s*(\d+)\s*%", text, re.M)
    if m:
        return min(100, int(m.group(1)))
    for line in text.splitlines():
        p = line.split()
        # ID ATTRIBUTE_NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
        if len(p) >= 10 and p[0].isdigit() and p[1] in (
                "Wear_Leveling_Count", "Media_Wearout_Indicator", "SSD_Life_Left", "Percent_Lifetime_Remain",
                "Remaining_Lifetime_Perc"):
            try:
                v = int(p[3])
            except ValueError:
                continue
            if 0 <= v <= 100:
                return 100 - v
    return None


def opt(args, name, default):
    if name in args:
        try:
            return type(default)(args[args.index(name) + 1])
        except (ValueError, IndexError):
            return default
    return default


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd in ("days-to-full", "growth-pct-per-day"):
        kw = dict(min_days=opt(args, "--min-days", 3), min_samples=opt(args, "--min-samples", 6),
                  window_days=opt(args, "--window", 30))
        samples = read_samples(sys.stdin)
        if cmd == "days-to-full":
            r = days_to_full(samples, **kw)
            print("-" if r is None else r)
        else:
            r = growth_pct_per_day(samples, **kw)
            print("-" if r is None else "%.1f" % r)
        return 0
    if cmd == "wear":
        r = wear_used(sys.stdin.read())
        print("-" if r is None else r)
        return 0
    if cmd == "cache-age-hours":
        try:
            print("%.1f" % ((int(args[0]) - int(args[1])) / 3600.0))
        except (ValueError, IndexError):
            print("-")
        return 0
    print("unknown command: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
