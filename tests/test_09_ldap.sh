#!/usr/bin/env bash
# Test Exercise 9 — Centralized LDAP Authentication (sssd)
# Configures sssd on the server, verifies LDAP user resolution and SSH login.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo ""
echo "${BOLD}Exercise 9 — Centralized LDAP Authentication (sssd)${RESET}"
echo ""

backup_pam

# ── Pre-check: LDAP server is reachable ──────────────────────────────
log_info "Verifying LDAP server is reachable..."
ldap_search=$(ssh_server 'ldapsearch -x -H ldap://192.168.100.3 -b "dc=pam-lab,dc=local" -LLL "(objectClass=posixAccount)" uid' 2>&1) || true
assert_contains "LDAP server responds from server VM" "$ldap_search" "ldapuser1"
assert_contains "LDAP has ldapuser2" "$ldap_search" "ldapuser2"

# ── Setup: configure sssd ────────────────────────────────────────────
log_info "Configuring sssd..."
ssh_server 'sudo bash -c "
# Create sssd config
mkdir -p /etc/sssd
cat > /etc/sssd/sssd.conf <<\"SSSDEOF\"
[sssd]
config_file_version = 2
services = nss, pam
domains = pam-lab.local

[nss]
filter_groups = root
filter_users = root

[pam]

[domain/pam-lab.local]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://192.168.100.3
ldap_search_base = dc=pam-lab,dc=local
ldap_id_use_start_tls = false
ldap_tls_reqcert = never
cache_credentials = true
enumerate = true
ldap_user_search_base = ou=users,dc=pam-lab,dc=local
ldap_group_search_base = ou=groups,dc=pam-lab,dc=local
ldap_default_bind_dn = cn=admin,dc=pam-lab,dc=local
ldap_default_authtok = ldapadmin
ldap_auth_disable_tls_never_use_in_production = true
SSSDEOF

chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf

# Backup and configure nsswitch.conf
cp /etc/nsswitch.conf /etc/nsswitch.conf.test09.bak
sed -i \"s/^passwd:.*/passwd:         files sss/\" /etc/nsswitch.conf
sed -i \"s/^group:.*/group:          files sss/\" /etc/nsswitch.conf
sed -i \"s/^shadow:.*/shadow:         files sss/\" /etc/nsswitch.conf

# Enable auto-creation of home directories
cp /etc/pam.d/common-session /etc/pam.d/common-session.test09.bak
grep -q pam_mkhomedir /etc/pam.d/common-session || echo \"session required pam_mkhomedir.so skel=/etc/skel umask=077\" >> /etc/pam.d/common-session

# Restart sssd
systemctl restart sssd
systemctl enable sssd
"'

# Wait for sssd to enumerate users
sleep 3

# ── Test: LDAP users visible via getent ──────────────────────────────
getent_user1=$(ssh_server "getent passwd ldapuser1" 2>&1) || true
assert_contains "getent resolves ldapuser1" "$getent_user1" "ldapuser1"

getent_user2=$(ssh_server "getent passwd ldapuser2" 2>&1) || true
assert_contains "getent resolves ldapuser2" "$getent_user2" "ldapuser2"

getent_group=$(ssh_server "getent group pamtesters" 2>&1) || true
assert_contains "getent resolves pamtesters group" "$getent_group" "pamtesters"

# ── Test: SSH login with LDAP user ───────────────────────────────────
log_info "Testing SSH login with ldapuser1..."
ldap_login=$(sshpass_client_to_server "Ldap123!" ldapuser1 "whoami" 2>/dev/null) || true
assert_contains "ldapuser1 can SSH to server" "$ldap_login" "ldapuser1"

# Test second LDAP user
ldap2_login=$(sshpass_client_to_server "Ldap456!" ldapuser2 "whoami" 2>/dev/null) || true
assert_contains "ldapuser2 can SSH to server" "$ldap2_login" "ldapuser2"

# ── Test: local users still work ─────────────────────────────────────
local_login=$(sshpass_client_to_server "Test123!" testuser "echo 'Login succeeded'" 2>/dev/null) || true
assert_contains "Local user testuser still works with sssd active" "$local_login" "Login succeeded"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Cleaning up sssd configuration..."
ssh_server 'sudo bash -c "
systemctl stop sssd 2>/dev/null || true
systemctl disable sssd 2>/dev/null || true
rm -f /etc/sssd/sssd.conf

if [[ -f /etc/nsswitch.conf.test09.bak ]]; then
    cp /etc/nsswitch.conf.test09.bak /etc/nsswitch.conf
    rm -f /etc/nsswitch.conf.test09.bak
fi
if [[ -f /etc/pam.d/common-session.test09.bak ]]; then
    cp /etc/pam.d/common-session.test09.bak /etc/pam.d/common-session
    rm -f /etc/pam.d/common-session.test09.bak
fi

# Clean up LDAP user home directories
rm -rf /home/ldapuser1 /home/ldapuser2

# Clear sssd caches
rm -rf /var/lib/sss/db/* /var/lib/sss/mc/*
"'

report_results "Exercise 9"
