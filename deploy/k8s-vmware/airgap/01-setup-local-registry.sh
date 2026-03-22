#!/usr/bin/env bash
# ============================================================
# 01-setup-local-registry.sh
# [폐쇄망 VM(Ubuntu)에서 실행]
#
# 역할: 폐쇄망 내부에서 사용할 Docker 레지스트리를 K8s Pod으로 배포합니다.
#       registry.local:5000 으로 접근 가능하도록 구성합니다.
#
# 사전 조건:
#   - k3s 설치 완료 (03-install-k3s-airgap.sh 실행 후)
#   - kubectl 사용 가능
#
# 실행 방법:
#   chmod +x 01-setup-local-registry.sh
#   ./01-setup-local-registry.sh
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[REG]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERR]${NC}   $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/images"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
REGISTRY_PORT="5000"
REGISTRY_HOST="registry.local"

# ── kubectl 확인 ─────────────────────────────────────────
command -v kubectl &>/dev/null || err "kubectl을 찾을 수 없습니다. k3s 설치 후 실행하세요."

log "로컬 레지스트리 배포: ${REGISTRY_HOST}:${REGISTRY_PORT} (Node IP: ${NODE_IP})"

# ── k8s-registry 네임스페이스 ────────────────────────────
kubectl create namespace kube-registry --dry-run=client -o yaml | kubectl apply -f -

# ── registry 이미지 먼저 로드 (k3s ctr 사용) ─────────────
REGISTRY_TAR=$(find "${IMAGES_DIR}" -name "registry__*" -o -name "*registry_2*" | head -1 || true)
if [[ -n "${REGISTRY_TAR}" ]]; then
  log "registry 이미지 로드: ${REGISTRY_TAR}"
  sudo k3s ctr images import "${REGISTRY_TAR}"
else
  warn "registry:2.8.3 tar 파일을 찾을 수 없습니다. images 디렉토리를 확인하세요."
fi

# ── 레지스트리 Deployment + Service + PVC ────────────────
log "레지스트리 Deployment 배포..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: kube-registry
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: kube-registry
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 30Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: kube-registry
  labels:
    app: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
        - name: registry
          image: registry:2.8.3
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5000
          env:
            - name: REGISTRY_STORAGE_DELETE_ENABLED
              value: "true"
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "300m"
              memory: "256Mi"
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: registry-data
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: kube-registry
spec:
  selector:
    app: registry
  type: NodePort
  ports:
    - port: 5000
      targetPort: 5000
      nodePort: 30500
EOF

log "레지스트리 Pod 준비 대기..."
kubectl rollout status deployment/registry -n kube-registry --timeout=120s

# ── /etc/hosts 에 registry.local 등록 ────────────────────
log "/etc/hosts에 registry.local 등록..."
if ! grep -q "registry.local" /etc/hosts; then
  echo "${NODE_IP}  registry.local" | sudo tee -a /etc/hosts
fi

# ── k3s containerd mirror 설정 ────────────────────────────
# k3s가 registry.local:5000을 신뢰하도록 insecure registry 설정
log "k3s containerd mirror 설정 (registry.local:5000)..."
sudo mkdir -p /etc/rancher/k3s
cat <<EOF | sudo tee /etc/rancher/k3s/registries.yaml
mirrors:
  "registry.local:5000":
    endpoint:
      - "http://${NODE_IP}:30500"

configs:
  "registry.local:5000":
    tls:
      insecure_skip_verify: true
EOF

# ── Docker daemon insecure registry 설정 (이미지 push용) ──
log "Docker insecure registry 설정 (push용)..."
sudo mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "insecure-registries": ["${NODE_IP}:30500", "registry.local:5000"]
}
EOF

# Docker 재시작
if systemctl is-active docker &>/dev/null; then
  sudo systemctl restart docker
  log "Docker 재시작 완료"
fi

# k3s 재시작 (registries.yaml 적용)
log "k3s 재시작 (mirror 설정 적용)..."
sudo systemctl restart k3s
sleep 10
kubectl get nodes

log "레지스트리 준비 완료!"
log "접근 주소: http://${NODE_IP}:30500  (또는 http://registry.local:5000)"
log "다음 단계: 02-import-and-push.sh 실행"
