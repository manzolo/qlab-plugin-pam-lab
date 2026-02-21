#!/usr/bin/env bash
# Common helpers for pam-lab test suite
# Sourced by each test script — not executed directly.

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Counters ────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0

# ── Logging ─────────────────────────────────────────────────────────
log_ok()   { printf "${GREEN}  [PASS]${RESET} %s\n" "$*"; }
log_fail() { printf "${RED}  [FAIL]${RESET} %s\n" "$*"; }
log_info() { printf "${YELLOW}  [INFO]${RESET} %s\n" "$*"; }

# ── Assertions ──────────────────────────────────────────────────────
assert() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        log_ok "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        log_fail "$description"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_fail() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        log_fail "$description"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        log_ok "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

assert_contains() {
    local description="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -qE "$pattern"; then
        log_ok "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        log_fail "$description (expected pattern: $pattern)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_not_contains() {
    local description="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -qE "$pattern"; then
        log_fail "$description (unexpected pattern: $pattern)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        log_ok "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

# ── Workspace detection ─────────────────────────────────────────────
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Find the qlab workspace — walk up until we find .qlab/
_find_workspace() {
    local dir="$PLUGIN_DIR"
    # If run from the plugin repo directly, look for .qlab in common locations
    if [[ -d "$dir/../../.qlab" ]]; then
        echo "$(cd "$dir/../.." && pwd)"
        return
    fi
    # Check if plugin is installed inside a workspace
    local d="$dir"
    while [[ "$d" != "/" ]]; do
        if [[ -d "$d/.qlab" ]]; then
            echo "$d"
            return
        fi
        d="$(dirname "$d")"
    done
    echo ""
}

WORKSPACE_DIR="$(_find_workspace)"
if [[ -z "$WORKSPACE_DIR" ]]; then
    echo "ERROR: Cannot find qlab workspace (.qlab/ directory). Make sure VMs are running."
    exit 1
fi

STATE_DIR="$WORKSPACE_DIR/.qlab/state"
SSH_KEY="$WORKSPACE_DIR/.qlab/ssh/qlab_key"

# ── Port discovery ──────────────────────────────────────────────────
_get_port() {
    local vm_name="$1"
    local port_file="$STATE_DIR/${vm_name}.port"
    if [[ -f "$port_file" ]]; then
        cat "$port_file"
    else
        echo ""
    fi
}

SERVER_PORT="$(_get_port pam-lab-server)"
CLIENT_PORT="$(_get_port pam-lab-client)"
LDAP_PORT="$(_get_port pam-lab-ldap)"

if [[ -z "$SERVER_PORT" || -z "$CLIENT_PORT" ]]; then
    echo "ERROR: Cannot find VM ports. Are the pam-lab VMs running?"
    echo "  Run: qlab run pam-lab"
    exit 1
fi

# ── SSH helpers ─────────────────────────────────────────────────────
_ssh_base_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

ssh_server() {
    ssh "${_ssh_base_opts[@]}" -i "$SSH_KEY" -p "$SERVER_PORT" labuser@localhost "$@"
}

ssh_client() {
    ssh "${_ssh_base_opts[@]}" -i "$SSH_KEY" -p "$CLIENT_PORT" labuser@localhost "$@"
}

ssh_ldap() {
    if [[ -z "$LDAP_PORT" ]]; then
        echo "ERROR: LDAP VM port not found"
        return 1
    fi
    ssh "${_ssh_base_opts[@]}" -i "$SSH_KEY" -p "$LDAP_PORT" labuser@localhost "$@"
}

# SSH from client VM to server VM via internal network using sshpass
sshpass_client_to_server() {
    local password="$1"
    local user="$2"
    shift 2
    ssh_client sshpass -p "'$password'" ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$user@192.168.100.1" "$@"
}

# ── Cleanup / reset helpers ─────────────────────────────────────────
reset_users() {
    log_info "Resetting faillock and passwords for testuser/alice..."
    ssh_server "sudo faillock --user testuser --reset 2>/dev/null; sudo faillock --user alice --reset 2>/dev/null; echo 'testuser:Test123!' | sudo chpasswd; echo 'alice:Alice123!' | sudo chpasswd"
}

backup_pam() {
    ssh_server "sudo ~/pam-backup.sh" >/dev/null 2>&1
}

restore_pam() {
    ssh_server "sudo ~/pam-restore.sh && sudo systemctl restart sshd" >/dev/null 2>&1
    sleep 1
}

# ── Test result reporting ───────────────────────────────────────────
report_results() {
    local test_name="${1:-Test}"
    echo ""
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        printf "${GREEN}${BOLD}  %s: All %d checks passed${RESET}\n" "$test_name" "$PASS_COUNT"
    else
        printf "${RED}${BOLD}  %s: %d passed, %d failed${RESET}\n" "$test_name" "$PASS_COUNT" "$FAIL_COUNT"
    fi
    return "$FAIL_COUNT"
}
