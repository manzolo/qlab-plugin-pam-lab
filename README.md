# pam-lab — PAM Authentication Lab

[![QLab Plugin](https://img.shields.io/badge/QLab-Plugin-blue)](https://github.com/manzolo/qlab)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Walkthrough](https://img.shields.io/badge/walkthrough-EN%20%26%20IT-informational)](docs/walkthrough-en.pdf)

A three-VM [QLab](https://github.com/manzolo/qlab) lab — a PAM server, a client that logs
into it over the network, and an LDAP server — for learning the stack that decides whether
you get in: read it, call it directly with `pamtester`, then change it, module by module.

## Quick start

```bash
qlab install pam-lab
qlab run pam-lab             # boots 3 VMs (~120s)
qlab shell pam-lab-server    # where PAM is configured — labuser / labpass
qlab shell pam-lab-client    # logs into the server over SSH
qlab shell pam-lab-ldap      # the directory server
qlab test pam-lab            # run the automated checks
qlab stop pam-lab
```

## What's inside

| # | Exercise | Module |
|---|----------|--------|
| 1 | PAM anatomy | types & control flags in `/etc/pam.d/` |
| 2 | Password policy | `pam_pwquality` |
| 3 | Account lockout | `pam_faillock` |
| 4 | Resource limits | `pam_limits` |
| 5 | Time-based access | `pam_time` |
| 6 | Host/user access | `pam_access` |
| 7 | Custom audit | `pam_exec` |
| 8 | Two-factor auth | `pam_google_authenticator` |
| 9 | Central identity | `sssd` against LDAP |

## Network

Private LAN `192.168.100.0/24`, isolated between the three VMs.

| VM | Address | Role |
|----|---------|------|
| `pam-lab-server` | `192.168.100.1` | PAM configs, sssd client |
| `pam-lab-client` | `192.168.100.2` | logs into the server over SSH |
| `pam-lab-ldap` | `192.168.100.3` | OpenLDAP (`pam-lab.local`) |

Accounts: `labuser` / `labpass` · lab users `testuser` / `Test123!`, `alice` / `Alice123!` ·
LDAP users `ldapuser1` / `Ldap123!`, `ldapuser2` / `Ldap456!`. SSH forwarded — see `qlab ports`.

## Learn more

- 📖 **[Step-by-step guide](GUIDE.md)** — every module with full config examples
- 📄 **Illustrated walkthrough** — a real run, captured live: **[English](docs/walkthrough-en.pdf)** · **[Italiano](docs/walkthrough-it.pdf)**
- 🧩 **[QLab](https://github.com/manzolo/qlab)** — the plugin runner: how install, overlays and cloud-init work
