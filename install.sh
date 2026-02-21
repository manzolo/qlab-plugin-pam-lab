#!/usr/bin/env bash
# pam-lab install script

set -euo pipefail

echo ""
echo "  [pam-lab] Installing..."
echo ""
echo "  This plugin creates three VMs for practicing PAM configuration:"
echo ""
echo "    1. pam-lab-server  — PAM Server VM"
echo "       Configure PAM modules, policies, and sssd"
echo "       Practice authentication hardening"
echo ""
echo "    2. pam-lab-client  — SSH Client VM"
echo "       Test PAM policies from a remote client"
echo "       Verify lockout, time restrictions, 2FA"
echo ""
echo "    3. pam-lab-ldap   — OpenLDAP Server VM"
echo "       Pre-configured LDAP directory"
echo "       Provides centralized users for sssd integration"
echo ""
echo "  What you will learn:"
echo "    - How PAM modules work (required, requisite, sufficient, optional)"
echo "    - How to enforce password complexity with pam_pwquality"
echo "    - How to lock accounts after failed attempts with pam_faillock"
echo "    - How to set resource limits with pam_limits"
echo "    - How to restrict login by time and host with pam_time/pam_access"
echo "    - How to add custom audit scripts with pam_exec"
echo "    - How to configure TOTP two-factor authentication"
echo "    - How to integrate LDAP authentication via sssd"
echo ""

# Create lab working directory
mkdir -p lab

# Check for required tools
echo "  Checking dependencies..."
local_ok=true
for cmd in qemu-system-x86_64 qemu-img genisoimage curl; do
    if command -v "$cmd" &>/dev/null; then
        echo "    [OK] $cmd"
    else
        echo "    [!!] $cmd — not found (install before running)"
        local_ok=false
    fi
done

if [[ "$local_ok" == true ]]; then
    echo ""
    echo "  All dependencies are available."
else
    echo ""
    echo "  Some dependencies are missing. Install them with:"
    echo "    sudo apt install qemu-kvm qemu-utils genisoimage curl"
fi

echo ""
echo "  [pam-lab] Installation complete."
echo "  Run with: qlab run pam-lab"
