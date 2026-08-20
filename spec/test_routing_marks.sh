#!/bin/sh
# Regression tests for service marks accepted by the Entware proxy validator.

SOURCE=${SOURCE:-/repo/scripts/_xkeen/02_install/07_install_register/04_register_init.sh}

extract() {
    awk '/^build_allowed_policy_marks\(\) \{/,/^\}/' "$SOURCE"
}

hex_mark_to_decimal() {
    printf '%d\n' "$1" 2>/dev/null
}

eval "$(extract)"

pass=0
fail=0

check() {
    if [ "$2" = "$3" ]; then
        printf 'OK   %s\n' "$1"
        pass=$((pass + 1))
    else
        printf 'FAIL %s\n       expected [%s]\n       received [%s]\n' "$1" "$3" "$2"
        fail=$((fail + 1))
    fi
}

policy_mark="0x10"
user_policies="main|10
duplicate|10"

check "Entware mode permits bypass and recapture service marks" \
    "$(build_allowed_policy_marks yes)" "255 256 16"

check "strict PBR excludes service marks" \
    "$(build_allowed_policy_marks no)" "16"

policy_mark=""
user_policies=""

check "service marks work without Keenetic policy marks" \
    "$(build_allowed_policy_marks yes)" "255 256"

check "strict PBR remains empty without policy marks" \
    "$(build_allowed_policy_marks no)" ""

firewall_bypass_256=$(grep -Ec 'ipt .*--mark 256.*-j RETURN' "$SOURCE")
check "mark 256 is not a firewall bypass" "$firewall_bypass_256" "0"

printf '\n=== passed: %s, failed: %s ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
