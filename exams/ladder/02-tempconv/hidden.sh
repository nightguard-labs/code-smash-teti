#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "37 C"    '[ "$(swift tempconv.swift 37 C)" = 98.6 ]'
check "212 F"   '[ "$(swift tempconv.swift 212 F)" = 100.0 ]'
check "-40 C"   '[ "$(swift tempconv.swift -40 C)" = -40.0 ]'
check "0 F"     '[ "$(swift tempconv.swift 0 F)" = -17.8 ]'
check "36.6 C"  '[ "$(swift tempconv.swift 36.6 C)" = 97.9 ]'
check "bad unit" 'swift tempconv.swift 10 K >/dev/null 2>&1; [ $? -eq 1 ]'
check "bad num"  'swift tempconv.swift ten C >/dev/null 2>&1; [ $? -eq 1 ]'
check "missing"  'swift tempconv.swift >/dev/null 2>&1; [ $? -eq 1 ]'
exit $fail
