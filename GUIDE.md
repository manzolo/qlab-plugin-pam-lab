# PAM Lab — Step-by-Step Guide

This guide walks you through understanding and configuring PAM (Pluggable Authentication Modules) on Linux, from basic module anatomy to centralized LDAP authentication with sssd.

## Prerequisites

Start the lab and wait for all VMs to finish booting (~90 seconds):

```bash
qlab run pam-lab
```

Open **three terminals** and connect to each VM:

```bash
# Terminal 1 — Server (where you configure PAM)
qlab shell pam-lab-server

# Terminal 2 — Client (where you test logins)
qlab shell pam-lab-client

# Terminal 3 — LDAP (OpenLDAP server, mostly hands-off)
qlab shell pam-lab-ldap
```

On each VM, make sure cloud-init has finished:

```bash
cloud-init status --wait
```

## Network Topology

Each VM has **two network interfaces**:

- **eth0** (SLIRP): for SSH access from the host (`qlab shell`)
- **Internal LAN**: a direct virtual link between the VMs (`192.168.100.0/24`)

```
        Host Machine
       ┌────────────┐
       │  SSH :auto │──────► pam-lab-server
       │  SSH :auto │──────► pam-lab-client
       │  SSH :auto │──────► pam-lab-ldap
       └────────────┘

   Internal LAN (192.168.100.0/24)
  ┌────────────────────────────────────────────────────┐
  │                                                    │
  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐│
  │  │ pam-server   │ │ pam-ldap     │ │ pam-client   ││
  │  │ 192.168.100.1│ │ 192.168.100.3│ │ 192.168.100.2││
  │  │              │◄│              │ │              ││
  │  │ PAM configs  │ │ OpenLDAP     │ │ SSH client   ││
  │  │ sssd client  │ │              │ │              ││
  │  └──────────────┘ └──────────────┘ └──────────────┘│
  └────────────────────────────────────────────────────┘
```

---

## SAFETY NET — Read This First!

PAM controls authentication. A misconfiguration can lock you out of the VM. Always follow these precautions:

### 1. Keep a backup SSH session open

Before making ANY PAM change, open a **second SSH session** to the server and keep it open. If your PAM change locks you out, you can use the backup session to fix it.

```bash
# In a separate terminal
qlab shell pam-lab-server
```

### 2. Backup PAM configuration

On **pam-lab-server**, run the backup script before each exercise:

```bash
sudo ~/pam-backup.sh
```

### 3. Restore if things go wrong

If you get locked out or something breaks:

```bash
sudo ~/pam-restore.sh
sudo systemctl restart sshd
```

### 4. Nuclear option — reset the VM

If all else fails:

```bash
# On the host
qlab stop pam-lab
qlab run pam-lab
```

---

## Exercise 1 — PAM Anatomy

**VM:** pam-lab-server
**Goal:** Understand the PAM configuration structure.

### 1.1 Explore PAM configuration directory

On **pam-lab-server**:

```bash
ls -la /etc/pam.d/
```

Each file corresponds to a service (sshd, login, sudo, etc.).

### 1.2 Examine the SSH PAM config

```bash
cat /etc/pam.d/sshd
```

Notice the `@include` directives — these pull in shared configs:

```bash
cat /etc/pam.d/common-auth
cat /etc/pam.d/common-account
cat /etc/pam.d/common-password
cat /etc/pam.d/common-session
```

### 1.3 Understand the four PAM types

Each line in a PAM file follows this format:

```
type  control  module  [arguments]
```

| Type | When it runs |
|------|-------------|
| `auth` | Verifies the user's identity (password, token, etc.) |
| `account` | Checks if the account is allowed to log in (expiry, time, etc.) |
| `password` | Handles password changes |
| `session` | Sets up/tears down the session (env vars, home dir, etc.) |

### 1.4 Understand the control flags

| Control | Behavior |
|---------|----------|
| `required` | Must pass, but continues checking other modules |
| `requisite` | Must pass, fails immediately if it doesn't |
| `sufficient` | If it passes, stops checking (success). If it fails, continues |
| `optional` | Result is ignored unless it's the only module for this type |

### 1.5 Test with pamtester

> **Note:** `pamtester` needs root privileges to read `/etc/shadow`, so always use `sudo`.

```bash
# Test authentication for testuser
sudo pamtester login testuser authenticate
# Enter password: Test123!

# Test with wrong password
sudo pamtester login testuser authenticate
# Enter password: wrongpassword
```

---

## Exercise 2 — Password Policy (pam_pwquality)

**VM:** pam-lab-server
**Goal:** Enforce password complexity rules.

### 2.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 2.2 Check current pwquality config

```bash
cat /etc/security/pwquality.conf
```

### 2.3 Configure password complexity

Edit the config:

```bash
sudo nano /etc/security/pwquality.conf
```

Add or modify these lines:

```
minlen = 12
minclass = 3
maxrepeat = 3
retry = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
```

These settings require:
- Minimum 12 characters
- At least 3 character classes (uppercase, lowercase, digit, special)
- No more than 3 consecutive identical characters
- At least 1 digit, 1 uppercase, 1 lowercase, 1 special character

### 2.4 Verify pam_pwquality is in the PAM stack

```bash
grep pwquality /etc/pam.d/common-password
```

You should see a line like:

```
password  requisite  pam_pwquality.so retry=3
```

### 2.5 Test password changes

```bash
# Switch to testuser
su - testuser
# Enter: Test123!

# Try changing to a weak password
passwd
# Enter current: Test123!
# Enter new: abc
# Should be rejected!

# Try a strong password
passwd
# Enter current: Test123!
# Enter new: MyStr0ng!Pass99
# Should succeed
```

### 2.6 Test with pamtester

```bash
# Back as labuser
exit

# With sudo, pamtester runs as root — it skips the old password
# and only asks for the new one (twice)
sudo pamtester passwd testuser chauthtok
# New password: abc          → should be rejected by pam_pwquality!
# New password: MyStr0ng!Pass99  → should succeed
```

---

## Exercise 3 — Account Lockout (pam_faillock)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Lock accounts after failed login attempts.

### 3.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 3.2 Configure pam_faillock

On **pam-lab-server**, edit `/etc/pam.d/common-auth`:

```bash
sudo nano /etc/pam.d/common-auth
```

Add these lines **before** the `pam_unix.so` line:

```
auth    required    pam_faillock.so preauth silent deny=3 unlock_time=300
```

Add this line **after** the `pam_unix.so` line:

```
auth    [default=die] pam_faillock.so authfail deny=3 unlock_time=300
```

The file should look like:

```
auth    required    pam_faillock.so preauth silent deny=3 unlock_time=300
auth    [success=1 default=ignore]  pam_unix.so nullok
auth    [default=die] pam_faillock.so authfail deny=3 unlock_time=300
auth    requisite   pam_deny.so
auth    required    pam_permit.so
```

Also add to `/etc/pam.d/common-account`:

```bash
sudo nano /etc/pam.d/common-account
```

Add at the top:

```
account required pam_faillock.so
```

### 3.3 Test from the client

On **pam-lab-client**, attempt 3 failed logins:

```bash
sshpass -p 'wrongpass' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
sshpass -p 'wrongpass' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
sshpass -p 'wrongpass' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
```

Now try with the correct password — it should be locked:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
```

### 3.4 Check lock status on the server

On **pam-lab-server**:

```bash
sudo faillock --user testuser
```

### 3.5 Unlock the account

```bash
sudo faillock --user testuser --reset
```

### 3.6 Verify unlock

From **pam-lab-client**:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
# Should work now!
```

---

## Exercise 4 — Resource Limits (pam_limits)

**VM:** pam-lab-server
**Goal:** Set resource limits per user/group.

### 4.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 4.2 Check current limits

```bash
# Check testuser's limits
su - testuser -c "ulimit -a"
```

### 4.3 Configure limits

On **pam-lab-server**, edit the limits config:

```bash
sudo nano /etc/security/limits.conf
```

Add these lines at the end (before `# End of file`):

```
# Max number of processes for testuser
testuser        hard    nproc           50
testuser        soft    nproc           30

# Max open files for testuser
testuser        hard    nofile          256
testuser        soft    nofile          128

# Max simultaneous logins for alice
alice           hard    maxlogins       2

# Max open files for all users
*               soft    nofile          1024
*               hard    nofile          4096
```

### 4.4 Verify pam_limits is active

```bash
grep limits /etc/pam.d/common-session
```

You should see:

```
session required pam_limits.so
```

### 4.5 Test the limits

```bash
# Switch to testuser
su - testuser

# Check the limits
ulimit -u    # max user processes (should be 30 soft)
ulimit -n    # max open files (should be 128 soft)

# Try to exceed the hard limit
ulimit -n 512  # Should fail (hard limit is 256)

exit
```

### 4.6 Test maxlogins for alice

Open two SSH sessions to alice on the server:

```bash
# Session 1
su - alice
# Session 2 (in another terminal on the server)
su - alice
# Session 3 — should be rejected
su - alice
```

---

## Exercise 5 — Time-based Access (pam_time)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Restrict login access based on time.

### 5.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 5.2 Enable pam_time for SSH

On **pam-lab-server**, add pam_time to the SSH account stack:

```bash
sudo nano /etc/pam.d/sshd
```

Add this line after the `@include common-account` line:

```
account    required    pam_time.so
```

### 5.3 Configure time restrictions

```bash
sudo nano /etc/security/time.conf
```

Add a rule to restrict testuser. The format is:

```
services;ttys;users;times
```

Example — deny testuser SSH on weekends:

```
sshd;*;testuser;!SaSu0000-2400
```

Example — allow testuser SSH only during business hours (Mon-Fri 08:00-18:00):

```
sshd;*;testuser;Wk0800-1800
```

### 5.4 Test the restriction

Check the current time on the server:

```bash
date
```

If the current time falls outside the allowed window, test from **pam-lab-client**:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
```

### 5.5 Verify that alice is NOT restricted

```bash
sshpass -p 'Alice123!' ssh -o StrictHostKeyChecking=no alice@192.168.100.1
# Should always work (no time restriction for alice)
```

### 5.6 Clean up

Remove or comment out the rule in `/etc/security/time.conf` when done.

---

## Exercise 6 — Host/User Access Control (pam_access)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Control who can log in from which host.

### 6.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 6.2 Enable pam_access for SSH

On **pam-lab-server**:

```bash
sudo nano /etc/pam.d/sshd
```

Add after `@include common-account`:

```
account    required    pam_access.so
```

### 6.3 Configure access rules

```bash
sudo nano /etc/security/access.conf
```

The format is:

```
+ : user : origin
- : user : origin
```

Example — allow testuser only from the client VM, deny from everywhere else:

```
+ : testuser : 192.168.100.2
- : testuser : ALL
+ : ALL : ALL
```

### 6.4 Test from the client

From **pam-lab-client** (192.168.100.2):

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
# Should work (allowed from 192.168.100.2)
```

### 6.5 Test from the server itself

On **pam-lab-server**:

```bash
ssh testuser@localhost
# Should be denied (not from 192.168.100.2)
```

### 6.6 Verify alice is not restricted

From **pam-lab-client**:

```bash
sshpass -p 'Alice123!' ssh -o StrictHostKeyChecking=no alice@192.168.100.1
# Should work (ALL : ALL allows everyone else)
```

### 6.7 Clean up

Remove or comment out the rules in `/etc/security/access.conf` when done.

---

## Exercise 7 — Custom Audit (pam_exec)

**VM:** pam-lab-server
**Goal:** Run custom scripts on authentication events.

### 7.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 7.2 Create an audit script

On **pam-lab-server**:

```bash
sudo nano /usr/local/bin/pam-audit.sh
```

Content:

```bash
#!/bin/bash
echo "$(date '+%Y-%m-%d %H:%M:%S') PAM_TYPE=$PAM_TYPE USER=$PAM_USER RHOST=$PAM_RHOST SERVICE=$PAM_SERVICE TTY=$PAM_TTY" >> /var/log/pam-audit.log
```

Make it executable:

```bash
sudo chmod +x /usr/local/bin/pam-audit.sh
sudo touch /var/log/pam-audit.log
sudo chmod 666 /var/log/pam-audit.log
```

### 7.3 Add pam_exec to the session stack

```bash
sudo nano /etc/pam.d/sshd
```

Add at the end of the file:

```
session    optional    pam_exec.so /usr/local/bin/pam-audit.sh
```

### 7.4 Test by logging in

From **pam-lab-client** or another session:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1 "echo hello"
```

### 7.5 Check the audit log

On **pam-lab-server**:

```bash
cat /var/log/pam-audit.log
```

You should see entries like:

```
2024-01-15 10:30:00 PAM_TYPE=open_session USER=testuser RHOST=192.168.100.2 SERVICE=sshd TTY=
```

### 7.6 Add auth event logging

You can also log authentication attempts by adding to the auth stack:

```bash
sudo nano /etc/pam.d/sshd
```

Add before the `@include common-auth` line:

```
auth    optional    pam_exec.so /usr/local/bin/pam-audit.sh
```

---

## Exercise 8 — Two-Factor Auth TOTP (pam_google_authenticator)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Set up TOTP-based two-factor authentication for SSH.

### 8.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 8.2 Generate TOTP secret for testuser

On **pam-lab-server**, switch to testuser and run the setup:

```bash
su - testuser
google-authenticator
```

Answer the prompts:

1. **Do you want authentication tokens to be time-based (y/n):** `y`
2. You'll see a QR code and a secret key — **save the secret key!**
3. **Enter the code from your app:** (enter the code from your TOTP app or use the secret key)
4. **Do you want me to update your ~/.google_authenticator file?** `y`
5. **Disallow multiple uses of the same token?** `y`
6. **Increase the window?** `n`
7. **Enable rate-limiting?** `y`

```bash
exit  # back to labuser
```

### 8.3 Configure PAM for 2FA

On **pam-lab-server**:

```bash
sudo nano /etc/pam.d/sshd
```

Add after `@include common-auth`:

```
auth    required    pam_google_authenticator.so
```

### 8.4 Configure SSH for 2FA

```bash
sudo nano /etc/ssh/sshd_config
```

Make sure these settings are set:

```
ChallengeResponseAuthentication yes
KbdInteractiveAuthentication yes
AuthenticationMethods keyboard-interactive
```

Restart SSH:

```bash
sudo systemctl restart sshd
```

### 8.5 Test from the client

From **pam-lab-client**:

```bash
ssh testuser@192.168.100.1
```

You should be prompted for:
1. Password (`Test123!`)
2. Verification code (from your TOTP app)

### 8.6 Fallback — if you don't have a TOTP app

You can use the emergency scratch codes that were shown during setup. They are stored in:

```bash
# On pam-lab-server as testuser
cat ~/.google_authenticator
```

The codes at the bottom of the file are one-time emergency codes.

### 8.7 Clean up

To disable 2FA, remove the `pam_google_authenticator.so` line from `/etc/pam.d/sshd` and restore the SSH config:

```bash
sudo nano /etc/pam.d/sshd
# Remove the pam_google_authenticator.so line

sudo sed -i 's/^AuthenticationMethods.*/# &/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

## Exercise 9 — Centralized LDAP Authentication (sssd)

**VM:** pam-lab-server, pam-lab-ldap
**Goal:** Configure sssd to authenticate users against the OpenLDAP server.

### 9.1 Verify LDAP is working

On **pam-lab-ldap**, verify the directory has users:

```bash
ldapsearch -x -H ldap://localhost -b "dc=pam-lab,dc=local" -LLL "(objectClass=posixAccount)" uid cn
```

You should see `ldapuser1` and `ldapuser2`.

From **pam-lab-server**, verify you can reach LDAP:

```bash
ldapsearch -x -H ldap://192.168.100.3 -b "dc=pam-lab,dc=local" -LLL "(objectClass=posixAccount)" uid cn
```

### 9.2 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 9.3 Configure sssd

On **pam-lab-server**, create the sssd config:

```bash
sudo nano /etc/sssd/sssd.conf
```

Content:

```ini
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
```

Set the correct permissions:

```bash
sudo chmod 600 /etc/sssd/sssd.conf
sudo chown root:root /etc/sssd/sssd.conf
```

### 9.4 Configure NSS to use sssd

On **pam-lab-server**:

```bash
sudo nano /etc/nsswitch.conf
```

Modify the `passwd`, `group`, and `shadow` lines to include `sss`:

```
passwd:         files sss
group:          files sss
shadow:         files sss
```

### 9.5 Enable PAM sssd modules

On **pam-lab-server**, check that pam_sss is in the PAM stack:

```bash
grep pam_sss /etc/pam.d/common-auth
grep pam_sss /etc/pam.d/common-account
grep pam_sss /etc/pam.d/common-session
grep pam_sss /etc/pam.d/common-password
```

If the lines are missing, add them. For example in `/etc/pam.d/common-auth`:

```bash
sudo nano /etc/pam.d/common-auth
```

Add after the `pam_unix.so` line:

```
auth    [success=1 default=ignore]  pam_sss.so use_first_pass
```

Similarly for common-account, common-session, and common-password:

```bash
# common-account — add:
account [default=bad success=ok user_unknown=ignore] pam_sss.so

# common-session — add:
session optional pam_sss.so

# common-password — add:
password sufficient pam_sss.so use_authtok
```

### 9.6 Enable automatic home directory creation

```bash
sudo nano /etc/pam.d/common-session
```

Add:

```
session required pam_mkhomedir.so skel=/etc/skel umask=077
```

### 9.7 Start sssd

```bash
sudo systemctl restart sssd
sudo systemctl enable sssd
```

### 9.8 Verify LDAP users are visible

```bash
# Check if LDAP users are visible via NSS
getent passwd ldapuser1
getent passwd ldapuser2

# Check the group
getent group pamtesters
```

You should see the LDAP users with their UIDs (10001, 10002).

### 9.9 Test SSH login with LDAP user

From **pam-lab-client**:

```bash
sshpass -p 'Ldap123!' ssh -o StrictHostKeyChecking=no ldapuser1@192.168.100.1
```

You should be logged in as `ldapuser1` with a home directory automatically created.

```bash
whoami
pwd
id
exit
```

### 9.10 Test the second LDAP user

```bash
sshpass -p 'Ldap456!' ssh -o StrictHostKeyChecking=no ldapuser2@192.168.100.1
whoami
id
exit
```

### 9.11 Verify the PAM stack works end-to-end

From **pam-lab-client**, verify that local users still work:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no testuser@192.168.100.1
exit
```

And LDAP users work:

```bash
sshpass -p 'Ldap123!' ssh -o StrictHostKeyChecking=no ldapuser1@192.168.100.1
exit
```

---

## Troubleshooting

### PAM changes locked me out

Use your backup SSH session (that you kept open!) to restore:

```bash
sudo ~/pam-restore.sh
sudo systemctl restart sshd
```

If you don't have a backup session, reset the VM:

```bash
# On the host
qlab stop pam-lab
qlab run pam-lab
```

### sshd won't start after PAM changes

Check the config:

```bash
sudo sshd -t
sudo journalctl -u sshd -n 20 --no-pager
```

Restore PAM config:

```bash
sudo ~/pam-restore.sh
sudo systemctl restart sshd
```

### faillock not working

Make sure pam_faillock is in **both** `common-auth` (auth stack) and `common-account` (account stack). The order matters — `preauth` must come before `pam_unix.so`, and `authfail` must come after.

### pam_pwquality not enforcing rules

Check that `/etc/security/pwquality.conf` is readable and has no syntax errors:

```bash
sudo cat /etc/security/pwquality.conf
```

Verify it's in the PAM stack:

```bash
grep pwquality /etc/pam.d/common-password
```

### sssd won't start

Check the config file permissions (must be 600):

```bash
ls -la /etc/sssd/sssd.conf
sudo chmod 600 /etc/sssd/sssd.conf
```

Check sssd logs:

```bash
sudo journalctl -u sssd -n 50 --no-pager
sudo cat /var/log/sssd/sssd.log
sudo cat /var/log/sssd/sssd_pam-lab.local.log
```

### LDAP users not visible with getent

1. Verify sssd is running: `sudo systemctl status sssd`
2. Verify LDAP is reachable: `ldapsearch -x -H ldap://192.168.100.3 -b "dc=pam-lab,dc=local" -LLL`
3. Check nsswitch.conf includes `sss`
4. Clear sssd cache: `sudo sss_cache -E && sudo systemctl restart sssd`

### Can't connect between VMs

1. Check network: `ping 192.168.100.1` (from client), `ping 192.168.100.3` (from server)
2. Verify cloud-init finished: `cloud-init status --wait`
3. Check slapd is running on LDAP VM: `sudo systemctl status slapd`
4. Check sshd is running on server: `sudo systemctl status sshd`

### General: packages not installed

Cloud-init may still be running:

```bash
cloud-init status --wait
```
