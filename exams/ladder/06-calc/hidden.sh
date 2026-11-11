#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "precedence"  '[ "$(python3 calc.py "2+3*4")" = 14 ]'
check "parens"      '[ "$(python3 calc.py "2*(3+4)")" = 14 ]'
check "left assoc"  '[ "$(python3 calc.py "10-4-3")" = 3 ]'
check "division"    '[ "$(python3 calc.py "7/2")" = 3.5 ]'
check "unary"       '[ "$(python3 calc.py "-(2+3)*2")" = -10 ]'
check "decimals"    '[ "$(python3 calc.py "1/3")" = 0.333333 ]'
check "spaces"      '[ "$(python3 calc.py " 8 / ( 1 + 1 ) ")" = 4 ]'
check "div zero"    'python3 calc.py "1/0" >/dev/null 2>&1; [ $? -eq 1 ]'
check "malformed"   'python3 calc.py "2+*3" >/dev/null 2>&1; [ $? -eq 1 ]'
check "no eval"     '! grep -Eq "(^|[^a-zA-Z_])(eval|exec)\(" calc.py'
exit $fail
