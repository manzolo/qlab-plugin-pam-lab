# pam-lab — PAM Authentication Lab

[![QLab Plugin](https://img.shields.io/badge/QLab-Plugin-blue)](https://github.com/manzolo/qlab)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey)](https://github.com/manzolo/qlab)

A [QLab](https://github.com/manzolo/qlab) plugin that boots three virtual machines for practicing PAM (Pluggable Authentication Modules) configuration, including password policies, account lockout, 2FA, and centralized LDAP authentication via sssd.

## Architecture

```
    Internal LAN (192.168.100.0/24)
┌────────────────────────────────────────────────────────────┐
│                                                            │
│  ┌──────────────────┐   ┌───────────────┐  ┌──────────────┐│
│  │  pam-lab-server  │   │pam-lab-ldap   │  │pam-lab-client││
│  │  192.168.100.1   │   │192.168.100.3  │  │              ││
│  │  PAM configs     │   │OpenLDAP       │  │192.168.100.2 ││
│  │  sssd client     │   │(pam-lab.local)│  │              ││
│  └──────────────────┘   │               │  │SSH test      ││
│                         └───────────────┘  └──────────────┘│
└────────────────────────────────────────────────────────────┘
```

## Objectives

- Understand PAM module types and control flags (required, requisite, sufficient, optional)
- Enforce password complexity with pam_pwquality
- Lock accounts after failed attempts with pam_faillock
- Set resource limits with pam_limits
- Restrict login by time and host with pam_time and pam_access
- Add custom audit scripts with pam_exec
- Configure TOTP two-factor authentication with pam_google_authenticator
- Integrate LDAP authentication via sssd

## How It Works

1. **Cloud image**: Downloads a minimal Ubuntu 22.04 cloud image (~250MB)
2. **Cloud-init**: Creates `user-data` for all VMs with PAM/LDAP packages
3. **ISO generation**: Packs cloud-init files into ISOs (cidata)
4. **Overlay disks**: Creates COW disks for each VM (original stays untouched)
5. **QEMU boot**: Starts three VMs with SSH access and a shared internal LAN

## Credentials

All VMs use the same base credentials:
- **Username:** `labuser`
- **Password:** `labpass`

Test users on the server:
- `testuser` / `Test123!`
- `alice` / `Alice123!`

LDAP users (on pam-lab-ldap):
- `ldapuser1` / `Ldap123!`
- `ldapuser2` / `Ldap456!`

## Network

| VM              | SSH (host) | Internal LAN IP  |
|-----------------|------------|------------------|
| pam-lab-server  | dynamic    | 192.168.100.1    |
| pam-lab-client  | dynamic    | 192.168.100.2    |
| pam-lab-ldap    | dynamic    | 192.168.100.3    |

> All host ports are dynamically allocated. Use `qlab ports` to see the actual mappings.

The VMs are connected by a direct internal LAN (`192.168.100.0/24`) via QEMU socket networking.

## Usage

```bash
# Install the plugin
qlab install pam-lab

# Run the lab (starts all 3 VMs)
qlab run pam-lab

# Wait ~90s for boot and package installation, then:

# Connect to the PAM server
qlab shell pam-lab-server

# Connect to the SSH client
qlab shell pam-lab-client

# Connect to the LDAP server
qlab shell pam-lab-ldap

# Stop all VMs
qlab stop pam-lab

# Stop a single VM
qlab stop pam-lab-server
qlab stop pam-lab-client
qlab stop pam-lab-ldap
```

## Exercises

> **New to PAM?** See the [Step-by-Step Guide](GUIDE.md) for complete walkthroughs with full config examples.

| # | Exercise | What you'll do |
|---|----------|----------------|
| 1 | **PAM Anatomy** | Explore `/etc/pam.d/`, understand module types and control flags |
| 2 | **Password Policy (pam_pwquality)** | Enforce minimum length, complexity, retry limits |
| 3 | **Account Lockout (pam_faillock)** | Lock accounts after N failed attempts, unlock with `faillock` |
| 4 | **Resource Limits (pam_limits)** | Set nproc, nofile, maxlogins per user/group |
| 5 | **Time-based Access (pam_time)** | Restrict login to specific times via `time.conf` |
| 6 | **Host/User Access Control (pam_access)** | Permit/deny by user and source host via `access.conf` |
| 7 | **Custom Audit (pam_exec)** | Run custom scripts on login/logout events |
| 8 | **Two-Factor Auth (pam_google_authenticator)** | Set up TOTP 2FA on SSH, scan QR, test from client |
| 9 | **LDAP + sssd** | Configure sssd for centralized LDAP authentication |

## Managing VMs

```bash
# View boot logs
qlab log pam-lab-server
qlab log pam-lab-client
qlab log pam-lab-ldap

# Check running VMs
qlab status
```

## Resetting

To start fresh, stop and re-run:

```bash
qlab stop pam-lab
qlab run pam-lab
```

Or reset the entire workspace:

```bash
qlab reset
```
