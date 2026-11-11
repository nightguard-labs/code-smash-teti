#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "15 lines"      '[ "$(python3 fizzbuzz.py 15 | wc -l | tr -d " ")" = 15 ]'
check "line 15"       '[ "$(python3 fizzbuzz.py 15 | sed -n 15p)" = FizzBuzz ]'
check "line 9"        '[ "$(python3 fizzbuzz.py 15 | sed -n 9p)" = Fizz ]'
check "line 10"       '[ "$(python3 fizzbuzz.py 15 | sed -n 10p)" = Buzz ]'
check "line 7"        '[ "$(python3 fizzbuzz.py 15 | sed -n 7p)" = 7 ]'
check "N=1"           '[ "$(python3 fizzbuzz.py 1)" = 1 ]'
check "bad N exit 2"  'python3 fizzbuzz.py abc >/dev/null 2>&1; [ $? -eq 2 ]'
check "zero exit 2"   'python3 fizzbuzz.py 0 >/dev/null 2>&1; [ $? -eq 2 ]'
check "missing exit 2" 'python3 fizzbuzz.py >/dev/null 2>&1; [ $? -eq 2 ]'
check "error on stderr only" '[ -z "$(python3 fizzbuzz.py abc 2>/dev/null)" ]'
exit $fail
