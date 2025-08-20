#!/bin/bash
# Control Plane setup (Ubuntu 22.04/24.04) for kubeadm + CRI-O
set -euxo pipefail

# ---------- Config ----------
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"   # e.g. "10.0.1.10" or "mycluster.example.com"
PUBLIC_IP_ACCESS="${PUBLIC_IP_ACCESS:-false}"          # fallback if no endpoint; not for prod
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"                 # Calico default
NODENAME="$(hostname -s)"
TAINT_CONTROL_PLANE="${TAINT_CONTROL_PLANE:-false}"    # default untaint in labs
TOKEN_TTL="${TOKEN_TTL:-24h}"                          # "0" for non-expiring lab token
FORCE_INIT="${FORCE_INIT:-false}"                      # set to "true" to bypass preflight CPU/Mem

# ---------- Resource preflight ----------
MIN_CPUS=2
MIN_MEM_MB=1700
CPUS="$(nproc --all)"
MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"

IGNORE_FLAGS=()
if (( CPUS < MIN_CPUS || MEM_MB < MIN_MEM_MB )); then
  echo "ERROR: Host has ${CPUS} vCPU and ${MEM_MB}MB RAM; needs >= ${MIN_CPUS} vCPU and >= ${MIN_MEM_MB}MB."
  if [[ "${FORCE_INIT}" == "true" ]]; then
    echo "FORCE_INIT=true → proceeding with --ignore-preflight-errors=NumCPU,Mem (lab-only, unstable)."
    IGNORE_FLAGS+=(--ignore-preflight-errors=NumCPU,Mem)
  else
    echo "Aborting. Resize the instance (e.g., t3.small or bigger) or rerun with FORCE_INIT=true for lab use."
    exit 1
  fi
fi

# ---------- Discover IPs (AWS IMDS with fallback) ----------
IMDS="http://169.254.169.254/latest"
TOKEN="$(curl -fsSL -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
get_md() {
  if [[ -n "$TOKEN" ]]; then
    curl -fsSL -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/$1" || true
  else
    curl -fsSL "$IMDS/meta-data/$1" || true
  fi
}

PRIVATE_IP="$(get_md local-ipv4 || true)"
PUBLIC_IP="$(get_md public-ipv4 || true)"

if [[ -z "${PRIVATE_IP}" ]]; then
  PRIMARY_IFACE="$(ip -j route get 1.1.1.1 | jq -r '.[0].dev')"
  PRIVATE_IP="$(ip -j addr show "$PRIMARY_IFACE" | jq -r '.[0].addr_info[] | select(.family=="inet") | .local' | head -n1)"
fi

# ---------- Cert SANs ----------
CERT_SANS=("127.0.0.1" "${PRIVATE_IP}" "${NODENAME}")
[[ -n "${PUBLIC_IP}" ]] && CERT_SANS+=("${PUBLIC_IP}")
[[ -n "${CONTROL_PLANE_ENDPOINT}" ]] && CERT_SANS+=("${CONTROL_PLANE_ENDPOINT}")
CERT_SANS_CSV="$(IFS=, ; echo "${CERT_SANS[*]}")"

# ---------- (Optional) Pre-pull control plane images ----------
kubeadm config images pull || true

# ---------- kubeadm init ----------
INIT_ARGS=(
  --apiserver-advertise-address="${PRIVATE_IP}"
  --apiserver-cert-extra-sans="${CERT_SANS_CSV}"
  --pod-network-cidr="${POD_CIDR}"
  --node-name "${NODENAME}"
)
if [[ -n "${CONTROL_PLANE_ENDPOINT}" ]]; then
  INIT_ARGS+=( --control-plane-endpoint="${CONTROL_PLANE_ENDPOINT}" )
elif [[ "${PUBLIC_IP_ACCESS}" == "true" && -n "${PUBLIC_IP}" ]]; then
  INIT_ARGS+=( --control-plane-endpoint="${PUBLIC_IP}" )
fi

kubeadm init "${INIT_ARGS[@]}" "${IGNORE_FLAGS[@]}"

# ---------- kubeconfig for current user ----------
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# ---------- Install Calico CNI ----------
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml

# ---------- (Lab) allow scheduling on control-plane ----------
if [[ "${TAINT_CONTROL_PLANE}" != "true" ]]; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
fi

# ---------- Save a worker join command ----------
kubeadm token create --ttl "${TOKEN_TTL}" --print-join-command | tee "$HOME/kubeadm-join.sh"
chmod +x "$HOME/kubeadm-join.sh"

echo "✅ Control plane initialized."
echo "   PRIVATE_IP: ${PRIVATE_IP}"
echo "   PUBLIC_IP:  ${PUBLIC_IP}"
echo "   Endpoint:   ${CONTROL_PLANE_ENDPOINT:-$([[ "${PUBLIC_IP_ACCESS}" == "true" && -n "${PUBLIC_IP}" ]] && echo "${PUBLIC_IP}" || echo "${PRIVATE_IP}")}:6443"
echo "➡  Worker join command saved to $HOME/kubeadm-join.sh"
