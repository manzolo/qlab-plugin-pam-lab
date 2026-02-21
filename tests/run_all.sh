#!/usr/bin/env bash
# run_all.sh — Run all pam-lab exercise tests in order
#
# Usage:
#   bash tests/run_all.sh              # run all tests
#   bash tests/run_all.sh --skip 09    # skip exercise 9 (LDAP)
#
# Prerequisites: pam-lab VMs must be running (qlab run pam-lab)

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/_common.sh"

# ── Parse arguments ─────────────────────────────────────────────────
SKIP_TESTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip) shift; SKIP_TESTS+=("$1"); shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

should_skip() {
    local num="$1"
    for s in "${SKIP_TESTS[@]+"${SKIP_TESTS[@]}"}"; do
        if [[ "$num" == "$s" ]]; then
            return 0
        fi
    done
    return 1
}

# ── Pre-flight checks ──────────────────────────────────────────────
echo ""
echo "${BOLD}=========================================${RESET}"
echo "${BOLD}  pam-lab — Automated Test Suite${RESET}"
echo "${BOLD}=========================================${RESET}"
echo ""

log_info "Workspace: $WORKSPACE_DIR"
log_info "Server port: $SERVER_PORT"
log_info "Client port: $CLIENT_PORT"
log_info "LDAP port: ${LDAP_PORT:-N/A}"

# Verify VMs are reachable
log_info "Checking VM connectivity..."
assert "Server VM is reachable via SSH" ssh_server "echo ok"
assert "Client VM is reachable via SSH" ssh_client "echo ok"

# Verify cloud-init has finished
log_info "Checking cloud-init status..."
server_ci=$(ssh_server "cloud-init status 2>/dev/null || echo done") || true
assert_contains "Server cloud-init is done" "$server_ci" "done\|status: done"

client_ci=$(ssh_client "cloud-init status 2>/dev/null || echo done") || true
assert_contains "Client cloud-init is done" "$client_ci" "done\|status: done"

# Reset to clean state before starting
reset_users

# ── Run tests ───────────────────────────────────────────────────────
TOTAL_PASS=0
TOTAL_FAIL=0
TESTS_RUN=0
TESTS_SKIPPED=0
FAILED_EXERCISES=()

run_test() {
    local num="$1"
    local script="$TESTS_DIR/test_${num}_*.sh"

    # Expand glob
    local files=($script)
    if [[ ! -f "${files[0]}" ]]; then
        log_info "Test file not found: $script"
        return
    fi

    if should_skip "$num"; then
        log_info "Skipping exercise $num"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        return
    fi

    # Reset state between tests
    reset_users >/dev/null 2>&1

    # Run the test in a subshell to isolate counters
    local test_exit=0
    bash "${files[0]}" || test_exit=$?

    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$test_exit" -ne 0 ]]; then
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        FAILED_EXERCISES+=("$num")
    else
        TOTAL_PASS=$((TOTAL_PASS + 1))
    fi
}

run_test "01"
run_test "02"
run_test "03"
run_test "04"
run_test "05"
run_test "06"
run_test "07"
run_test "09"

# ── Final report ────────────────────────────────────────────────────
echo ""
echo "${BOLD}=========================================${RESET}"
echo "${BOLD}  Final Report${RESET}"
echo "${BOLD}=========================================${RESET}"
echo ""
echo "  Exercises run:     $TESTS_RUN"
echo "  Exercises passed:  $TOTAL_PASS"
echo "  Exercises failed:  $TOTAL_FAIL"
echo "  Exercises skipped: $TESTS_SKIPPED"

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    echo ""
    printf "${RED}${BOLD}  FAILED exercises: %s${RESET}\n" "${FAILED_EXERCISES[*]}"
    exit 1
else
    echo ""
    printf "${GREEN}${BOLD}  All exercises passed!${RESET}\n"
    exit 0
fi
