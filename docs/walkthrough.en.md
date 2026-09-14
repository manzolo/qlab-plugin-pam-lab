---
kicker: QLab · pam-lab
title: |
  PAM, one module
  at a time
subtitle: >
  The stack that decides whether you get in. Read it, call it directly, then
  change it seven times — password rules, lockout, limits, host restrictions,
  an audit hook, and a directory server. From a running lab.
facts:
  - [Command, "`qlab run pam-lab`"]
  - [VMs, "`pam-lab-server` · `pam-lab-client` · `pam-lab-ldap`"]
  - [LAN, "`192.168.100.0/24`, isolated between the three VMs"]
  - [Credentials, "`labuser` / `labpass` · `testuser` / `Test123!` · `alice` / `Alice123!`"]
  - [Outcome, "`qlab test pam-lab` → 8 exercises, 43 checks, all passed"]
---

## 1. Three machines, one login

{{evidence:topology as=shell}}

The server is where PAM is configured. The client exists so that logins arrive
over a network, from an address the server can see and make decisions about —
several of the modules below only make sense when the login comes from
somewhere. The LDAP server is for the last section, and is ignored until then.

Everything that follows changes the server's PAM configuration and then puts it
back. That is worth saying out loud: PAM is the one subsystem where a typo locks
you out of your own machine, which is why every experiment here is paired with a
restore, and why `pamtester` — section 3 — exists at all.

## 2. The stack is a text file

{{evidence:stack as=shell}}

`/etc/pam.d/sshd` is not a config file *about* authentication; it is the
authentication, in order. Each line has three parts: a **type**, a **control**,
and a **module**.

The four types are four separate stacks that run at different moments.
**`auth`** proves who you are. **`account`** decides whether that identity may
log in *now, here* — valid, unexpired, not locked. **`session`** sets up and
tears down what surrounds the login. **`password`** runs only when a credential
is being changed. A module can implement any subset of them, which is why the
same `pam_unix.so` appears in several stacks doing different jobs.

The control field is the interesting one. `required`, `requisite`, `sufficient`
and `optional` are the shorthand forms; `common-auth` shows the long form the
shorthands expand to — `[success=2 default=ignore]` means *on success, skip the
next two lines*. That is how "try local users, then try the directory, then give
up" is expressed without a single `if`.

The `@include` lines matter as much as the rest: the per-service file delegates
to `common-*`, which is why installing something that edits `common-auth`
changes how *every* service on the machine authenticates.

## 3. Calling PAM directly

{{evidence:pamtester as=shell}}

`pamtester` runs the stack the way a service would, without being one. The first
call authenticates `testuser` against the `sshd` stack — no SSH daemon involved,
no network, just the library. The second does the same with a wrong password and
gets the failure.

The last four calls are the four types from section 2, requested one at a time
against the same service. `authenticate` checks the password, `acct_mgmt` asks
whether the account may be used, `open_session` and `close_session` run the
session hooks. Every login you have ever performed is these four calls in that
order, made by a program that then goes on to do its own job.

:::note
This is the tool that makes PAM safe to experiment with. Open a second terminal
that is already logged in, change the stack, test it with `pamtester`, and only
then try a real login. Editing `common-auth` and logging out to see if it worked
is how people end up reaching for the rescue console.
:::

## 4. Password rules that apply to some people

{{evidence:pwquality as=shell}}

`pam_pwquality` sits at the top of the `password` stack and vets the new
password before `pam_unix` is allowed to store it. The rules are in
`/etc/security/pwquality.conf`: a length floor, a minimum number of character
classes, and the `*credit` settings, where a **negative** value means "require
at least this many" — `dcredit = -1` is one digit, minimum.

When `testuser` changes his own password, the rules are enforced: two rejections
with the reason spelled out, then a password that satisfies everything, accepted.
`retry = 3` is why he gets three goes before `passwd` gives up entirely.

Then root sets the *same* rejected password on the same account, and it goes
through — with the complaint printed, and ignored. `pam_pwquality` does not
enforce against root unless it is given `enforce_for_root`. This surprises
people regularly: a policy tested with `sudo passwd someuser` looks like it is
not working at all, because for root it is only ever advice.

## 5. Lockout: three strikes, counted on disk

{{evidence:faillock as=shell}}

The rebuilt stack shows the shape `pam_faillock` needs, and the order is not
optional. **`preauth`** runs *before* `pam_unix` and refuses immediately if the
account is already locked. **`authfail`** runs *after* it and records a failure —
with `[default=die]`, so a failed attempt stops the stack there. Put `authfail`
first and every login fails; this is a genuinely easy mistake to make.

Then three wrong passwords from the client, and the fourth attempt — with the
*right* password — is refused too. The account is locked, and the server's own
log says so in as many words: three `pam_unix` authentication failures, then
`pam_faillock` announcing that the account is temporarily locked.

`faillock --user` prints the ledger: one row per failure, with the time and the
source address, because the counter is per-user and kept in
`/var/run/faillock/`. `--reset` empties it, and the same password that was
refused a moment ago works again. `unlock_time=300` would have done the same
thing on its own after five minutes.

## 6. Limits arrive with the session

{{evidence:limits as=shell}}

`pam_limits` is already in `common-session` — it is in almost every distribution
by default — and it applies `/etc/security/limits.conf` at the moment a session
opens. Nothing else in the system does this; a limit set here is a property of
*logging in*, not of the shell or the user account.

Three lines produce three different answers in the new session: a soft limit, a
hard limit, and a process cap. The soft one is what a program gets; the hard one
is the ceiling it may raise itself to and no further. The distinction is what
lets `ulimit -n 4096` sometimes work and sometimes not, on the same machine, for
different users.

The measurement has to come from a *new* login. An existing shell keeps the
limits it was born with, and no amount of editing `limits.conf` will change it.

## 7. Where you are logging in from

{{evidence:access as=shell}}

One line of `/etc/security/access.conf` — deny, this user, from that address —
and `pam_access` in the `account` stack to read it. The client's login is closed
before it gets a shell, the password having been perfectly correct, and the log
records exactly why.

This is the clearest demonstration in the lab of what the `account` stack is
*for*. Authentication succeeded: the password was right and `pam_unix` said so.
Authorisation then failed, separately, on grounds that have nothing to do with
credentials. Two different questions, two different stacks, and PAM keeps them
apart on purpose.

The same account still passes `acct_mgmt` when the login is not coming from the
denied address — the rule names a source, so it only applies there.

## 8. Anything you can write in a script

{{evidence:audit as=shell}}

`pam_exec` runs an arbitrary program as part of the stack, handing it the
context in environment variables. Twelve lines of shell and one line in
`/etc/pam.d/sshd` produce a login audit trail: who, from where, which service,
which TTY, and whether the session was opening or closing.

The log has three entries after one login, not two, and the third is the
walkthrough's own SSH connection arriving to read the file. That is worth
noticing — the hook is on the service, not on the user, and it sees everything
the service does, including the thing you are doing right now.

`optional` is the right control here: an audit hook that can *fail the login*
because a script had a typo is a bad trade. With `required`, a non-zero exit
from that script would lock everyone out.

## 9. Users who live somewhere else

{{evidence:sssd as=shell}}

`nsswitch.conf` already lists `sss` as a source for `passwd`, `group` and
`shadow` — but `sssd` is not running and has no configuration, so the machine
has never had anything to ask. `getent passwd ldapuser1` comes back empty.

The entry exists, one VM away, in an LDAP directory: a `uid`, a `uidNumber`, a
`gidNumber`, a home directory and a login shell — the same fields `/etc/passwd`
has, written as a directory object.

One config file and a restart later, and the machine answers the same questions
differently. `getent` resolves the user, `id` resolves the group membership, and
`/etc/passwd` still contains no trace of either. Then `ldapuser1` logs in over
SSH from the client, and `pam_mkhomedir` creates the home directory on the way
past, copying `/etc/skel` into it.

That is the whole point of the exercise: **identity** came from the directory via
NSS, **authentication** came from the directory via `pam_sss`, and **the home
directory** came from a PAM session module — three separate mechanisms that
together make a user who was never created on this machine into an ordinary one.

## 10. Try it yourself

```
qlab run pam-lab
qlab shell pam-lab-server
```

The safe loop is always the same:

```
sudo cp /etc/pam.d/common-auth /root/common-auth.bak    # first, always
sudo nano /etc/pam.d/common-auth
echo 'Test123!' | sudo pamtester -v sshd testuser authenticate
```

and from the client, a real login to confirm:

```
sshpass -p 'Test123!' ssh testuser@192.168.100.1
```

Three things worth doing:

- Change a `required` to a `requisite` in `common-auth` and watch where the stack
  stops — `requisite` fails immediately, `required` finishes the stack first so
  an attacker cannot tell *which* module refused.
- Set `deny=3` in `pam_faillock` and lock yourself out on purpose, then unlock
  the account from a second session with `faillock --reset`.
- Add `pam_time` alongside `pam_access` and restrict a user to office hours in
  `/etc/security/time.conf`.

{{evidence:qlab-test as=shell grep="Exercise [0-9]|All [0-9]+ checks|Exercises (run|passed|failed)" }}

`qlab test pam-lab` performs each of these changes, verifies the behaviour it
was meant to produce, and restores the original files — which is also the
best-documented answer to "what does this module actually do".
