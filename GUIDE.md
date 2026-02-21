# PAM Lab — Step-by-Step Guide

This guide walks you through understanding and configuring **PAM (Pluggable Authentication Modules)** on Linux. PAM is the framework that sits between applications (like SSH, `login`, `sudo`) and the actual authentication mechanisms (passwords, tokens, LDAP, etc.). Every time you type a password on a Linux system, PAM is involved.

By the end of this lab you will understand how PAM works internally, and you will be able to harden a real Linux server with password policies, account lockout, access restrictions, two-factor authentication, and centralized LDAP login.

## Prerequisites

Start the lab and wait for all VMs to finish booting (~90 seconds):

```bash
qlab run pam-lab
```

Open **three terminals** and connect to each VM:

```bash
# Terminal 1 — Server (where you configure PAM)
qlab shell pam-lab-server

# Terminal 2 — Client (where you test logins remotely)
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

**About `sshpass`:** In this lab we use `sshpass` to automate password entry during SSH tests. We always add `-o PubkeyAuthentication=no` to force SSH to use password authentication — without this flag, SSH would use key-based auth and PAM would never see the password, making our PAM rules useless.

---

## SAFETY NET — Read This First!

PAM controls **all authentication** on the system. A misconfiguration can lock you out of the VM entirely — including root. This is not a theoretical risk: it happens easily and it will happen to you if you're not careful. Always follow these precautions:

### 1. Keep a backup SSH session open

Before making ANY PAM change, open a **second SSH session** to the server **and keep it open**. This session was authenticated before your change, so it stays valid even if your new PAM config is broken. If your change locks you out, you can use this backup session to fix it.

```bash
# In a separate terminal — KEEP THIS OPEN
qlab shell pam-lab-server
```

### 2. Backup PAM configuration

On **pam-lab-server**, run the backup script **before each exercise**:

```bash
sudo ~/pam-backup.sh
```

This saves a timestamped copy of all PAM configuration files (`/etc/pam.d/`, `/etc/security/*.conf`, `/etc/sssd/`).

### 3. Restore if things go wrong

If you get locked out or something breaks, use your backup session:

```bash
sudo ~/pam-restore.sh
sudo systemctl restart sshd
```

### 4. Nuclear option — reset the VM

If even the backup session is gone (you closed it!), reset everything from the host:

```bash
# On the host
qlab stop pam-lab
qlab run pam-lab
```

This destroys and recreates all VMs from scratch.

---

## Exercise 1 — PAM Anatomy

**VM:** pam-lab-server
**Goal:** Understand how PAM configuration files are structured before changing anything.

PAM is not a single program — it's a **framework**. Each application that needs authentication (SSH, login, sudo, su, passwd...) has its own PAM configuration file that defines which checks to perform and in what order. Think of it as a pipeline: each module in the pipeline performs one check, and the results are combined to decide if access is granted.

### 1.1 Explore the PAM configuration directory

On **pam-lab-server**:

```bash
ls /etc/pam.d/
```

Each file in this directory corresponds to a **service** — the name of the program that uses PAM. For example:
- `sshd` — used when someone connects via SSH
- `login` — used for local console login
- `sudo` — used when running `sudo`
- `su` — used when switching users with `su`
- `passwd` — used when changing passwords

### 1.2 Examine the SSH PAM configuration

Let's look at the file that controls SSH authentication:

```bash
cat /etc/pam.d/sshd
```

You'll notice `@include` directives — these pull in shared configuration files so that all services use the same base rules. This is the standard Ubuntu approach: instead of duplicating rules in every service file, common rules are defined once and included everywhere.

Look at the shared files one by one:

```bash
# How passwords are verified (authentication)
cat /etc/pam.d/common-auth

# Whether the account is allowed to log in (not expired, not locked, etc.)
cat /etc/pam.d/common-account

# Rules for changing passwords (complexity, history, etc.)
cat /etc/pam.d/common-password

# What happens when a session starts/ends (env vars, home dir, logging)
cat /etc/pam.d/common-session
```

### 1.3 Understand the four PAM types

Each line in a PAM file follows this format:

```
type  control  module  [arguments]
```

The **type** determines *when* the module runs during the authentication process:

| Type | Purpose | Example |
|------|---------|---------|
| `auth` | **"Who are you?"** — verifies identity (checks password, token, fingerprint) | `pam_unix.so` checks the password against `/etc/shadow` |
| `account` | **"Are you allowed in?"** — checks if the account can be used right now | `pam_faillock.so` checks if the account is locked |
| `password` | **"Change your password"** — handles password changes | `pam_pwquality.so` enforces complexity rules |
| `session` | **"Set up your workspace"** — runs when a session opens or closes | `pam_limits.so` applies resource limits |

These four types run in a specific order: `auth` first, then `account`, then `session` (on login). `password` only runs when someone changes their password.

### 1.4 Understand the control flags

The **control** flag tells PAM what to do if a module succeeds or fails:

| Control | What happens on failure | What happens on success |
|---------|------------------------|------------------------|
| `required` | Marks the overall result as "fail", but **keeps running** the remaining modules. The user won't know which module failed (this is intentional — it prevents information leakage). | Continues to next module |
| `requisite` | Marks the result as "fail" and **stops immediately**. No other modules run. | Continues to next module |
| `sufficient` | Ignored — continues to next module | **Stops immediately with success** (unless a previous `required` already failed) |
| `optional` | Ignored (unless it's the only module for this type) | Ignored |

**Why does this matter?** The order of modules and their control flags completely determines the authentication behavior. A `sufficient` module before a `required` one can bypass the check entirely. This is exactly how PAM achieves its flexibility — and why misconfigurations are so dangerous.

### 1.5 Test with pamtester

`pamtester` is a utility that lets you test PAM without actually logging in. It calls the same PAM functions that `sshd` or `login` would call.

> **Note:** `pamtester` needs root privileges to read `/etc/shadow`, so always use `sudo`.

```bash
# Test authentication for testuser with the correct password
sudo pamtester login testuser authenticate
# Enter password: Test123!
# Expected: "pamtester: successfully authenticated"

# Now test with a wrong password
sudo pamtester login testuser authenticate
# Enter password: wrongpassword
# Expected: "pamtester: Authentication failure"
```

Notice how the failure message doesn't tell you *what* was wrong — it just says "Authentication failure". This is by design: PAM deliberately avoids telling attackers whether the username exists, the password was wrong, or the account is locked.

---

## Exercise 2 — Password Policy (pam_pwquality)

**VM:** pam-lab-server
**Goal:** Learn how to enforce password complexity rules so users can't set weak passwords.

In a real server environment, users tend to pick short, simple passwords ("password123", "qwerty"). The `pam_pwquality` module checks new passwords against a set of rules and rejects those that are too weak. It only runs during password **changes** (type `password`), not during login.

### 2.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 2.2 Look at the current password quality configuration

```bash
cat /etc/security/pwquality.conf
```

You'll see a file full of comments explaining each option. Most values are commented out, meaning the defaults apply (which are quite permissive).

### 2.3 Configure strict password complexity

Edit the configuration file:

```bash
sudo nano /etc/security/pwquality.conf
```

Add or modify these lines (you can put them at the end of the file):

```
# Minimum password length
minlen = 12

# Minimum number of character classes (uppercase, lowercase, digits, special)
# A password with only lowercase letters has 1 class; "Password1!" has 4 classes
minclass = 3

# Maximum number of consecutive identical characters (aaa = 3)
maxrepeat = 3

# How many times the user can retry before passwd gives up
retry = 3

# Require at least 1 of each type (-1 means "at least one required")
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
```

**What do the credit options mean?** The `*credit` values are confusing because negative means "require at least N". So `dcredit = -1` means "require at least 1 digit". A positive value would give "bonus credits" toward the minimum length, but negative values are more intuitive and commonly used.

### 2.4 Verify pam_pwquality is in the PAM stack

The module needs to be referenced in the PAM configuration to have any effect:

```bash
grep pwquality /etc/pam.d/common-password
```

You should see something like:

```
password  requisite  pam_pwquality.so retry=3
```

This tells PAM: "Before allowing a password change, run pam_pwquality. If it fails (`requisite`), stop immediately and reject the change."

### 2.5 Test password policy with `passwd`

Now let's see the policy in action. Switch to testuser and try changing the password:

```bash
# Switch to testuser
su - testuser
# Enter password: Test123!
```

Try setting a weak password:

```bash
passwd
# Current password: Test123!
# New password: abc
```

You should see a rejection message like "BAD PASSWORD: The password is shorter than 8 characters". Try a few more weak passwords to see the different rejection messages:
- `abcdefghijklm` — rejected (no uppercase, no digit, no special)
- `Abcdefgh1` — rejected (too short if minlen=12)
- `aaaaaBBBB111!` — might be rejected for too many repeats

Now try a strong password that meets all the rules:

```bash
passwd
# Current password: Test123!
# New password: MyStr0ng!Pass99
# Retype: MyStr0ng!Pass99
```

This should succeed. When you're done testing:

```bash
# Restore the original password for future exercises
passwd
# Current password: MyStr0ng!Pass99
# New password: Test123!
# (If Test123! is rejected by your new rules, that's expected!
#  Use a password that meets your rules, or restore with the backup script)

exit  # back to labuser
```

### 2.6 Test with pamtester

You can also test the password change flow with `pamtester`:

```bash
# With sudo, pamtester runs as root — it skips the old password
# and only asks for the new one (twice)
sudo pamtester passwd testuser chauthtok
# New password: abc          → should be rejected by pam_pwquality!
# New password: MyStr0ng!Pass99  → should succeed
```

**Tip:** After testing, restore testuser's password: `echo "testuser:Test123!" | sudo chpasswd`

---

## Exercise 3 — Account Lockout (pam_faillock)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Automatically lock an account after too many failed login attempts.

This is a critical security feature: if someone tries to brute-force a password, `pam_faillock` will lock the account after N failures, making the attack useless. After a configurable timeout (or manual intervention), the account unlocks automatically.

### 3.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 3.2 How pam_faillock works

`pam_faillock` needs to be called **twice** in the auth stack:

1. **Before** `pam_unix.so` (the password check) — with the `preauth` argument. This checks if the account is already locked and denies access immediately if so.
2. **After** `pam_unix.so` — with the `authfail` argument. This records the failure if the password was wrong.

It also needs an entry in the `account` stack to actually enforce the lock.

### 3.3 Configure pam_faillock

On **pam-lab-server**, edit the common authentication file:

```bash
sudo nano /etc/pam.d/common-auth
```

You need to add two lines. Find the line that contains `pam_unix.so` and add one line **before** it and one line **after** it:

```
auth    required    pam_faillock.so preauth silent deny=3 unlock_time=300
auth    [success=2 default=ignore]  pam_unix.so nullok
auth    [default=die] pam_faillock.so authfail deny=3 unlock_time=300
```

**What do the options mean?**
- `preauth` — this is the "check before authenticating" call
- `silent` — don't show messages about the lock to the user (prevents information leakage)
- `deny=3` — lock the account after 3 failed attempts
- `unlock_time=300` — automatically unlock after 300 seconds (5 minutes)
- `authfail` — this is the "record the failure" call
- `[default=die]` — if faillock itself fails, stop the entire PAM stack

> **Important:** Keep the existing `[success=2 default=ignore]` (or similar) control on `pam_unix.so` — the number may need adjusting if you add more modules. The number tells PAM how many modules to skip on success.

Now add the account check. Edit `/etc/pam.d/common-account`:

```bash
sudo nano /etc/pam.d/common-account
```

Add this line **at the top** (before the other account lines):

```
account required pam_faillock.so
```

This line tells PAM to check the faillock database during the account phase — if the account is locked, deny access regardless of what other modules say.

### 3.4 Test from the client

On **pam-lab-client**, try logging in with a wrong password 3 times:

> **Important:** We use `-o PubkeyAuthentication=no` to force password authentication. Without this, SSH would use key-based auth and PAM would never see the failed password attempt — the faillock counter would never increment.

```bash
sshpass -p 'wrongpass' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
sshpass -p 'wrongpass' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
sshpass -p 'wrongpass' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
```

Each attempt should show "Permission denied". Now try with the **correct** password:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
# Permission denied — the account is LOCKED even with the right password!
```

### 3.5 Check lock status on the server

On **pam-lab-server**, view the faillock status:

```bash
sudo faillock --user testuser
```

You'll see a table showing each failed attempt with timestamps and source addresses. The `V` column indicates the attempt is still "valid" (not expired).

### 3.6 Unlock the account

There are two ways to unlock:

```bash
# Manual unlock (immediate)
sudo faillock --user testuser --reset

# Or just wait 5 minutes (unlock_time=300)
```

### 3.7 Verify unlock

From **pam-lab-client**, try logging in with the correct password again:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
# Should work now!
```

Type `exit` to disconnect.

---

## Exercise 4 — Resource Limits (pam_limits)

**VM:** pam-lab-server
**Goal:** Limit system resources (processes, open files, logins) per user or group.

`pam_limits` reads `/etc/security/limits.conf` and applies resource limits when a user's session starts. This is useful to prevent a single user from consuming all system resources — for example, a fork bomb that creates infinite processes, or a program that opens thousands of files.

### 4.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 4.2 Understand soft vs hard limits

Linux has two types of resource limits:

- **Soft limit** — the default value for the user. The user can raise it up to the hard limit using `ulimit`.
- **Hard limit** — the absolute maximum. Only root can raise it. Once set, the user cannot exceed it.

Think of it like a speed limit: the soft limit is the "recommended speed" and the hard limit is the "physical barrier".

### 4.3 Check testuser's current limits

```bash
su - testuser -c "ulimit -a"
```

This shows all current limits. Pay attention to `open files` and `max user processes` — we'll change those.

### 4.4 Configure limits

On **pam-lab-server**, edit the limits configuration:

```bash
sudo nano /etc/security/limits.conf
```

Add these lines at the end (before the `# End of file` comment):

```
# Max number of processes for testuser
# Soft limit: default 30 (user sees this)
# Hard limit: absolute max 50 (user can't go beyond this)
testuser        hard    nproc           50
testuser        soft    nproc           30

# Max open files for testuser
testuser        hard    nofile          256
testuser        soft    nofile          128

# Max simultaneous logins for alice (prevents same user logging in N+ times)
alice           hard    maxlogins       2

# Default open files for all users (the * wildcard matches everyone)
*               soft    nofile          1024
*               hard    nofile          4096
```

**Format:** `<user/@group>  <hard/soft>  <resource>  <value>`

You can also use `@groupname` to apply limits to all members of a group.

### 4.5 Verify pam_limits is active

The module must be in the session stack to apply limits at login time:

```bash
grep limits /etc/pam.d/common-session
```

You should see:

```
session required pam_limits.so
```

### 4.6 Test the limits

Log in as testuser (the limits apply to **new** sessions only, not existing ones):

```bash
su - testuser

# Check the limits
ulimit -u    # max user processes — should show 30 (soft limit)
ulimit -n    # max open files — should show 128 (soft limit)

# Try to raise open files beyond the hard limit
ulimit -n 512
# Expected: "bash: ulimit: open files: cannot modify limit: Operation not permitted"
# Because the hard limit is 256

# But raising within the hard limit works
ulimit -n 200
# This should succeed (200 < 256)

exit
```

### 4.7 Test maxlogins for alice

The `maxlogins` limit restricts how many simultaneous sessions a user can have. Open multiple sessions:

```bash
# In Terminal 1 on the server:
su - alice
# Works — session 1

# In Terminal 2 on the server (or another qlab shell):
su - alice
# Works — session 2

# In Terminal 3:
su - alice
# Should be rejected — maxlogins is 2
```

---

## Exercise 5 — Time-based Access (pam_time)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Restrict when users are allowed to log in.

`pam_time` checks the current time against rules in `/etc/security/time.conf` and denies access if the login is outside the allowed time window. This is useful in corporate environments where you want to prevent after-hours access.

### 5.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 5.2 Enable pam_time for SSH

By default, `pam_time` is not active for SSH. You need to add it to the SSHD PAM config.

On **pam-lab-server**:

```bash
sudo nano /etc/pam.d/sshd
```

Find the line `@include common-account` and add this line **after** it:

```
account    required    pam_time.so
```

This tells PAM: "After the standard account checks, also check time restrictions. If the check fails (`required`), deny access."

### 5.3 Understand the time.conf format

```bash
sudo nano /etc/security/time.conf
```

Each rule has four fields separated by semicolons:

```
services;ttys;users;times
```

- **services** — which PAM services this rule applies to (e.g., `sshd`, `login`, `*` for all)
- **ttys** — which terminals (`*` for all)
- **users** — which users (can use `!` to negate)
- **times** — when access is allowed, using day codes and time ranges

**Day codes:** `Mo Tu We Th Fr Sa Su` (individual days), `Wk` (weekdays), `Wd` (weekends), `Al` (all days)

**Time format:** `HHMM-HHMM` (24-hour format)

**Examples:**

```
# Allow testuser SSH only on weekdays 08:00-18:00
sshd;*;testuser;Wk0800-1800

# Deny testuser SSH on weekends (! means "NOT these times")
sshd;*;testuser;!SaSu0000-2400

# Allow alice SSH at any time (no restriction)
# (simply don't add a rule for alice)
```

Add a rule appropriate for your current time. Check the time first:

```bash
date
```

For example, if it's currently 15:00 on a weekday and you want to test a **denial**, add a rule that blocks the current time:

```
# Block testuser right now (adjust to match your current time!)
sshd;*;testuser;Wk1800-0800
```

This allows access only from 18:00 to 08:00, so at 15:00 the user would be denied.

### 5.4 Test the restriction

From **pam-lab-client**:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
# Should be denied if the current time is outside the allowed window
```

### 5.5 Verify that alice is NOT restricted

Since we didn't add a rule for alice, she can always log in:

```bash
sshpass -p 'Alice123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no alice@192.168.100.1
# Should always work
```

Type `exit` to disconnect.

### 5.6 Clean up

On **pam-lab-server**, remove or comment out the time rule:

```bash
sudo nano /etc/security/time.conf
# Comment out your rule by adding # at the beginning
```

---

## Exercise 6 — Host/User Access Control (pam_access)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Control which users can log in from which IP addresses.

`pam_access` reads `/etc/security/access.conf` and checks whether a user is allowed to log in from their current location (IP address, hostname, or terminal). This is useful to restrict admin access to specific jump hosts, or to prevent certain users from logging in remotely.

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

### 6.3 Understand the access.conf format

```bash
sudo nano /etc/security/access.conf
```

Each rule has three fields:

```
permission : users : origins
```

- **permission** — `+` (allow) or `-` (deny)
- **users** — username, `ALL`, or a group name
- **origins** — IP address, hostname, `ALL`, `LOCAL` (console)

**Rules are processed top-to-bottom. The first match wins.** This means order matters! Put specific rules before general ones.

Add these rules:

```
# Allow testuser ONLY from the client VM (192.168.100.2)
+ : testuser : 192.168.100.2

# Deny testuser from everywhere else
- : testuser : ALL

# Allow everyone else from anywhere (important! Without this,
# ALL users would be denied because the default is to allow,
# but once you have any rules, unmatched users might behave unexpectedly)
+ : ALL : ALL
```

### 6.4 Test from the client (should work)

From **pam-lab-client** (192.168.100.2):

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
# Should work — testuser is allowed from 192.168.100.2
```

Type `exit` to disconnect.

### 6.5 Test from the server itself (should be denied)

On **pam-lab-server**, try to SSH to localhost:

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@localhost
# Should be denied — localhost is not 192.168.100.2
```

### 6.6 Verify alice is not restricted

From **pam-lab-client**:

```bash
sshpass -p 'Alice123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no alice@192.168.100.1
# Should work — the "ALL : ALL" rule allows everyone except testuser
```

Type `exit` to disconnect.

### 6.7 Clean up

On **pam-lab-server**, remove or comment out the rules in `/etc/security/access.conf`:

```bash
sudo nano /etc/security/access.conf
# Comment out the rules you added
```

---

## Exercise 7 — Custom Audit (pam_exec)

**VM:** pam-lab-server
**Goal:** Run a custom script every time someone logs in, for auditing or alerting.

`pam_exec` runs an external script or command at any point in the PAM pipeline. PAM passes environment variables to the script with information about the authentication attempt. This is a powerful way to build custom logging, alerting, or even custom authentication logic.

### 7.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 7.2 Understand the PAM environment variables

When `pam_exec` runs your script, the following environment variables are available:

| Variable | Content |
|----------|---------|
| `PAM_TYPE` | The phase: `auth`, `open_session`, `close_session`, `account`, `password` |
| `PAM_USER` | The username being authenticated |
| `PAM_RHOST` | The remote host (IP address of the client) |
| `PAM_SERVICE` | The service name (e.g., `sshd`) |
| `PAM_TTY` | The terminal being used |

### 7.3 Create an audit script

On **pam-lab-server**:

```bash
sudo nano /usr/local/bin/pam-audit.sh
```

Content:

```bash
#!/bin/bash
# Log every PAM event to a custom audit log
echo "$(date '+%Y-%m-%d %H:%M:%S') PAM_TYPE=$PAM_TYPE USER=$PAM_USER RHOST=$PAM_RHOST SERVICE=$PAM_SERVICE TTY=$PAM_TTY" >> /var/log/pam-audit.log
```

Make it executable and create the log file:

```bash
sudo chmod +x /usr/local/bin/pam-audit.sh
sudo touch /var/log/pam-audit.log
sudo chmod 666 /var/log/pam-audit.log
```

### 7.4 Add pam_exec to the SSH session stack

```bash
sudo nano /etc/pam.d/sshd
```

Add at the end of the file:

```
session    optional    pam_exec.so /usr/local/bin/pam-audit.sh
```

We use `optional` because we don't want the audit script to block login if it fails — it's just for logging.

### 7.5 Test by logging in

From **pam-lab-client** (or another terminal):

```bash
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1 "echo hello"
```

### 7.6 Check the audit log

On **pam-lab-server**:

```bash
cat /var/log/pam-audit.log
```

You should see entries like:

```
2026-02-21 14:30:00 PAM_TYPE=open_session USER=testuser RHOST=192.168.100.2 SERVICE=sshd TTY=
2026-02-21 14:30:01 PAM_TYPE=close_session USER=testuser RHOST=192.168.100.2 SERVICE=sshd TTY=
```

Notice how there are two entries — `open_session` when the session starts and `close_session` when it ends. This is because `pam_exec` in the session stack is called at both events.

### 7.7 Add auth event logging (optional)

You can also log authentication attempts (including failures) by adding the script to the auth stack:

```bash
sudo nano /etc/pam.d/sshd
```

Add **before** the `@include common-auth` line:

```
auth    optional    pam_exec.so /usr/local/bin/pam-audit.sh
```

Now failed login attempts will also appear in the audit log.

---

## Exercise 8 — Two-Factor Auth TOTP (pam_google_authenticator)

**VM:** pam-lab-server, pam-lab-client
**Goal:** Add TOTP (Time-based One-Time Password) two-factor authentication to SSH.

Two-factor authentication (2FA) requires **something you know** (password) AND **something you have** (a TOTP app on your phone). Even if an attacker steals the password, they can't log in without the code from your phone. This is the same technology used by Google, GitHub, AWS, and most modern services.

### 8.1 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 8.2 Generate a TOTP secret for testuser

The TOTP secret is generated **per user** — each user has their own secret key. On **pam-lab-server**, switch to testuser:

```bash
su - testuser
google-authenticator
```

Answer the prompts:

1. **Do you want authentication tokens to be time-based (y/n):** `y`
   (This selects TOTP instead of HOTP — TOTP is the standard used by most services)

2. You'll see a **QR code** in the terminal and a **secret key** below it. **Save the secret key!**
   If you have a TOTP app (Google Authenticator, Authy, FreeOTP), scan the QR code now.

3. **Enter the code from your app:** enter a 6-digit code from your app, or use the secret key manually

4. **Update ~/.google_authenticator file?** `y`

5. **Disallow multiple uses of the same token?** `y` (prevents replay attacks)

6. **Increase the window?** `n` (keep it tight — 30 second window)

7. **Enable rate-limiting?** `y` (limits brute-force attempts on the TOTP code)

```bash
exit  # back to labuser
```

### 8.3 Configure PAM for 2FA

On **pam-lab-server**, add the Google Authenticator module to the SSH auth stack:

```bash
sudo nano /etc/pam.d/sshd
```

Add **after** the `@include common-auth` line:

```
auth    required    pam_google_authenticator.so
```

This means: after the normal password check succeeds, **also** require a valid TOTP code. Both must pass (`required`).

### 8.4 Configure SSH for 2FA

SSH needs to be configured to use challenge-response authentication (which is how TOTP prompts work):

```bash
sudo nano /etc/ssh/sshd_config
```

Make sure these settings are present:

```
ChallengeResponseAuthentication yes
KbdInteractiveAuthentication yes
AuthenticationMethods keyboard-interactive
```

The `AuthenticationMethods keyboard-interactive` line tells SSH to use the PAM-based interactive method instead of the simple password method. This is what allows the TOTP prompt to appear after the password.

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
1. **Password:** `Test123!`
2. **Verification code:** (the 6-digit code from your TOTP app)

If both are correct, you're logged in with 2FA!

### 8.6 Fallback — if you don't have a TOTP app

During setup, `google-authenticator` generated 5 emergency scratch codes. You can use one of these instead of a TOTP code (each code works only once):

```bash
# On pam-lab-server, as root, read testuser's file:
sudo cat /home/testuser/.google_authenticator
```

The lines at the bottom (5 eight-digit numbers) are the emergency codes. Use one as the "Verification code" when prompted.

### 8.7 Clean up

To disable 2FA and restore normal password-only authentication:

```bash
sudo nano /etc/pam.d/sshd
# Remove the line: auth required pam_google_authenticator.so

sudo sed -i 's/^AuthenticationMethods.*/# &/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

## Exercise 9 — Centralized LDAP Authentication (sssd)

**VM:** pam-lab-server, pam-lab-ldap
**Goal:** Configure the server to authenticate users from a central LDAP directory.

In enterprise environments, user accounts are not stored locally on each server — they're stored in a central directory (LDAP, Active Directory). This way, an admin creates a user account **once** and the user can log into **any** server. The `sssd` (System Security Services Daemon) is the standard Linux component that connects to LDAP and makes remote users appear as local users.

The pam-lab-ldap VM already has an OpenLDAP server running with two users (`ldapuser1`, `ldapuser2`) and a group (`pamtesters`). Your job is to configure the pam-lab-server to use this LDAP directory for authentication.

### 9.1 Verify LDAP is working

First, make sure the LDAP server has the expected data.

On **pam-lab-ldap**:

```bash
ldapsearch -x -H ldap://localhost -b "dc=pam-lab,dc=local" -LLL "(objectClass=posixAccount)" uid cn
```

You should see `ldapuser1` and `ldapuser2`.

From **pam-lab-server**, verify you can reach the LDAP server over the network:

```bash
ldapsearch -x -H ldap://192.168.100.3 -b "dc=pam-lab,dc=local" -LLL "(objectClass=posixAccount)" uid cn
```

If this doesn't work, check network connectivity with `ping 192.168.100.3`.

### 9.2 Backup first!

```bash
sudo ~/pam-backup.sh
```

### 9.3 Configure sssd

sssd needs a configuration file that tells it where the LDAP server is and how to connect.

On **pam-lab-server**, create the config:

```bash
sudo nano /etc/sssd/sssd.conf
```

Content:

```ini
[sssd]
config_file_version = 2
# Which services sssd provides: NSS (name resolution) and PAM (authentication)
services = nss, pam
# Which identity domains to use
domains = pam-lab.local

[nss]
# Don't shadow the local root user with an LDAP root
filter_groups = root
filter_users = root

[pam]

[domain/pam-lab.local]
# Use LDAP for both identity (who exists) and authentication (password check)
id_provider = ldap
auth_provider = ldap

# LDAP connection details
ldap_uri = ldap://192.168.100.3
ldap_search_base = dc=pam-lab,dc=local
ldap_id_use_start_tls = false
ldap_tls_reqcert = never

# Cache credentials locally so users can still log in if LDAP is temporarily down
cache_credentials = true

# Enumerate users (needed for getent to list all LDAP users)
enumerate = true

# Where to find users and groups in the LDAP tree
ldap_user_search_base = ou=users,dc=pam-lab,dc=local
ldap_group_search_base = ou=groups,dc=pam-lab,dc=local

# Bind credentials to search the directory
# (in production, use a read-only service account, not the admin)
ldap_default_bind_dn = cn=admin,dc=pam-lab,dc=local
ldap_default_authtok = ldapadmin
```

sssd is very strict about file permissions — it won't start if the config is world-readable:

```bash
sudo chmod 600 /etc/sssd/sssd.conf
sudo chown root:root /etc/sssd/sssd.conf
```

### 9.4 Configure NSS to use sssd

NSS (Name Service Switch) is the system component that resolves usernames to UIDs. You need to tell it to also look in sssd (which talks to LDAP).

On **pam-lab-server**:

```bash
sudo nano /etc/nsswitch.conf
```

Find the `passwd`, `group`, and `shadow` lines and add `sss` after `files`:

```
passwd:         files sss
group:          files sss
shadow:         files sss
```

This tells the system: "First check local files (`/etc/passwd`, `/etc/shadow`), then ask sssd (which checks LDAP)."

### 9.5 Verify PAM sssd modules are in the stack

When you installed the `libpam-sss` package, it should have automatically added itself to the PAM stack. Verify:

```bash
grep pam_sss /etc/pam.d/common-auth
grep pam_sss /etc/pam.d/common-account
grep pam_sss /etc/pam.d/common-session
grep pam_sss /etc/pam.d/common-password
```

Each command should return at least one line. If any are missing, add them manually:

```bash
# If missing from common-auth, add after pam_unix.so:
# auth    [success=1 default=ignore]  pam_sss.so use_first_pass

# If missing from common-account:
# account [default=bad success=ok user_unknown=ignore] pam_sss.so

# If missing from common-session:
# session optional pam_sss.so

# If missing from common-password:
# password sufficient pam_sss.so use_authtok
```

### 9.6 Enable automatic home directory creation

When an LDAP user logs in for the first time, they don't have a home directory on the server. The `pam_mkhomedir` module creates it automatically:

```bash
sudo nano /etc/pam.d/common-session
```

Add this line at the end:

```
session required pam_mkhomedir.so skel=/etc/skel umask=077
```

This creates a home directory from the `/etc/skel` template with permissions `700` (only the user can access it).

### 9.7 Start sssd

```bash
sudo systemctl restart sssd
sudo systemctl enable sssd
```

If sssd fails to start, check the config file permissions and syntax:

```bash
sudo journalctl -u sssd -n 30 --no-pager
```

### 9.8 Verify LDAP users are visible

The real test — can the system see LDAP users as if they were local?

```bash
# List LDAP users
getent passwd ldapuser1
getent passwd ldapuser2

# List the LDAP group
getent group pamtesters
```

You should see entries like:

```
ldapuser1:*:10001:10000:LDAP User1:/home/ldapuser1:/bin/bash
ldapuser2:*:10002:10000:LDAP User2:/home/ldapuser2:/bin/bash
pamtesters:*:10000:ldapuser1,ldapuser2
```

If `getent` doesn't return anything, sssd is not configured correctly. Check the troubleshooting section.

### 9.9 Test SSH login with an LDAP user

This is the moment of truth! From **pam-lab-client**:

```bash
sshpass -p 'Ldap123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no ldapuser1@192.168.100.1
```

You should be logged in as `ldapuser1`. Verify:

```bash
whoami        # should show: ldapuser1
pwd           # should show: /home/ldapuser1 (auto-created!)
id            # should show: uid=10001 gid=10000(pamtesters)
ls -la ~/     # should show standard skeleton files
exit
```

### 9.10 Test the second LDAP user

```bash
sshpass -p 'Ldap456!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no ldapuser2@192.168.100.1
whoami
id
exit
```

### 9.11 Verify local users still work

It's important that adding LDAP authentication doesn't break local user authentication:

From **pam-lab-client**:

```bash
# Local user should still work
sshpass -p 'Test123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no testuser@192.168.100.1
exit

# LDAP user should also work
sshpass -p 'Ldap123!' ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no ldapuser1@192.168.100.1
exit
```

Both should work — `files sss` in nsswitch.conf means local users are checked first, then LDAP. The two sources coexist peacefully.

---

## Troubleshooting

### PAM changes locked me out

Use your backup SSH session (that you kept open!) to restore:

```bash
sudo ~/pam-restore.sh
sudo systemctl restart sshd
```

If you don't have a backup session, reset the VM from the host:

```bash
qlab stop pam-lab
qlab run pam-lab
```

### sshd won't start after PAM changes

Check what's wrong:

```bash
sudo sshd -t                              # test sshd config syntax
sudo journalctl -u sshd -n 20 --no-pager  # check recent logs
```

The most common problem is a typo in `/etc/pam.d/sshd`. Restore and retry:

```bash
sudo ~/pam-restore.sh
sudo systemctl restart sshd
```

### faillock not working

Common causes:

1. **Missing `-o PubkeyAuthentication=no`** in your SSH command — SSH uses key auth instead of password, so PAM never sees the failure
2. **Missing `account required pam_faillock.so`** in `common-account` — failures are recorded but never enforced
3. **Wrong order** in `common-auth` — `preauth` must come before `pam_unix.so`, and `authfail` must come after
4. **Wrong `success=N` jump count** — after adding faillock lines, the `success=N` on `pam_unix.so` may need adjusting

### pam_pwquality not enforcing rules

1. Check that `/etc/security/pwquality.conf` is readable and has no syntax errors:
   ```bash
   sudo cat /etc/security/pwquality.conf
   ```

2. Verify it's in the PAM stack:
   ```bash
   grep pwquality /etc/pam.d/common-password
   ```

3. Remember: pwquality only applies to **password changes** (`passwd`), not to login. It doesn't retroactively check existing passwords.

### sssd won't start

1. **Permissions:** the config file must be `0600` owned by `root`:
   ```bash
   ls -la /etc/sssd/sssd.conf
   sudo chmod 600 /etc/sssd/sssd.conf
   sudo chown root:root /etc/sssd/sssd.conf
   ```

2. **Check logs:**
   ```bash
   sudo journalctl -u sssd -n 50 --no-pager
   sudo cat /var/log/sssd/sssd.log 2>/dev/null
   sudo cat /var/log/sssd/sssd_pam-lab.local.log 2>/dev/null
   ```

3. **LDAP unreachable:** verify from the server:
   ```bash
   ldapsearch -x -H ldap://192.168.100.3 -b "dc=pam-lab,dc=local" -LLL
   ```

### LDAP users not visible with getent

1. Verify sssd is running: `sudo systemctl status sssd`
2. Verify LDAP is reachable: `ldapsearch -x -H ldap://192.168.100.3 -b "dc=pam-lab,dc=local" -LLL`
3. Check `/etc/nsswitch.conf` includes `sss` on the `passwd` and `group` lines
4. Clear the sssd cache and restart:
   ```bash
   sudo sss_cache -E
   sudo systemctl restart sssd
   ```
5. Wait a few seconds and try `getent passwd ldapuser1` again

### Can't connect between VMs

1. Check network: `ping 192.168.100.1` (from client), `ping 192.168.100.3` (from server)
2. Verify cloud-init finished: `cloud-init status --wait`
3. Check slapd is running on LDAP VM: `sudo systemctl status slapd`
4. Check sshd is running on server: `sudo systemctl status sshd`

### General: packages not installed

Cloud-init may still be running (it installs packages):

```bash
cloud-init status --wait
```

Wait for it to show `status: done` before proceeding with exercises.
