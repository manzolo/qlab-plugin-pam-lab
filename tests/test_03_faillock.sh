#!/usr/bin/env bash
# Test Exercise 3 — Account Lockout (pam_faillock)
# Configures faillock, triggers lockout from client, verifies, unlocks, cleans up.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 3 — Account Lockout (pam_faillock)${RESET}"
echo ""

backup_pam
reset_users

# ── Setup: configure faillock ────────────────────────────────────────
log_info "Configuring pam_faillock in common-auth..."

# Read current common-auth and rebuild it with faillock
ssh_server 'sudo bash -c "
# Backup original
cp /etc/pam.d/common-auth /etc/pam.d/common-auth.test03.bak

# Get the pam_unix.so line and modify the success jump
# We need: preauth before pam_unix, authfail after pam_unix
# Build a new common-auth
cat > /etc/pam.d/common-auth <<\"PAMEOF\"
# common-auth — modified by test_03
auth    required    pam_faillock.so preauth silent deny=3 unlock_time=300
auth    [success=3 default=ignore]  pam_unix.so nullok
auth    [default=die] pam_faillock.so authfail deny=3 unlock_time=300
auth    requisite   pam_deny.so
auth    required    pam_permit.so
PAMEOF
"'

# Add account faillock
ssh_server 'sudo bash -c "
cp /etc/pam.d/common-account /etc/pam.d/common-account.test03.bak
# Prepend faillock to common-account
sed -i \"1i account required pam_faillock.so\" /etc/pam.d/common-account
"'

# ── Test: 3 failed attempts should lock the account ──────────────────
log_info "Attempting 3 failed logins from client..."
sshpass_client_to_server "wrongpass" testuser "echo locked" 2>/dev/null || true
sshpass_client_to_server "wrongpass" testuser "echo locked" 2>/dev/null || true
sshpass_client_to_server "wrongpass" testuser "echo locked" 2>/dev/null || true

# Now correct password should also fail (account locked)
locked_result=$(sshpass_client_to_server "Test123!" testuser "echo 'Login succeeded'" 2>/dev/null) || true
assert_not_contains "Correct password denied (account locked)" "$locked_result" "Login succeeded"

# Check faillock status on server
faillock_output=$(ssh_server "sudo faillock --user testuser" 2>&1) || true
assert_contains "faillock shows failed attempts" "$faillock_output" "testuser"

# ── Unlock and verify ────────────────────────────────────────────────
log_info "Unlocking testuser..."
ssh_server "sudo faillock --user testuser --reset"

unlock_result=$(sshpass_client_to_server "Test123!" testuser "echo 'Login succeeded'" 2>/dev/null) || true
assert_contains "Login succeeds after unlock" "$unlock_result" "Login succeeded"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Restoring PAM configuration..."
ssh_server 'sudo bash -c "
if [[ -f /etc/pam.d/common-auth.test03.bak ]]; then
    cp /etc/pam.d/common-auth.test03.bak /etc/pam.d/common-auth
    rm -f /etc/pam.d/common-auth.test03.bak
fi
if [[ -f /etc/pam.d/common-account.test03.bak ]]; then
    cp /etc/pam.d/common-account.test03.bak /etc/pam.d/common-account
    rm -f /etc/pam.d/common-account.test03.bak
fi
"'
reset_users

report_results "Exercise 3"
