#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
cat > h1.json <<'J'
{"price": 5, "items": [{"price": 2.5, "qty": 1}, {"price": 2.5, "sub": {"price": 10}}], "meta": {"price": true, "x": [ {"price": 1} ]}}
J
check "nested sum"   '[ "$(python3 jsonsum.py h1.json price)" = 21 ]'
check "missing key"  '[ "$(python3 jsonsum.py h1.json nope)" = 0 ]'
echo '[{"v": 0.5}, {"v": 0.25}]' > h2.json
check "float sum"    '[ "$(python3 jsonsum.py h2.json v)" = 0.75 ]'
echo '{"v": "7", "w": {"v": 3}}' > h3.json
check "strings skipped" '[ "$(python3 jsonsum.py h3.json v)" = 3 ]'
echo '{bad json' > h4.json
check "bad json exit 1" 'python3 jsonsum.py h4.json v >/dev/null 2>&1; [ $? -eq 1 ]'
check "no file exit 1"  'python3 jsonsum.py nofile.json v >/dev/null 2>&1; [ $? -eq 1 ]'
exit $fail
