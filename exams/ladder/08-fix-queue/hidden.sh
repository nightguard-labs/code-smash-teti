#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "compiles"   'swiftc Queue.swift main.swift -o queue 2>/dev/null'
check "output"     '[ "$(./queue)" = "$(printf "dequeued 1\ndequeued 2\ncount 1\npeek 3\nempty false")" ]'
mkdir -p hiddencheck; cat > hiddencheck/main.swift <<'S'
var q = Queue<String>()
print(q.dequeue() == nil, q.peek() == nil, q.isEmpty, q.count)
q.enqueue("a"); q.enqueue("b"); q.enqueue("c")
print(q.dequeue()!, q.dequeue()!, q.count)
q.enqueue("d")
print(q.dequeue()!, q.dequeue()!, q.dequeue() == nil, q.isEmpty)
S
check "hidden use" 'swiftc Queue.swift hiddencheck/main.swift -o hq 2>/dev/null && [ "$(./hq)" = "$(printf "true true true 0\na b 1\nc d true true")" ]'
exit $fail
