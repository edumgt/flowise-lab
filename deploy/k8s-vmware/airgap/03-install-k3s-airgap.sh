#!/usr/bin/env bash
# ============================================================
# 03-install-k3s-airgap.sh
# [폐쇄망 VM(Ubuntu)에서 실행]
#
# 역할: 인터넷 없이 k3s를 설치합니다 (air-gap 모드).
#       MetalLB, NGINX Ingress도 로컬 YAML로 설치합니다.
#
# 사전 조건:
#   - ./images/k3s/ 디렉토리에 아래 파일이 존재해야 합니다:
#       k3s                              (바이너리)
#       k3s-airgap-images-amd64.tar.zst  (k3s 컨테이너 이미지 번들)
#   - ./images/install-yaml/ 에 아래 파일이 존재해야 합니다:
#       metallb-native.yaml
#       ingress-nginx-deploy.yaml
#
# 실행 방법:
#   chmod +x 03-install-k3s-airgap.sh
#   sudo ./03-install-k3s-airgap.sh
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[K3S]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERR]${NC}   $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3S_DIR="${SCRIPT_DIR}/images/k3s"
YAML_DIR="${SCRIPT_DIR}/images/install-yaml"
K3S_VERSION="v1.30.3+k3s1"
INSTALL_K3S_SKIP_DOWNLOAD=true

# root 여부 확인
[[ "${EUID}" -eq 0 ]] || err "root 권한으로 실행하세요: sudo $0"

# ── 파일 존재 확인 ───────────────────────────────────────
[[ -f "${K3S_DIR}/k3s" ]] || \
  err "k3s 바이너리 없음: ${K3S_DIR}/k3s\n00-pull-and-export.sh 를 인터넷 PC에서 먼저 실행하세요."
[[ -f "${K3S_DIR}/k3s-airgap-images-amd64.tar.zst" ]] || \
  err "k3s air-gap 이미지 없음: ${K3S_DIR}/k3s-airgap-images-amd64.tar.zst"

# ── k3s 바이너리 설치 ────────────────────────────────────
log "k3s 바이너리 설치..."
install -o root -g root -m 0755 "${K3S_DIR}/k3s" /usr/local/bin/k3s

# ── air-gap 이미지 번들 배치 ─────────────────────────────
log "k3s air-gap 이미지 번들 배치..."
mkdir -p /var/lib/rancher/k3s/agent/images
cp "${K3S_DIR}/k3s-airgap-images-amd64.tar.zst" \
   /var/lib/rancher/k3s/agent/images/

# ── k3s install script (오프라인 모드) ───────────────────
log "k3s 설치 스크립트 실행 (air-gap 모드)..."
# INSTALL_K3S_SKIP_DOWNLOAD=true: 바이너리 다운로드 생략
# --disable servicelb: MetalLB 사용을 위해 내장 servicelb 비활성화
# --disable traefik:   NGINX Ingress 사용을 위해 내장 Traefik 비활성화
export INSTALL_K3S_SKIP_DOWNLOAD=true
export INSTALL_K3S_VERSION="${K3S_VERSION}"

# k3s install 스크립트가 없으면 직접 서비스 등록
if [[ ! -f /tmp/k3s-install.sh ]]; then
  log "install.sh 없음 – 수동으로 systemd 서비스 등록..."
  cat > /etc/systemd/system/k3s.service <<'UNIT'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service'
ExecStart=/usr/local/bin/k3s server \
    --disable servicelb \
    --disable traefik \
    --write-kubeconfig-mode 644
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl enable k3s
  systemctl start k3s
else
  bash /tmp/k3s-install.sh \
    --disable servicelb \
    --disable traefik
fi

# ── k3s 시작 대기 ────────────────────────────────────────
log "k3s API 서버 준비 대기 (최대 120초)..."
for i in $(seq 1 24); do
  if /usr/local/bin/k3s kubectl get nodes &>/dev/null 2>&1; then
    log "k3s 준비 완료!"
    break
  fi
  echo -n "."
  sleep 5
done
echo ""
/usr/local/bin/k3s kubectl get nodes || err "k3s 시작 실패"

# ── kubeconfig 설정 ──────────────────────────────────────
mkdir -p "${HOME}/.kube"
cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
export KUBECONFIG="${HOME}/.kube/config"
log "kubeconfig: ${HOME}/.kube/config"

# ── MetalLB 설치 (로컬 YAML) ─────────────────────────────
[[ -f "${YAML_DIR}/metallb-native.yaml" ]] || \
  err "MetalLB YAML 없음: ${YAML_DIR}/metallb-native.yaml"

log "MetalLB 설치..."
kubectl apply -f "${YAML_DIR}/metallb-native.yaml"
log "MetalLB webhook 준비 대기..."
kubectl rollout status deployment/controller -n metallb-system --timeout=180s

# ── NGINX Ingress 설치 (로컬 YAML) ───────────────────────
[[ -f "${YAML_DIR}/ingress-nginx-deploy.yaml" ]] || \
  err "NGINX Ingress YAML 없음: ${YAML_DIR}/ingress-nginx-deploy.yaml"

log "NGINX Ingress Controller 설치..."
kubectl apply -f "${YAML_DIR}/ingress-nginx-deploy.yaml"
log "NGINX Ingress 준비 대기..."
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

log ""
log "=========================================="
log "k3s air-gap 설치 완료!"
log "  kubectl get nodes"
kubectl get nodes
log ""
log "다음 단계:"
log "  1. 01-setup-local-registry.sh  : 로컬 레지스트리 배포"
log "  2. 02-import-and-push.sh       : 이미지 import & push"
log "  3. kubectl apply -k airgap/    : 앱 배포 (kustomize)"
log "=========================================="
