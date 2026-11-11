#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
out=$(python3 stats.py 3 1 2 2 9)
check "mean"        '[ "$(echo "$out" | sed -n 1p)" = "mean 3.40" ]'
check "median odd"  '[ "$(echo "$out" | sed -n 2p)" = "median 2.00" ]'
check "mode"        '[ "$(echo "$out" | sed -n 3p)" = "mode 2" ]'
out2=$(python3 stats.py 4 1 3 2)
check "median even" '[ "$(echo "$out2" | sed -n 2p)" = "median 2.50" ]'
check "mode tie"    '[ "$(echo "$out2" | sed -n 3p)" = "mode 1" ]'
check "decimal mode" '[ "$(python3 stats.py 1.5 1.5 2 | sed -n 3p)" = "mode 1.5" ]'
check "empty exit 1" 'python3 stats.py >/dev/null 2>&1; [ $? -eq 1 ]'
exit $fail
