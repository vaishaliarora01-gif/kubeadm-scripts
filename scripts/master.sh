#!/bin/bash
#
# Setup for Control Plane (Master) server - Ubuntu 22.04
set -euxo pipefail

# === Config ===
PUBLIC_IP_ACCESS="true"                 # expose API on the instance's public IP (not recommended for prod)
POD_CIDR="192.168.0.0/16"               # match your CNI choice (Calico default here)
NODENAME="$(hostname -s)"

# === Discover IPs (prefer AWS IMDS) ===
IMDS="http://169.254.169.254/latest"
TOKEN="$(curl -fsSL -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
get_md() { curl -fsSL -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/$1"; }

PRIVATE_IP="$(get_md local-ipv4 || true)"
PUBLIC_IP="$(get_md public-ipv4 || true)"


# Fallbacks if not on EC2/IMDS not available
if [[ -z "${PRIVATE_IP}" ]]; then
  PRIMARY_IFACE="$(ip -j route get 1.1.1.1 | jq -r '.[0].dev')"
  PRIVATE_IP="$(ip -j addr show "$PRIMARY_IFACE" | jq -r '.[0].addr_info[] | select(.family=="inet") | .local' | head -n1)"
fi

# Build cert SANs (always include localhost + private; include public if present)
CERT_SANS=("127.0.0.1" "${PRIVATE_IP}" "${NODENAME}")
if [[ -n "${PUBLIC_IP}" ]]; then
  CERT_SANS+=("${PUBLIC_IP}")
fi
CERT_SANS_CSV="$(IFS=, ; echo "${CERT_SANS[*]}")"

# === Pull required images (optional but speeds up init) ===
sudo kubeadm config images pull

# === kubeadm init ===
INIT_ARGS=(
  --apiserver-advertise-address="${PRIVATE_IP}"
  --apiserver-cert-extra-sans="${CERT_SANS_CSV}"
  --pod-network-cidr="${POD_CIDR}"
  --node-name "${NODENAME}"
)

# If you truly want the API reachable on the public IP, set the control-plane endpoint to it.
# NOTE: For HA you should use a stable DNS name/NLB here instead.
if [[ "${PUBLIC_IP_ACCESS}" == "true" && -n "${PUBLIC_IP}" ]]; then
  INIT_ARGS+=( --control-plane-endpoint="${PUBLIC_IP}" )
fi

sudo kubeadm init "${INIT_ARGS[@]}"

# === kubeconfig for the current user ===
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# === Install Calico CNI (versioned manifest) ===
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml

# === Quality of life: save join command for workers ===
kubeadm token create --print-join-command | tee "$HOME/kubeadm-join.sh"
chmod +x "$HOME/kubeadm-join.sh"

echo "✅ Control plane initialized on ${PRIVATE_IP} (public access: ${PUBLIC_IP_ACCESS})."
echo "➡  Worker join command saved to $HOME/kubeadm-join.sh"
