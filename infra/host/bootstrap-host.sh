#!/usr/bin/env bash
# One-shot RHEL 9 host bootstrap, run by cloud-init as root on first boot.
#
# Fails closed: if any step fails, /var/lib/ai-sandbox/NOT_READY explains why
# and sandbox-run refuses to start. Success writes /var/lib/ai-sandbox/READY.
# Re-running is safe; every step is idempotent.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/ai-sandbox/host.conf

SVC_USER=ai-sandbox
SVC_HOME=/var/lib/ai-sandbox/home
STATE_DIR=/var/lib/ai-sandbox
LOG_DIR=/var/log/ai-sandbox
SRC_DIR=/opt/ai-sandbox/acq-src

mkdir -p "$STATE_DIR" "$LOG_DIR/runs"
exec > >(tee -a "$LOG_DIR/bootstrap.log" | logger -t ai-sandbox-bootstrap -p local5.info) 2>&1
rm -f "$STATE_DIR/READY"

fail() {
  echo "BOOTSTRAP FAILED: $*"
  printf '%s\n' "$*" > "$STATE_DIR/NOT_READY"
  exit 1
}
trap 'fail "unexpected error on line $LINENO"' ERR

step() { echo "==> $*"; }

step "Checking nested virtualization"
if [ ! -c /dev/kvm ]; then
  fail "/dev/kvm is missing: the VM size or security type does not expose nested virtualization. Redeploy with a Dsv5/Ddsv5/Esv5 size, or securityType=Standard."
fi

step "Validating pinned acq commit"
[[ "$ACQ_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "ACQ_COMMIT_SHA is not a 40-character lowercase commit SHA"

step "Installing packages"
dnf -y -q install git jq tar curl audit rsyslog util-linux \
  policycoreutils-python-utils setools-console setroubleshoot-server

step "Enforcing SELinux"
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
if [ "$(getenforce)" != "Enforcing" ]; then
  setenforce 1
fi

step "Creating sandbox service account"
if ! id "$SVC_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$SVC_HOME" --shell /bin/bash "$SVC_USER"
fi
usermod -aG kvm "$SVC_USER"
chmod 0750 "$SVC_HOME"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 "$STATE_DIR/work"
install -d -o root -g "$SVC_USER" -m 0770 "$LOG_DIR/runs"
install -d -o root -g root -m 0755 /etc/ai-sandbox/providers

step "Making /dev/kvm group-owned by kvm (0660)"
cat > /etc/udev/rules.d/65-kvm.rules <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF
udevadm control --reload-rules
udevadm trigger --name-match=kvm

step "Fetching acq at $ACQ_COMMIT_SHA"
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --quiet "$ACQ_REPO_URL" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --quiet origin "$ACQ_COMMIT_SHA"
git -C "$SRC_DIR" -c advice.detachedHead=false checkout --quiet "$ACQ_COMMIT_SHA"
[ "$(git -C "$SRC_DIR" rev-parse HEAD)" = "$ACQ_COMMIT_SHA" ] || fail "acq checkout does not match the pinned commit"
chown -R root:root "$SRC_DIR"
chmod -R go-w "$SRC_DIR"

step "Installing acq and the pinned msb runtime for $SVC_USER"
sudo -u "$SVC_USER" -H env \
  ACQ_INSTALL_REPO_URL="$ACQ_REPO_URL" \
  sh "$SRC_DIR/install.sh" --method clone --sha "$ACQ_COMMIT_SHA" --yes

step "Configuring acq defaults"
cat > /etc/ai-sandbox/sandbox.conf <<EOF
# Read by /usr/local/bin/sandbox-run. Root-owned: the service account cannot change it.
MAX_SANDBOXES=$MAX_SANDBOXES
ACQ_BACKEND=msb
ACQ_NETWORK_TIER=strict
EOF
chmod 0644 /etc/ai-sandbox/sandbox.conf

step "Allowing operators to run sandbox-run (and only sandbox-run) as $SVC_USER"
# Only Entra-authorized users can sign in at all, so ALL here means "any
# operator the RBAC role assignment admits".
cat > /etc/sudoers.d/90-ai-sandbox <<EOF
Defaults:$SVC_USER !requiretty
ALL ALL=($SVC_USER) NOPASSWD: /usr/local/bin/sandbox-run
EOF
chmod 0440 /etc/sudoers.d/90-ai-sandbox
visudo -cq

step "Forwarding auditd to syslog (local6) for the Azure Monitor Agent"
sed -i -e 's/^active = .*/active = yes/' -e 's/^args = .*/args = LOG_LOCAL6/' \
  /etc/audit/plugins.d/syslog.conf
mkdir -p "$SVC_HOME/.local/bin" "$SVC_HOME/.local/share/acq" "$SVC_HOME/.config/acq" "$SVC_HOME/.microsandbox"
chown -R "$SVC_USER:$SVC_USER" "$SVC_HOME"
augenrules --load
service auditd restart
systemctl enable --now rsyslog

step "Running msb doctor"
MSB_BIN="$SVC_HOME/.local/bin/msb"
if [ ! -x "$MSB_BIN" ]; then
  MSB_BIN=$(sudo -u "$SVC_USER" -H bash -lc 'command -v msb' || true)
fi
[ -n "$MSB_BIN" ] || fail "msb was not installed"
sudo -u "$SVC_USER" -H "$MSB_BIN" doctor || fail "msb doctor reports the host is not ready for microVMs"

step "Locking the throwaway local admin ($ADMIN_USER)"
if id "$ADMIN_USER" >/dev/null 2>&1; then
  passwd -l "$ADMIN_USER" >/dev/null
  : > "/home/$ADMIN_USER/.ssh/authorized_keys"
  usermod -s /sbin/nologin "$ADMIN_USER"
fi

step "Recording SELinux denials seen during bootstrap (review before going live)"
ausearch -m AVC,USER_AVC -ts boot 2>/dev/null > "$LOG_DIR/selinux-denials-bootstrap.txt" || true

trap - ERR
rm -f "$STATE_DIR/NOT_READY"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/READY"
echo "BOOTSTRAP COMPLETE"
