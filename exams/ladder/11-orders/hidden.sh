#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
cat > h.json <<'J'
[{"id":1,"customer":"Ann","items":[{"name":"pen","price":1.5,"qty":4}]},
 {"id":2,"customer":"Bob","items":[{"name":"ink","price":2.25,"qty":2},{"name":"pad","price":1.5,"qty":1}]},
 {"id":3,"customer":"Ann","items":[]},
 {"id":4,"customer":"Cat","items":[{"name":"cap","price":0.1,"qty":3}]}]
J
out=$(swift orders.swift h.json)
check "order + format" '[ "$out" = "$(printf "Ann: 6.00\nBob: 6.00\nCat: 0.30\nTOTAL: 12.30")" ]'
echo '{"not":"a list"}' > bad.json
check "bad shape exit 1" 'swift orders.swift bad.json >/dev/null 2>&1; [ $? -eq 1 ]'
check "missing exit 1"   'swift orders.swift none.json >/dev/null 2>&1; [ $? -eq 1 ]'
check "uses Codable"     'grep -q "Codable\|Decodable" orders.swift'
exit $fail
