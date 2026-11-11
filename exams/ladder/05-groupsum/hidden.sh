#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
cat > h.csv <<'C'
name,city,amount
a,"Austin, TX",10
b,Boston,5.5
c,"Austin, TX",2.25
d,Boston,
e,Chicago,abc
f,Denver,5.5
g,Chicago,1
C
out=$(python3 groupsum.py h.csv city amount)
check "first line"  '[ "$(echo "$out" | sed -n 1p)" = "$(printf "Austin, TX\t12.25")" ]'
check "tie order"   '[ "$(echo "$out" | sed -n 2p)" = "$(printf "Boston\t5.50")" ] && [ "$(echo "$out" | sed -n 3p)" = "$(printf "Denver\t5.50")" ]'
check "last line"   '[ "$(echo "$out" | sed -n 4p)" = "$(printf "Chicago\t1.00")" ]'
check "4 groups"    '[ "$(echo "$out" | wc -l | tr -d " ")" = 4 ]'
check "bad column"  'python3 groupsum.py h.csv nope amount >/dev/null 2>&1; [ $? -eq 2 ]'
exit $fail
