#!/usr/bin/env zsh
# run_pty_tests — invoke all test_p*.zsh, summarise pass/fail.

cd "${0:A:h}"

if (( $# > 0 )); then
    TESTS=("$@")
else
    TESTS=(test_p*.zsh)
fi

typeset -i PASS=0 FAIL=0
typeset -A FAILED

for t in "${TESTS[@]}"; do
    [[ -f $t ]] || { print -- "  $t: NOT FOUND"; continue }
    result=$(timeout 30 zsh "$t" 2>&1 | tail -1)
    case $result in
        PASS\ *)
            printf "  %-50s PASS\n" "$t"
            (( PASS++ ))
            ;;
        *)
            printf "  %-50s FAIL: %s\n" "$t" "$result"
            FAILED[$t]=$result
            (( FAIL++ ))
            ;;
    esac
done

print
print -- "Summary: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    print
    print -- "Failed tests:"
    for k in "${(@k)FAILED}"; do
        print -- "  $k: ${FAILED[$k]}"
    done
    exit 1
fi
exit 0
