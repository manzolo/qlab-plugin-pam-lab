#!/usr/bin/env bash
# Test Exercise 6 — Host/User Access Control (pam_access)
# Restricts testuser to client IP only, verifies from client and localhost, cleans up.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 6 — Host/User Access Control (pam_access)${RESET}"
echo ""

backup_pam
reset_users

# ── Setup: enable pam_access for sshd ────────────────────────────────
log_info "Enabling pam_access for sshd..."
ssh_server 'sudo bash -c "
cp /etc/pam.d/sshd /etc/pam.d/sshd.test06.bak
# Add pam_access after common-account
sed -i \"/@include common-account/a account    required    pam_access.so\" /etc/pam.d/sshd
"'

# Configure access rules: testuser only from 192.168.100.2
log_info "Configuring access.conf rules..."
ssh_server 'sudo bash -c "
cp /etc/security/access.conf /etc/security/access.conf.test06.bak
cat >> /etc/security/access.conf <<\"ACCEOF\"
# == test_06 ==
+ : testuser : 192.168.100.2
- : testuser : ALL
+ : ALL : ALL
ACCEOF
"'

# ── Test: testuser from client (192.168.100.2) should work ───────────
client_result=$(sshpass_client_to_server "Test123!" testuser "echo 'Login succeeded'" 2>/dev/null) || true
assert_contains "testuser allowed from client (192.168.100.2)" "$client_result" "Login succeeded"

# ── Test: testuser from server localhost should be denied ─────────────
localhost_result=$(ssh_server "sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@localhost 'echo Login succeeded'" 2>/dev/null) || true
assert_not_contains "testuser denied from localhost" "$localhost_result" "Login succeeded"

# ── Test: alice should work from anywhere ────────────────────────────
alice_result=$(sshpass_client_to_server "Alice123!" alice "echo 'Login succeeded'" 2>/dev/null) || true
assert_contains "alice allowed from client (ALL:ALL rule)" "$alice_result" "Login succeeded"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Restoring access.conf and sshd PAM..."
ssh_server 'sudo bash -c "
if [[ -f /etc/pam.d/sshd.test06.bak ]]; then
    cp /etc/pam.d/sshd.test06.bak /etc/pam.d/sshd
    rm -f /etc/pam.d/sshd.test06.bak
fi
if [[ -f /etc/security/access.conf.test06.bak ]]; then
    cp /etc/security/access.conf.test06.bak /etc/security/access.conf
    rm -f /etc/security/access.conf.test06.bak
fi
"'
reset_users

report_results "Exercise 6"
