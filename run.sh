#!/usr/bin/env bash
# pam-lab run script — boots three VMs for PAM authentication labs

set -euo pipefail

PLUGIN_NAME="pam-lab"
SERVER_VM="pam-lab-server"
CLIENT_VM="pam-lab-client"
LDAP_VM="pam-lab-ldap"

# Internal LAN — direct VM-to-VM link via QEMU socket multicast
INTERNAL_MCAST="230.0.0.1:10004"
SERVER_INTERNAL_IP="192.168.100.1"
CLIENT_INTERNAL_IP="192.168.100.2"
LDAP_INTERNAL_IP="192.168.100.3"
SERVER_LAN_MAC="52:54:00:00:06:01"
CLIENT_LAN_MAC="52:54:00:00:06:02"
LDAP_LAN_MAC="52:54:00:00:06:03"

echo "============================================="
echo "  pam-lab: PAM Authentication Lab"
echo "  Modules, Policies, 2FA, LDAP/sssd"
echo "============================================="
echo ""
echo "  This lab creates three VMs connected by an"
echo "  internal LAN (192.168.100.0/24):"
echo ""
echo "    1. $SERVER_VM"
echo "       Internal IP: $SERVER_INTERNAL_IP"
echo "       PAM modules, policies, sssd client"
echo ""
echo "    2. $CLIENT_VM"
echo "       Internal IP: $CLIENT_INTERNAL_IP"
echo "       SSH client to test PAM policies"
echo ""
echo "    3. $LDAP_VM"
echo "       Internal IP: $LDAP_INTERNAL_IP"
echo "       OpenLDAP server (pam-lab.local)"
echo ""

# Source QLab core libraries
if [[ -z "${QLAB_ROOT:-}" ]]; then
    echo "ERROR: QLAB_ROOT not set. Run this plugin via 'qlab run ${PLUGIN_NAME}'."
    exit 1
fi

for lib_file in "$QLAB_ROOT"/lib/*.bash; do
    # shellcheck source=/dev/null
    [[ -f "$lib_file" ]] && source "$lib_file"
done

# Configuration
WORKSPACE_DIR="${WORKSPACE_DIR:-.qlab}"
LAB_DIR="lab"
IMAGE_DIR="$WORKSPACE_DIR/images"
CLOUD_IMAGE_URL=$(get_config CLOUD_IMAGE_URL "https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img")
CLOUD_IMAGE_FILE="$IMAGE_DIR/ubuntu-22.04-minimal-cloudimg-amd64.img"
MEMORY="${QLAB_MEMORY:-$(get_config DEFAULT_MEMORY 768)}"

# Ensure directories exist
mkdir -p "$LAB_DIR" "$IMAGE_DIR"

# =============================================
# Step 1: Download cloud image (shared by all VMs)
# =============================================
info "Step 1: Cloud image"
if [[ -f "$CLOUD_IMAGE_FILE" ]]; then
    success "Cloud image already downloaded: $CLOUD_IMAGE_FILE"
else
    echo ""
    echo "  Cloud images are pre-built OS images designed for cloud environments."
    echo "  All VMs will share the same base image via overlay disks."
    echo ""
    info "Downloading Ubuntu cloud image..."
    echo "  URL: $CLOUD_IMAGE_URL"
    echo "  This may take a few minutes depending on your connection."
    echo ""
    check_dependency curl || exit 1
    curl -L -o "$CLOUD_IMAGE_FILE" "$CLOUD_IMAGE_URL" || {
        error "Failed to download cloud image."
        echo "  Check your internet connection and try again."
        exit 1
    }
    success "Cloud image downloaded: $CLOUD_IMAGE_FILE"
fi
echo ""

# =============================================
# Step 2: Cloud-init configurations
# =============================================
info "Step 2: Cloud-init configuration for all VMs"
echo ""

# --- PAM Server VM cloud-init ---
info "Creating cloud-init for $SERVER_VM..."
cat > "$LAB_DIR/user-data-server" <<'USERDATA'
#cloud-config
hostname: pam-lab-server
package_update: true
users:
  - name: labuser
    plain_text_passwd: labpass
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - "__QLAB_SSH_PUB_KEY__"
ssh_pwauth: true
packages:
  - libpam-pwquality
  - libpam-google-authenticator
  - pamtester
  - qrencode
  - sssd
  - sssd-ldap
  - libnss-sss
  - libpam-sss
  - openssh-server
  - nano
  - net-tools
  - iputils-ping
  - tcpdump
  - zsh
  - vim
  - nano
  - fonts-powerline
write_files:
  - path: /etc/profile.d/cloud-init-status.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      if command -v cloud-init >/dev/null 2>&1; then
        status=$(cloud-init status 2>/dev/null)
        if echo "$status" | grep -q "running"; then
          printf '\033[1;33m'
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Cloud-init is still running..."
          echo "  Some packages and services may not be ready yet."
          echo "  Run 'cloud-init status --wait' to wait for completion."
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          printf '\033[0m\n'
        fi
      fi
  - path: /etc/netplan/60-internal.yaml
    content: |
      network:
        version: 2
        ethernets:
          pamlan:
            match:
              macaddress: "52:54:00:00:06:01"
            addresses:
              - 192.168.100.1/24
  - path: /home/labuser/pam-backup.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Backup PAM and SSSD configuration
      BACKUP_DIR="$HOME/pam-backup-$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$BACKUP_DIR"
      sudo cp -a /etc/pam.d/ "$BACKUP_DIR/"
      if [[ -d /etc/sssd ]]; then
        sudo cp -a /etc/sssd/ "$BACKUP_DIR/"
      fi
      if [[ -f /etc/security/pwquality.conf ]]; then
        sudo cp /etc/security/pwquality.conf "$BACKUP_DIR/"
      fi
      if [[ -f /etc/security/limits.conf ]]; then
        sudo cp /etc/security/limits.conf "$BACKUP_DIR/"
      fi
      if [[ -f /etc/security/time.conf ]]; then
        sudo cp /etc/security/time.conf "$BACKUP_DIR/"
      fi
      if [[ -f /etc/security/access.conf ]]; then
        sudo cp /etc/security/access.conf "$BACKUP_DIR/"
      fi
      echo "Backup saved to: $BACKUP_DIR"
      ls -la "$BACKUP_DIR/"
  - path: /home/labuser/pam-restore.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Restore PAM and SSSD configuration from the most recent backup
      LATEST=$(ls -1d "$HOME"/pam-backup-* 2>/dev/null | sort | tail -1)
      if [[ -z "$LATEST" ]]; then
        echo "No backup found! Run pam-backup.sh first."
        exit 1
      fi
      echo "Restoring from: $LATEST"
      if [[ -d "$LATEST/pam.d" ]]; then
        sudo cp -a "$LATEST/pam.d/"* /etc/pam.d/
        echo "  Restored /etc/pam.d/"
      fi
      if [[ -d "$LATEST/sssd" ]]; then
        sudo cp -a "$LATEST/sssd/"* /etc/sssd/
        echo "  Restored /etc/sssd/"
      fi
      for f in pwquality.conf limits.conf time.conf access.conf; do
        if [[ -f "$LATEST/$f" ]]; then
          sudo cp "$LATEST/$f" "/etc/security/$f"
          echo "  Restored /etc/security/$f"
        fi
      done
      echo "Restore complete. You may need to restart services (sshd, sssd)."
  - path: /etc/motd.raw
    content: |
      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
        \033[1;32mpam-lab-server\033[0m — \033[1mPAM Authentication Lab\033[0m
      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m

        \033[1;33mRole:\033[0m  PAM Server — configure and test PAM modules
        \033[1;33mInternal IP:\033[0m  \033[1;36m192.168.100.1\033[0m

        \033[1;33mOther VMs:\033[0m
          \033[0;32mpam-lab-client\033[0m   192.168.100.2  (SSH client)
          \033[0;32mpam-lab-ldap\033[0m     192.168.100.3  (OpenLDAP)

        \033[1;33mTest Users:\033[0m
          \033[0;32mtestuser\033[0m / Test123!
          \033[0;32malice\033[0m    / Alice123!

        \033[1;33mSafety Net:\033[0m
          \033[0;32msudo ~/pam-backup.sh\033[0m     backup PAM config
          \033[0;32msudo ~/pam-restore.sh\033[0m    restore from backup

        \033[1;33mInstalled PAM modules:\033[0m
          \033[0;32mpam_pwquality\033[0m     password complexity
          \033[0;32mpam_faillock\033[0m      account lockout
          \033[0;32mpam_limits\033[0m        resource limits
          \033[0;32mpam_time\033[0m          time-based access
          \033[0;32mpam_access\033[0m        host/user access
          \033[0;32mpam_exec\033[0m          custom scripts
          \033[0;32mpam_google_authenticator\033[0m  TOTP 2FA
          \033[0;32msssd/pam_sss\033[0m      LDAP integration

        \033[1;33mUseful Commands:\033[0m
          \033[0;32msudo pamtester <service> <user> authenticate\033[0m
          \033[0;32mcat /etc/pam.d/common-auth\033[0m
          \033[0;32mfaillock --user testuser\033[0m

        \033[1;33mCredentials:\033[0m  \033[1;36mlabuser\033[0m / \033[1;36mlabpass\033[0m
        \033[1;33mExit:\033[0m         type '\033[1;31mexit\033[0m'

      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m


  - path: /tmp/setup-zsh.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
      sed -i 's/^ZSH_THEME=.*/ZSH_THEME="agnoster"/' ~/.zshrc
      sed -i 's/^plugins=(.*)/plugins=(git)/' ~/.zshrc
runcmd:
  - netplan apply
  # Fix ownership of helper scripts
  - chown labuser:labuser /home/labuser/pam-backup.sh /home/labuser/pam-restore.sh
  # Add host entries
  - echo "192.168.100.2 pam-lab-client" >> /etc/hosts
  - echo "192.168.100.3 pam-lab-ldap" >> /etc/hosts
  # Create test users
  - useradd -m -s /bin/bash testuser
  - echo "testuser:Test123!" | chpasswd
  - useradd -m -s /bin/bash alice
  - echo "alice:Alice123!" | chpasswd
  # Enable PasswordAuthentication for SSH
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
  # MOTD setup
  - chmod -x /etc/update-motd.d/*
  - sed -i 's/^#\?PrintMotd.*/PrintMotd yes/' /etc/ssh/sshd_config
  - sed -i 's/^session.*pam_motd.*/# &/' /etc/pam.d/sshd
  - printf '%b\n' "$(cat /etc/motd.raw)" > /etc/motd
  - rm -f /etc/motd.raw
  - systemctl restart sshd
  # Re-set test user passwords after pam-auth-update (libpam-sss may alter PAM stack)
  - echo "testuser:Test123!" | chpasswd
  - echo "alice:Alice123!" | chpasswd
  - sudo -Hu labuser bash /tmp/setup-zsh.sh
  - chsh -s /usr/bin/zsh labuser
  - echo "=== pam-lab-server VM is ready! ==="
USERDATA

sed -i "s|__QLAB_SSH_PUB_KEY__|${QLAB_SSH_PUB_KEY:-}|g" "$LAB_DIR/user-data-server"

cat > "$LAB_DIR/meta-data-server" <<METADATA
instance-id: ${SERVER_VM}-001
local-hostname: ${SERVER_VM}
METADATA

success "Created cloud-init for $SERVER_VM"

# --- PAM Client VM cloud-init ---
info "Creating cloud-init for $CLIENT_VM..."
cat > "$LAB_DIR/user-data-client" <<'USERDATA'
#cloud-config
hostname: pam-lab-client
package_update: true
users:
  - name: labuser
    plain_text_passwd: labpass
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - "__QLAB_SSH_PUB_KEY__"
ssh_pwauth: true
packages:
  - openssh-client
  - pamtester
  - sshpass
  - nano
  - net-tools
  - iputils-ping
  - curl
  - zsh
  - vim
  - nano
  - fonts-powerline
write_files:
  - path: /etc/profile.d/cloud-init-status.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      if command -v cloud-init >/dev/null 2>&1; then
        status=$(cloud-init status 2>/dev/null)
        if echo "$status" | grep -q "running"; then
          printf '\033[1;33m'
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Cloud-init is still running..."
          echo "  Some packages and services may not be ready yet."
          echo "  Run 'cloud-init status --wait' to wait for completion."
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          printf '\033[0m\n'
        fi
      fi
  - path: /etc/netplan/60-internal.yaml
    content: |
      network:
        version: 2
        ethernets:
          pamlan:
            match:
              macaddress: "52:54:00:00:06:02"
            addresses:
              - 192.168.100.2/24
  - path: /etc/motd.raw
    content: |
      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
        \033[1;31mpam-lab-client\033[0m — \033[1mSSH Client\033[0m
      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m

        \033[1;33mRole:\033[0m  SSH Client — test PAM policies remotely
        \033[1;33mInternal IP:\033[0m  \033[1;36m192.168.100.2\033[0m

        \033[1;33mServers:\033[0m
          \033[0;32mpam-lab-server\033[0m   192.168.100.1  (PAM configs)
          \033[0;32mpam-lab-ldap\033[0m     192.168.100.3  (OpenLDAP)

        \033[1;33mQuick Test Commands:\033[0m
          \033[0;32mssh testuser@192.168.100.1\033[0m        test PAM login
          \033[0;32mssh alice@192.168.100.1\033[0m           test alice login
          \033[0;32msshpass -p 'Test123!' ssh testuser@192.168.100.1\033[0m
          \033[0;32mping 192.168.100.1\033[0m                test connectivity

        \033[1;33mCredentials:\033[0m  \033[1;36mlabuser\033[0m / \033[1;36mlabpass\033[0m
        \033[1;33mExit:\033[0m         type '\033[1;31mexit\033[0m'

      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m


  - path: /tmp/setup-zsh.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
      sed -i 's/^ZSH_THEME=.*/ZSH_THEME="agnoster"/' ~/.zshrc
      sed -i 's/^plugins=(.*)/plugins=(git)/' ~/.zshrc
runcmd:
  - netplan apply
  # Add host entries
  - echo "192.168.100.1 pam-lab-server" >> /etc/hosts
  - echo "192.168.100.3 pam-lab-ldap" >> /etc/hosts
  # MOTD setup
  - chmod -x /etc/update-motd.d/*
  - sed -i 's/^#\?PrintMotd.*/PrintMotd yes/' /etc/ssh/sshd_config
  - sed -i 's/^session.*pam_motd.*/# &/' /etc/pam.d/sshd
  - printf '%b\n' "$(cat /etc/motd.raw)" > /etc/motd
  - rm -f /etc/motd.raw
  - systemctl restart sshd
  - sudo -Hu labuser bash /tmp/setup-zsh.sh
  - chsh -s /usr/bin/zsh labuser
  - echo "=== pam-lab-client VM is ready! ==="
USERDATA

sed -i "s|__QLAB_SSH_PUB_KEY__|${QLAB_SSH_PUB_KEY:-}|g" "$LAB_DIR/user-data-client"

cat > "$LAB_DIR/meta-data-client" <<METADATA
instance-id: ${CLIENT_VM}-001
local-hostname: ${CLIENT_VM}
METADATA

success "Created cloud-init for $CLIENT_VM"

# --- LDAP Server VM cloud-init ---
info "Creating cloud-init for $LDAP_VM..."
cat > "$LAB_DIR/user-data-ldap" <<'USERDATA'
#cloud-config
hostname: pam-lab-ldap
package_update: true
users:
  - name: labuser
    plain_text_passwd: labpass
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - "__QLAB_SSH_PUB_KEY__"
ssh_pwauth: true
packages:
  - slapd
  - ldap-utils
  - nano
  - net-tools
  - iputils-ping
  - zsh
  - vim
  - nano
  - fonts-powerline
write_files:
  - path: /etc/profile.d/cloud-init-status.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      if command -v cloud-init >/dev/null 2>&1; then
        status=$(cloud-init status 2>/dev/null)
        if echo "$status" | grep -q "running"; then
          printf '\033[1;33m'
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Cloud-init is still running..."
          echo "  Some packages and services may not be ready yet."
          echo "  Run 'cloud-init status --wait' to wait for completion."
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          printf '\033[0m\n'
        fi
      fi
  - path: /etc/netplan/60-internal.yaml
    content: |
      network:
        version: 2
        ethernets:
          pamlan:
            match:
              macaddress: "52:54:00:00:06:03"
            addresses:
              - 192.168.100.3/24
  - path: /home/labuser/ldap-setup.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      echo "=== Configuring OpenLDAP for pam-lab.local ==="

      # Stop slapd for reconfiguration
      sudo systemctl stop slapd

      # Reconfigure slapd non-interactively
      sudo debconf-set-selections <<DEBCONF
      slapd slapd/no_configuration boolean false
      slapd slapd/domain string pam-lab.local
      slapd shared/organization string PAM Lab
      slapd slapd/password1 password ldapadmin
      slapd slapd/password2 password ldapadmin
      slapd slapd/backend select MDB
      slapd slapd/purge_database boolean true
      slapd slapd/move_old_database boolean true
      DEBCONF
      sudo dpkg-reconfigure -f noninteractive slapd

      # Wait for slapd to be ready
      sleep 2
      sudo systemctl start slapd
      sleep 2

      echo "=== Creating OUs ==="
      ldapadd -x -D "cn=admin,dc=pam-lab,dc=local" -w ldapadmin <<LDIF
      dn: ou=users,dc=pam-lab,dc=local
      objectClass: organizationalUnit
      ou: users

      dn: ou=groups,dc=pam-lab,dc=local
      objectClass: organizationalUnit
      ou: groups
      LDIF

      echo "=== Creating LDAP users ==="
      LDAPUSER1_PASS=$(slappasswd -s "Ldap123!")
      LDAPUSER2_PASS=$(slappasswd -s "Ldap456!")

      ldapadd -x -D "cn=admin,dc=pam-lab,dc=local" -w ldapadmin <<LDIF
      dn: uid=ldapuser1,ou=users,dc=pam-lab,dc=local
      objectClass: inetOrgPerson
      objectClass: posixAccount
      objectClass: shadowAccount
      uid: ldapuser1
      sn: User1
      givenName: LDAP
      cn: LDAP User1
      displayName: LDAP User1
      uidNumber: 10001
      gidNumber: 10000
      homeDirectory: /home/ldapuser1
      loginShell: /bin/bash
      mail: ldapuser1@pam-lab.local
      userPassword: $LDAPUSER1_PASS

      dn: uid=ldapuser2,ou=users,dc=pam-lab,dc=local
      objectClass: inetOrgPerson
      objectClass: posixAccount
      objectClass: shadowAccount
      uid: ldapuser2
      sn: User2
      givenName: LDAP
      cn: LDAP User2
      displayName: LDAP User2
      uidNumber: 10002
      gidNumber: 10000
      homeDirectory: /home/ldapuser2
      loginShell: /bin/bash
      mail: ldapuser2@pam-lab.local
      userPassword: $LDAPUSER2_PASS
      LDIF

      echo "=== Creating LDAP group ==="
      ldapadd -x -D "cn=admin,dc=pam-lab,dc=local" -w ldapadmin <<LDIF
      dn: cn=pamtesters,ou=groups,dc=pam-lab,dc=local
      objectClass: posixGroup
      cn: pamtesters
      gidNumber: 10000
      memberUid: ldapuser1
      memberUid: ldapuser2
      LDIF

      echo "=== Verifying LDAP setup ==="
      ldapsearch -x -H ldap://localhost -b "dc=pam-lab,dc=local" -LLL "(objectClass=posixAccount)" uid cn
      echo ""
      echo "=== OpenLDAP setup complete! ==="
      echo "  Domain:   pam-lab.local (dc=pam-lab,dc=local)"
      echo "  Admin DN: cn=admin,dc=pam-lab,dc=local"
      echo "  Admin PW: ldapadmin"
      echo "  Users:    ldapuser1 (Ldap123!), ldapuser2 (Ldap456!)"
      echo "  Group:    pamtesters"
  - path: /etc/motd.raw
    content: |
      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
        \033[1;35mpam-lab-ldap\033[0m — \033[1mOpenLDAP Server\033[0m
      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m

        \033[1;33mRole:\033[0m  OpenLDAP Server (pam-lab.local)
        \033[1;33mInternal IP:\033[0m  \033[1;36m192.168.100.3\033[0m

        \033[1;33mLDAP Configuration:\033[0m
          \033[0;32mDomain:\033[0m     pam-lab.local
          \033[0;32mBase DN:\033[0m    dc=pam-lab,dc=local
          \033[0;32mAdmin DN:\033[0m   cn=admin,dc=pam-lab,dc=local
          \033[0;32mAdmin PW:\033[0m   ldapadmin

        \033[1;33mLDAP Users:\033[0m
          \033[0;32mldapuser1\033[0m / Ldap123!  (UID 10001)
          \033[0;32mldapuser2\033[0m / Ldap456!  (UID 10002)

        \033[1;33mLDAP Group:\033[0m
          \033[0;32mpamtesters\033[0m (GID 10000)

        \033[1;33mUseful Commands:\033[0m
          \033[0;32mldapsearch -x -H ldap://localhost -b "dc=pam-lab,dc=local" -LLL\033[0m
          \033[0;32msudo systemctl status slapd\033[0m
          \033[0;32msudo journalctl -u slapd -f\033[0m

        \033[1;33mCredentials:\033[0m  \033[1;36mlabuser\033[0m / \033[1;36mlabpass\033[0m
        \033[1;33mExit:\033[0m         type '\033[1;31mexit\033[0m'

      \033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m


  - path: /tmp/setup-zsh.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
      sed -i 's/^ZSH_THEME=.*/ZSH_THEME="agnoster"/' ~/.zshrc
      sed -i 's/^plugins=(.*)/plugins=(git)/' ~/.zshrc
runcmd:
  - netplan apply
  # Fix ownership of helper scripts
  - chown labuser:labuser /home/labuser/ldap-setup.sh
  # Add host entries
  - echo "192.168.100.1 pam-lab-server" >> /etc/hosts
  - echo "192.168.100.2 pam-lab-client" >> /etc/hosts
  # Run LDAP setup automatically
  - bash /home/labuser/ldap-setup.sh
  # MOTD setup
  - chmod -x /etc/update-motd.d/*
  - sed -i 's/^#\?PrintMotd.*/PrintMotd yes/' /etc/ssh/sshd_config
  - sed -i 's/^session.*pam_motd.*/# &/' /etc/pam.d/sshd
  - printf '%b\n' "$(cat /etc/motd.raw)" > /etc/motd
  - rm -f /etc/motd.raw
  - systemctl restart sshd
  - sudo -Hu labuser bash /tmp/setup-zsh.sh
  - chsh -s /usr/bin/zsh labuser
  - echo "=== pam-lab-ldap VM is ready! ==="
USERDATA

sed -i "s|__QLAB_SSH_PUB_KEY__|${QLAB_SSH_PUB_KEY:-}|g" "$LAB_DIR/user-data-ldap"

cat > "$LAB_DIR/meta-data-ldap" <<METADATA
instance-id: ${LDAP_VM}-001
local-hostname: ${LDAP_VM}
METADATA

success "Created cloud-init for $LDAP_VM"
echo ""

# =============================================
# Step 3: Generate cloud-init ISOs
# =============================================
info "Step 3: Cloud-init ISOs"
echo ""
check_dependency genisoimage || {
    warn "genisoimage not found. Install it with: sudo apt install genisoimage"
    exit 1
}

CIDATA_SERVER="$LAB_DIR/cidata-server.iso"
genisoimage -output "$CIDATA_SERVER" -volid cidata -joliet -rock \
    -graft-points "user-data=$LAB_DIR/user-data-server" "meta-data=$LAB_DIR/meta-data-server" 2>/dev/null
success "Created cloud-init ISO: $CIDATA_SERVER"

CIDATA_CLIENT="$LAB_DIR/cidata-client.iso"
genisoimage -output "$CIDATA_CLIENT" -volid cidata -joliet -rock \
    -graft-points "user-data=$LAB_DIR/user-data-client" "meta-data=$LAB_DIR/meta-data-client" 2>/dev/null
success "Created cloud-init ISO: $CIDATA_CLIENT"

CIDATA_LDAP="$LAB_DIR/cidata-ldap.iso"
genisoimage -output "$CIDATA_LDAP" -volid cidata -joliet -rock \
    -graft-points "user-data=$LAB_DIR/user-data-ldap" "meta-data=$LAB_DIR/meta-data-ldap" 2>/dev/null
success "Created cloud-init ISO: $CIDATA_LDAP"
echo ""

# =============================================
# Step 4: Create overlay disks
# =============================================
info "Step 4: Overlay disks"
echo ""
echo "  Each VM gets its own overlay disk (copy-on-write) so the"
echo "  base cloud image is never modified."
echo ""

OVERLAY_SERVER="$LAB_DIR/${SERVER_VM}-disk.qcow2"
if [[ -f "$OVERLAY_SERVER" ]]; then rm -f "$OVERLAY_SERVER"; fi
create_overlay "$CLOUD_IMAGE_FILE" "$OVERLAY_SERVER" "${QLAB_DISK_SIZE:-}" || {
    error "Failed to create overlay disk for server."
    exit 1
}

OVERLAY_CLIENT="$LAB_DIR/${CLIENT_VM}-disk.qcow2"
if [[ -f "$OVERLAY_CLIENT" ]]; then rm -f "$OVERLAY_CLIENT"; fi
create_overlay "$CLOUD_IMAGE_FILE" "$OVERLAY_CLIENT" "${QLAB_DISK_SIZE:-}" || {
    error "Failed to create overlay disk for client."
    exit 1
}

OVERLAY_LDAP="$LAB_DIR/${LDAP_VM}-disk.qcow2"
if [[ -f "$OVERLAY_LDAP" ]]; then rm -f "$OVERLAY_LDAP"; fi
create_overlay "$CLOUD_IMAGE_FILE" "$OVERLAY_LDAP" "${QLAB_DISK_SIZE:-}" || {
    error "Failed to create overlay disk for LDAP server."
    exit 1
}
echo ""

# =============================================
# Step 5: Start all VMs
# =============================================
info "Step 5: Starting VMs (internal LAN: 192.168.100.0/24)"
echo ""

# Multi-VM: resource check, cleanup trap, rollback on failure
MEMORY_TOTAL=$(( MEMORY * 3 ))
check_host_resources "$MEMORY_TOTAL" 3
declare -a STARTED_VMS=()
register_vm_cleanup STARTED_VMS

info "Starting $SERVER_VM..."
start_vm_or_fail STARTED_VMS "$OVERLAY_SERVER" "$CIDATA_SERVER" "$MEMORY" "$SERVER_VM" auto \
    "-netdev" "socket,id=vlan1,mcast=${INTERNAL_MCAST}" \
    "-device" "virtio-net-pci,netdev=vlan1,mac=${SERVER_LAN_MAC}" || exit 1

echo ""

info "Starting $CLIENT_VM..."
start_vm_or_fail STARTED_VMS "$OVERLAY_CLIENT" "$CIDATA_CLIENT" "$MEMORY" "$CLIENT_VM" auto \
    "-netdev" "socket,id=vlan1,mcast=${INTERNAL_MCAST}" \
    "-device" "virtio-net-pci,netdev=vlan1,mac=${CLIENT_LAN_MAC}" || exit 1

echo ""

info "Starting $LDAP_VM..."
start_vm_or_fail STARTED_VMS "$OVERLAY_LDAP" "$CIDATA_LDAP" "$MEMORY" "$LDAP_VM" auto \
    "-netdev" "socket,id=vlan1,mcast=${INTERNAL_MCAST}" \
    "-device" "virtio-net-pci,netdev=vlan1,mac=${LDAP_LAN_MAC}" || exit 1

# Successful start — disable cleanup trap
trap - EXIT

echo ""
echo "============================================="
echo "  pam-lab: All VMs are booting"
echo "============================================="
echo ""
echo "  PAM Server VM:"
echo "    SSH:          qlab shell $SERVER_VM"
echo "    Log:          qlab log $SERVER_VM"
echo "    Internal IP:  $SERVER_INTERNAL_IP"
echo "    Test users:   testuser / Test123!, alice / Alice123!"
echo ""
echo "  SSH Client VM:"
echo "    SSH:          qlab shell $CLIENT_VM"
echo "    Log:          qlab log $CLIENT_VM"
echo "    Internal IP:  $CLIENT_INTERNAL_IP"
echo ""
echo "  OpenLDAP Server VM:"
echo "    SSH:          qlab shell $LDAP_VM"
echo "    Log:          qlab log $LDAP_VM"
echo "    Internal IP:  $LDAP_INTERNAL_IP"
echo "    LDAP domain:  pam-lab.local"
echo "    LDAP users:   ldapuser1 / Ldap123!, ldapuser2 / Ldap456!"
echo ""
echo "  Internal LAN:  192.168.100.0/24"
echo "  Credentials:   labuser / labpass"
echo ""
echo "  Quick test (after boot ~90s):"
echo "    qlab shell $CLIENT_VM"
echo "    ssh testuser@192.168.100.1              # test PAM login"
echo "    ping 192.168.100.3                      # test LDAP reachable"
echo ""
echo "  Stop all VMs:"
echo "    qlab stop $PLUGIN_NAME"
echo ""
echo "  Tip: override resources with environment variables:"
echo "    QLAB_MEMORY=1024 qlab run ${PLUGIN_NAME}"
echo "============================================="
