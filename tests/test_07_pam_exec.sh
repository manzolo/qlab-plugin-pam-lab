#!/usr/bin/env bash
# Test Exercise 7 — Custom Audit (pam_exec)
# Creates an audit script, adds it to sshd session stack, triggers login, verifies log.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 7 — Custom Audit (pam_exec)${RESET}"
echo ""

backup_pam

# ── Setup: create audit script and configure PAM ─────────────────────
log_info "Creating pam-audit.sh and configuring pam_exec..."
ssh_server 'sudo bash -c "
# Create audit script
cat > /usr/local/bin/pam-audit.sh <<\"SCRIPT\"
#!/bin/bash
echo \"\$(date \"+%Y-%m-%d %H:%M:%S\") PAM_TYPE=\$PAM_TYPE USER=\$PAM_USER RHOST=\$PAM_RHOST SERVICE=\$PAM_SERVICE TTY=\$PAM_TTY\" >> /var/log/pam-audit.log
SCRIPT
chmod +x /usr/local/bin/pam-audit.sh

# Create log file
touch /var/log/pam-audit.log
chmod 666 /var/log/pam-audit.log

# Add pam_exec to sshd
cp /etc/pam.d/sshd /etc/pam.d/sshd.test07.bak
echo \"session    optional    pam_exec.so /usr/local/bin/pam-audit.sh\" >> /etc/pam.d/sshd
"'

# Clear any previous audit entries
ssh_server "sudo truncate -s 0 /var/log/pam-audit.log"

# ── Trigger a login from client ──────────────────────────────────────
log_info "Triggering login from client to generate audit entries..."
sshpass_client_to_server "Test123!" testuser "echo hello" >/dev/null 2>&1 || true
sleep 1

# ── Verify audit log ────────────────────────────────────────────────
audit_log=$(ssh_server "cat /var/log/pam-audit.log" 2>/dev/null) || true
assert_contains "Audit log has open_session entry" "$audit_log" "PAM_TYPE=open_session"
assert_contains "Audit log records USER=testuser" "$audit_log" "USER=testuser"
assert_contains "Audit log records SERVICE=sshd" "$audit_log" "SERVICE=sshd"
assert_contains "Audit log has close_session entry" "$audit_log" "PAM_TYPE=close_session"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Cleaning up pam_exec configuration..."
ssh_server 'sudo bash -c "
if [[ -f /etc/pam.d/sshd.test07.bak ]]; then
    cp /etc/pam.d/sshd.test07.bak /etc/pam.d/sshd
    rm -f /etc/pam.d/sshd.test07.bak
fi
rm -f /usr/local/bin/pam-audit.sh /var/log/pam-audit.log
"'

report_results "Exercise 7"
