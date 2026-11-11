#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
cat > hidden_test.py <<'P'
import time
from lru import LRUCache
c = LRUCache(2)
c.put(1, 1); c.put(2, 2)
assert c.get(1) == 1
c.put(3, 3)                 # evicts 2
assert c.get(2) == -1
c.put(4, 4)                 # evicts 1
assert c.get(1) == -1 and c.get(3) == 3 and c.get(4) == 4
c.put(3, 30)                # update counts as use
c.put(5, 5)                 # evicts 4
assert c.get(4) == -1 and c.get(3) == 30 and len(c) == 2
big = LRUCache(200000)
t = time.time()
for i in range(200000): big.put(i, i)
for i in range(200000): big.get(i)
assert time.time() - t < 3, "too slow, not O(1)"
print("ALL OK")
P
check "behaviour + speed" '[ "$(python3 hidden_test.py 2>&1 | tail -1)" = "ALL OK" ]'
exit $fail
