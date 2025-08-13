#!/bin/bash
# Common setup for all servers (control-plane and workers) on Ubuntu 22.04
set -euxo pipefail

# --- Versions ---
KUBERNETES_VERSION="1.29.0-1.1"   # from pkgs.k8s.io
CRI_O_VERSION="1.29"
OS_CODENAME="xUbuntu_22.04"

# --- Disable swap now & forever ---
swapoff -a || true
if grep -Eq '^[^#].*\s+swap\s' /etc/fstab; then
  sed -i.bak '/\sswap\s/s/^\(.*\)$/# \1/' /etc/fstab
fi

apt-get update -y
apt-get install -y curl ca-certificates gpg jq apt-transport-https

# --- Kernel modules & sysctl ---
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

# --- Install CRI-O runtime ---
cat >/etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list <<EOF
deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/${OS_CODENAME}/ /
EOF
cat >/etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:${CRI_O_VERSION}.list <<EOF
deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${CRI_O_VERSION}/${OS_CODENAME}/ /
EOF

# Note: apt-key is deprecated but these repos still commonly use it
curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${CRI_O_VERSION}/${OS_CODENAME}/Release.key" \
  | apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -
curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/${OS_CODENAME}/Release.key" \
  | apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -

apt-get update -y
apt-get install -y cri-o cri-o-runc
systemctl enable --now crio

# --- Install kubelet/kubeadm/kubectl 1.29 ---
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-1-29-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-1-29-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes-1.29.list

apt-get update -y
apt-get install -y kubelet="${KUBERNETES_VERSION}" kubeadm="${KUBERNETES_VERSION}" kubectl="${KUBERNETES_VERSION}"
apt-mark hold kubelet kubeadm kubectl

# --- Kubelet: set node IP from primary interface (EC2-safe) ---
PRIMARY_IFACE="$(ip -j route get 1.1.1.1 | jq -r '.[0].dev')"
LOCAL_IP="$(ip -j addr show "$PRIMARY_IFACE" | jq -r '.[0].addr_info[] | select(.family=="inet") | .local' | head -n1)"

cat >/etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--node-ip=${LOCAL_IP}
EOF

systemctl enable --now kubelet || true

echo "✅ Base Kubernetes prerequisites completed on $(hostname) with CRI-O ${CRI_O_VERSION} and K8s ${KUBERNETES_VERSION}"
