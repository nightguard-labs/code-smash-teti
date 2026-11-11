#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
rm -f todo.json
python3 todo.py add "buy milk" >/dev/null; python3 todo.py add "walk dog" >/dev/null; python3 todo.py add "code" >/dev/null
check "list still works" '[ "$(python3 todo.py list)" = "$(printf "1. [ ] buy milk\n2. [ ] walk dog\n3. [ ] code")" ]'
python3 todo.py done 2 >/dev/null
check "done"     '[ "$(python3 todo.py list | sed -n 2p)" = "2. [x] walk dog" ]'
python3 todo.py remove 1 >/dev/null
check "remove + renumber" '[ "$(python3 todo.py list)" = "$(printf "1. [x] walk dog\n2. [ ] code")" ]'
before=$(cat todo.json)
check "bad N exit 1"   'python3 todo.py done 9 >/dev/null 2>&1; [ $? -eq 1 ]'
check "bad N no change" '[ "$(cat todo.json)" = "$before" ]'
check "text N exit 1"  'python3 todo.py remove x >/dev/null 2>&1; [ $? -eq 1 ]'
check "persists"       '[ "$(python3 todo.py list | wc -l | tr -d " ")" = 2 ]'
exit $fail
