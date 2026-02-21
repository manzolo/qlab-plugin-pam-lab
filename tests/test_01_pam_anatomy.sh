#!/usr/bin/env bash
# Test Exercise 1 — PAM Anatomy
# Verifies PAM configuration files exist and have the expected structure.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 1 — PAM Anatomy${RESET}"
echo ""

# 1.1 PAM directory exists and contains expected service files
output=$(ssh_server "ls /etc/pam.d/")
assert "PAM directory contains sshd" echo "$output" \| grep -q "sshd"
assert "PAM directory contains login" echo "$output" \| grep -q "login"
assert "PAM directory contains sudo"  echo "$output" \| grep -q "sudo"

# 1.2 SSH PAM config includes common files
sshd_pam=$(ssh_server "cat /etc/pam.d/sshd")
assert_contains "sshd includes common-auth"    "$sshd_pam" "@include common-auth"
assert_contains "sshd includes common-account" "$sshd_pam" "@include common-account"
assert_contains "sshd includes common-session" "$sshd_pam" "@include common-session"

# 1.3 Common files exist and contain expected modules
common_auth=$(ssh_server "cat /etc/pam.d/common-auth")
assert_contains "common-auth contains pam_unix.so" "$common_auth" "pam_unix\\.so"

common_account=$(ssh_server "cat /etc/pam.d/common-account")
assert_contains "common-account contains pam_unix.so" "$common_account" "pam_unix\\.so"

common_password=$(ssh_server "cat /etc/pam.d/common-password")
assert_contains "common-password contains pam_unix.so" "$common_password" "pam_unix\\.so"

common_session=$(ssh_server "cat /etc/pam.d/common-session")
assert_contains "common-session contains pam_unix.so" "$common_session" "pam_unix\\.so"

# 1.5 pamtester is available
assert "pamtester is installed" ssh_server "which pamtester"

# Test pamtester with correct password
pam_result=$(ssh_server "echo 'Test123!' | sudo pamtester login testuser authenticate" 2>&1) || true
assert_contains "pamtester accepts correct password" "$pam_result" "successfully authenticated"

# Test pamtester with wrong password
pam_fail=$(ssh_server "echo 'wrongpass' | sudo pamtester login testuser authenticate" 2>&1) || true
assert_contains "pamtester rejects wrong password" "$pam_fail" "[Aa]uthentication failure"

report_results "Exercise 1"
