#!/bin/bash
# Common setup for ALL nodes (control-plane + workers) on Ubuntu 22.04/24.04
set -euxo pipefail

# Must run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash common.sh"
  exit 1
fi

# --- Versions (change minor to 1.30 if you want that stream) ---
K8S_MINOR="1.29"        # Kubernetes & CRI-O minor stream

# --- Disable swap now & on boot ---
swapoff -a || true
if grep -Eq '^[^#].*\s+swap\s' /etc/fstab; then
  sed -i.bak '/\sswap\s/s/^\(.*\)$/# \1/' /etc/fstab
fi

# --- Base tools ---
apt-get update -y
apt-get install -y curl ca-certificates gpg jq apt-transport-https iproute2

# --- Kernel modules & sysctl for Kubernetes networking ---
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# --- Clean any old/dead repos from previous attempts (safe on fresh VMs) ---
rm -f /etc/apt/sources.list.d/devel:kubic:libcontainers:stable*.list || true
rm -f /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:* || true
rm -f /etc/apt/trusted.gpg.d/libcontainers.gpg || true

# --- Add official pkgs.k8s.io repos (no apt-key) ---
install -d -m 0755 /etc/apt/keyrings

# CRI-O (v${K8S_MINOR})
curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] \
https://pkgs.k8s.io/addons:/cri-o:/stable:/v${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/cri-o.list

# Kubernetes core (v${K8S_MINOR})
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes-${K8S_MINOR}.list

apt-get update -y

# --- Install container runtime (CRI-O) ---
apt-get install -y cri-o
# Ensure a low-level runtime is present (Ubuntu usually has runc)
if ! command -v runc >/dev/null 2>&1; then
  apt-get install -y runc || true
fi
systemctl enable --now crio

# Remove default CNI snippets so your chosen CNI owns /etc/cni/net.d
rm -f /etc/cni/net.d/* || true

# --- Install Kubernetes node tools (latest 1.29.z from repo) ---
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# --- Kubelet: advertise the node's primary IPv4 (EC2-safe) ---
PRIMARY_IFACE="$(ip -j route get 1.1.1.1 | jq -r '.[0].dev // empty')"
if [[ -z "${PRIMARY_IFACE}" ]]; then
  PRIMARY_IFACE="$(ip -4 route list default | awk '{print $5}' | head -n1)"
fi
LOCAL_IP="$(ip -4 -o addr show dev "${PRIMARY_IFACE}" | awk '{split($4,a,"/"); print a[1]}' | head -n1)"

cat >/etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--node-ip=${LOCAL_IP}
EOF

systemctl enable --now kubelet || true

echo "✅ $(hostname): ready with CRI-O ${K8S_MINOR} & Kubernetes ${K8S_MINOR} (swap off, sysctl ok, kubelet -> ${LOCAL_IP})"
