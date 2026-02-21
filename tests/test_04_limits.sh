#!/usr/bin/env bash
# Test Exercise 4 — Resource Limits (pam_limits)
# Configures limits for testuser, tests enforcement, cleans up.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 4 — Resource Limits (pam_limits)${RESET}"
echo ""

backup_pam

# ── Verify pam_limits is in session stack (sshd or common-session) ───
limits_found=$(ssh_server "grep -l pam_limits /etc/pam.d/sshd /etc/pam.d/common-session /etc/pam.d/su 2>/dev/null | head -1") || true
assert "pam_limits is in the PAM stack" test -n "$limits_found"

# ── Setup: add limits ───────────────────────────────────────────────
log_info "Configuring resource limits..."
ssh_server 'sudo bash -c "
cp /etc/security/limits.conf /etc/security/limits.conf.test04.bak
cat >> /etc/security/limits.conf <<\"LIMEOF\"
# == test_04 additions ==
testuser        hard    nproc           50
testuser        soft    nproc           30
testuser        hard    nofile          256
testuser        soft    nofile          128
LIMEOF
"'

# ── Test: check soft limits via su (pam_limits applies to su sessions) ─
nofile_val=$(ssh_server "sudo su - testuser -c 'ulimit -n'" 2>/dev/null) || true
assert_contains "testuser nofile soft limit is 128" "$nofile_val" "128"

nproc_val=$(ssh_server "sudo su - testuser -c 'ulimit -u'" 2>/dev/null) || true
assert_contains "testuser nproc soft limit is 30" "$nproc_val" "30"

# ── Test: cannot exceed hard limit ───────────────────────────────────
exceed_result=$(ssh_server "sudo su - testuser -c 'ulimit -n 512' 2>&1") || true
assert_contains "Cannot exceed nofile hard limit" "$exceed_result" "cannot modify limit|Operation not permitted"

# ── Test: can raise within hard limit ────────────────────────────────
within_result=$(ssh_server "sudo su - testuser -c 'ulimit -n 200 && ulimit -n'" 2>&1) || true
assert_contains "Can raise nofile within hard limit (200)" "$within_result" "200"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Restoring limits.conf..."
ssh_server 'sudo bash -c "
if [[ -f /etc/security/limits.conf.test04.bak ]]; then
    cp /etc/security/limits.conf.test04.bak /etc/security/limits.conf
    rm -f /etc/security/limits.conf.test04.bak
fi
"'

report_results "Exercise 4"
