#!/bin/bash
# StoneShop Server Hardening — Phase 1
# Run as root on a fresh Ubuntu 24.04 server.
# Usage: sudo bash harden.sh

set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

echo "=== StoneShop Server Hardening ==="

# ── Hostname ──────────────────────────────────────────────
echo "Setting hostname to stoneshop..."
hostnamectl set-hostname stoneshop

# ── Groups and Users ─────────────────────────────────────
echo "Creating groups and deploy user..."
groupadd -f --gid 1100 stoneshop
groupadd -f project

if ! id deploy &>/dev/null; then
    useradd -m -u 1001 -s /bin/bash -G sudo,stoneshop,project deploy
    echo "Created user 'deploy'. Set a password or add SSH keys manually."
else
    usermod -aG sudo,stoneshop,project deploy
    echo "User 'deploy' already exists, updated groups."
fi

# Ensure deploy can sudo without password (for cron scripts)
echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
chmod 0440 /etc/sudoers.d/deploy

# ── SSH Hardening ─────────────────────────────────────────
echo "Hardening SSH..."
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'SSHEOF'
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
SSHEOF

# Ensure deploy has .ssh directory
sudo -u deploy mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chown deploy:deploy /home/deploy/.ssh

# Copy SSH keys from root if available, otherwise prompt
if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
    chown deploy:deploy /home/deploy/.ssh/authorized_keys
    chmod 600 /home/deploy/.ssh/authorized_keys
    echo "Copied SSH authorized_keys from root to deploy."
else
    echo "NOTE: No root SSH keys found. Add your SSH public key to /home/deploy/.ssh/authorized_keys"
fi

systemctl restart ssh

# ── UFW Firewall ──────────────────────────────────────────
echo "Configuring UFW..."
apt-get update -qq
apt-get install -y -qq ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'HTTP/3 QUIC'
ufw --force enable

# ── fail2ban ──────────────────────────────────────────────
echo "Installing fail2ban..."
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.d/sshd.conf <<'F2BEOF'
[sshd]
enabled = true
port = 22
maxretry = 5
bantime = 3600
findtime = 600
F2BEOF

systemctl enable fail2ban
systemctl restart fail2ban

# ── Sysctl Hardening ─────────────────────────────────────
echo "Applying sysctl hardening..."
cat > /etc/sysctl.d/99-stoneshop.conf <<'SYSEOF'
# Swap
vm.swappiness = 10

# Network security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1

# IPv6
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Kernel
kernel.randomize_va_space = 2
SYSEOF

sysctl --system > /dev/null

# ── Swap ──────────────────────────────────────────────────
echo "Setting up 2GB swap..."
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    echo "Swapfile already exists, skipping."
fi

# ── Unattended Upgrades ──────────────────────────────────
echo "Configuring unattended-upgrades..."
apt-get install -y -qq unattended-upgrades

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
UUEOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUEOF

# ── Logrotate ─────────────────────────────────────────────
echo "Configuring logrotate for stoneshop..."
cat > /etc/logrotate.d/stoneshop <<'LREOF'
/opt/stoneshop/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 deploy stoneshop
    sharedscripts
}
LREOF

# ── Essential Packages ────────────────────────────────────
echo "Installing essential packages..."
apt-get install -y -qq \
    curl \
    wget \
    htop \
    tmux \
    jq

echo ""
echo "=== Hardening complete ==="
echo ""
echo "Next steps:"
echo "  1. Add SSH public key: /home/deploy/.ssh/authorized_keys"
echo "  2. Test SSH login as deploy before closing this session"
echo "  3. Run infra/setup.sh to install Docker and deploy the stack"
