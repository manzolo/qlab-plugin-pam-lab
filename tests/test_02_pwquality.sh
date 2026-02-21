#!/usr/bin/env bash
# Test Exercise 2 — Password Policy (pam_pwquality)
# Configures password quality rules, tests weak/strong passwords, then cleans up.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 2 — Password Policy (pam_pwquality)${RESET}"
echo ""

backup_pam

# ── Setup ───────────────────────────────────────────────────────────
log_info "Configuring pwquality rules..."
ssh_server "sudo tee -a /etc/security/pwquality.conf >/dev/null" <<'CONF'
# == test_02 additions ==
minlen = 12
minclass = 3
maxrepeat = 3
retry = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
CONF

# Verify pam_pwquality is in the stack
pw_stack=$(ssh_server "cat /etc/pam.d/common-password")
assert_contains "pam_pwquality is in password stack" "$pw_stack" "pam_pwquality\\.so"

# ── Test weak passwords via pamtester ────────────────────────────────
# pamtester as root skips old password, only asks for new one
weak_result=$(ssh_server "echo -e 'abc\nabc' | sudo pamtester passwd testuser chauthtok" 2>&1) || true
assert_contains "Rejects 'abc' (too short)" "$weak_result" "BAD PASSWORD\|Password quality check failed\|chauthtok failed"

weak2=$(ssh_server "echo -e 'abcdefghijklm\nabcdefghijklm' | sudo pamtester passwd testuser chauthtok" 2>&1) || true
assert_contains "Rejects 'abcdefghijklm' (no uppercase/digit/special)" "$weak2" "BAD PASSWORD\|Password quality check failed\|chauthtok failed"

# ── Test strong password ─────────────────────────────────────────────
strong=$(ssh_server "echo -e 'MyStr0ng!Pass99\nMyStr0ng!Pass99' | sudo pamtester passwd testuser chauthtok" 2>&1) || true
assert_contains "Accepts 'MyStr0ng!Pass99'" "$strong" "successfully"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Restoring PAM and resetting passwords..."
ssh_server "sudo sed -i '/# == test_02 additions ==/,\$d' /etc/security/pwquality.conf"
ssh_server "echo 'testuser:Test123!' | sudo chpasswd"

report_results "Exercise 2"
