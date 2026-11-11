#!/bin/zsh
set -u; fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "builds" 'swift build -q >/dev/null 2>&1'
printf "hello wide world\nsecond line here\n" > h1.txt
check "two lines"  '[ "$(swift run -q textstats < h1.txt)" = "$(printf "lines 2\nwords 6\nchars 34\nlongest second")" ]'
printf "" > h2.txt
check "empty"      '[ "$(swift run -q textstats < h2.txt | sed "s/ *$//")" = "$(printf "lines 0\nwords 0\nchars 0\nlongest")" ]'
printf "aa bb" > h3.txt
check "tie + no newline" '[ "$(swift run -q textstats < h3.txt)" = "$(printf "lines 1\nwords 2\nchars 5\nlongest aa")" ]'
check "library target" 'grep -q "TextStatsCore" Package.swift && ls Sources/TextStatsCore/*.swift >/dev/null 2>&1'
exit $fail
