#!/usr/bin/env bash
# Test Exercise 5 — Time-based Access (pam_time)
# Adds a time restriction that blocks the current time, verifies denial, cleans up.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 5 — Time-based Access (pam_time)${RESET}"
echo ""

backup_pam
reset_users

# ── Setup: enable pam_time for sshd ─────────────────────────────────
# IMPORTANT: pam_time must be placed BEFORE @include common-account because
# common-account contains pam_localuser.so with "sufficient" which, on success
# for local users, skips all subsequent account modules in the include chain.
log_info "Enabling pam_time for sshd..."
ssh_server 'sudo bash -c "
cp /etc/pam.d/sshd /etc/pam.d/sshd.test05.bak
# Add pam_time BEFORE common-account
sed -i \"/@include common-account/i account    required    pam_time.so\" /etc/pam.d/sshd
"'

# Build a time rule that denies access at the CURRENT time.
# pam_time allows access only when the time matches the rule.
# We create a rule that allows testuser only during 03:00-03:01 (1 minute window),
# which ensures denial at any other time of day.
log_info "Adding time rule to restrict testuser to 03:00-03:01 only..."
ssh_server 'sudo bash -c "
cp /etc/security/time.conf /etc/security/time.conf.test05.bak
echo \"# == test_05 ==\" >> /etc/security/time.conf
echo \"sshd;*;testuser;Al0300-0301\" >> /etc/security/time.conf
"'

# ── Test: testuser should be denied (unless you run this at 3:00 AM) ─
denied_result=$(sshpass_client_to_server "Test123!" testuser "echo 'Login succeeded'" 2>/dev/null) || true
assert_not_contains "testuser denied by time restriction" "$denied_result" "Login succeeded"

# ── Test: alice should still work (no time rule for her) ─────────────
alice_result=$(sshpass_client_to_server "Alice123!" alice "echo 'Login succeeded'" 2>/dev/null) || true
assert_contains "alice not restricted by pam_time" "$alice_result" "Login succeeded"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Restoring pam_time configuration..."
ssh_server 'sudo bash -c "
if [[ -f /etc/pam.d/sshd.test05.bak ]]; then
    cp /etc/pam.d/sshd.test05.bak /etc/pam.d/sshd
    rm -f /etc/pam.d/sshd.test05.bak
fi
if [[ -f /etc/security/time.conf.test05.bak ]]; then
    cp /etc/security/time.conf.test05.bak /etc/security/time.conf
    rm -f /etc/security/time.conf.test05.bak
fi
"'
reset_users

report_results "Exercise 5"
