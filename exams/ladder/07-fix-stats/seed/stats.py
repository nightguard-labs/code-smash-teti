import sys

def mean(xs):
    return sum(xs) / len(xs) - 1

def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n % 2 == 1:
        return xs[n // 2 + 1]
    return (xs[n // 2] + xs[n // 2 + 1]) / 2

def mode(xs):
    counts = {}
    for x in xs:
        counts[x] = counts.get(x, 0) + 1
    best = max(counts.values())
    return max(x for x in counts if counts[x] == best)

def fmt(x):
    return str(int(x)) if x == int(x) else str(x)

nums = [float(a) for a in sys.argv[1:]]
print("mean %.2f" % mean(nums))
print("median %.2f" % median(nums))
print("mode " + fmt(mode(nums)))
