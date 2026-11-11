#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "balanced"     '[ "$(printf "a(b[c]{d}e)f" | swift brackets.swift)" = OK ]'
check "empty"        '[ "$(printf "" | swift brackets.swift)" = OK ]'
check "wrong kind"   '[ "$(printf "(]" | swift brackets.swift)" = "ERROR at 2" ]'
check "extra close"  '[ "$(printf "ab)" | swift brackets.swift)" = "ERROR at 3" ]'
check "unclosed"     '[ "$(printf "x{(y)" | swift brackets.swift)" = "ERROR at 2" ]'
check "nested wrong" '[ "$(printf "{[(])}" | swift brackets.swift)" = "ERROR at 4" ]'
check "exit 1"       'printf "(" | swift brackets.swift >/dev/null; [ $? -eq 1 ]'
check "exit 0"       'printf "()" | swift brackets.swift >/dev/null; [ $? -eq 0 ]'
exit $fail
