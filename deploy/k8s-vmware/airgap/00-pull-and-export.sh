#!/usr/bin/env bash
# ============================================================
# 00-pull-and-export.sh
# [인터넷 연결 PC에서 실행]
#
# 역할: 모든 Docker 이미지를 pull 하고 tar 파일로 내보냅니다.
#       생성된 tar 파일들을 USB/HDD/파일서버를 통해
#       폐쇄망 환경으로 이동하세요.
#
# 사전 조건:
#   - Docker Desktop 또는 Docker Engine 설치
#   - 인터넷 연결
#
# 실행 방법 (WSL 또는 Linux):
#   chmod +x 00-pull-and-export.sh
#   ./00-pull-and-export.sh
#
# 출력 디렉토리: ./images/
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_FILE="${SCRIPT_DIR}/images.txt"
OUTPUT_DIR="${SCRIPT_DIR}/images"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[PULL]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERR]${NC}   $1"; }

# ── 출력 디렉토리 생성 ────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"

# ── Docker 실행 여부 확인 ─────────────────────────────────
if ! docker info &>/dev/null; then
  err "Docker가 실행 중이지 않습니다. Docker Desktop 또는 Docker Engine을 시작하세요."
  exit 1
fi

# ── 이미지 목록 읽기 (주석 및 빈 줄 제외) ────────────────
mapfile -t IMAGES < <(grep -v '^\s*#' "${IMAGES_FILE}" | grep -v '^\s*$')

TOTAL=${#IMAGES[@]}
DONE=0
FAILED=()

for IMAGE in "${IMAGES[@]}"; do
  DONE=$((DONE + 1))
  log "[${DONE}/${TOTAL}] Pull: ${IMAGE}"

  if ! docker pull "${IMAGE}"; then
    warn "Pull 실패: ${IMAGE} – 건너뜁니다."
    FAILED+=("${IMAGE}")
    continue
  fi

  # 파일명: 슬래시, 콜론 → 언더스코어 치환
  FILENAME="${IMAGE//\//__}"
  FILENAME="${FILENAME//:/_}.tar"
  FILEPATH="${OUTPUT_DIR}/${FILENAME}"

  log "  → 저장: ${FILEPATH}"
  docker save "${IMAGE}" -o "${FILEPATH}"
  log "  ✓ 완료 ($(du -sh "${FILEPATH}" | cut -f1))"
  echo ""
done

# ── k3s 바이너리 및 air-gap 이미지 번들 다운로드 ─────────
K3S_VERSION="v1.30.3+k3s1"
K3S_DIR="${OUTPUT_DIR}/k3s"
mkdir -p "${K3S_DIR}"

log "k3s 바이너리 다운로드: ${K3S_VERSION}"
K3S_BIN_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s"
K3S_IMAGES_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"

curl -L --progress-bar -o "${K3S_DIR}/k3s" "${K3S_BIN_URL}"
chmod +x "${K3S_DIR}/k3s"

log "k3s air-gap 이미지 번들 다운로드 (대용량, 시간 소요)..."
curl -L --progress-bar -o "${K3S_DIR}/k3s-airgap-images-amd64.tar.zst" "${K3S_IMAGES_URL}"

# MetalLB, Ingress 설치 YAML 다운로드
METALLB_VERSION="v0.14.8"
INGRESS_VERSION="v1.11.2"
YAML_DIR="${OUTPUT_DIR}/install-yaml"
mkdir -p "${YAML_DIR}"

log "MetalLB 설치 YAML 다운로드 (${METALLB_VERSION})..."
curl -L --progress-bar -o "${YAML_DIR}/metallb-native.yaml" \
  "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

log "NGINX Ingress 설치 YAML 다운로드 (${INGRESS_VERSION})..."
curl -L --progress-bar -o "${YAML_DIR}/ingress-nginx-deploy.yaml" \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_VERSION}/deploy/static/provider/baremetal/deploy.yaml"

# ── 결과 요약 ────────────────────────────────────────────
echo ""
echo "=============================================="
log "완료! 이미지 파일 저장 위치: ${OUTPUT_DIR}"
echo "  총 이미지:  ${TOTAL}"
echo "  성공:      $((TOTAL - ${#FAILED[@]}))"
echo "  실패:      ${#FAILED[@]}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "실패한 이미지:"
  for f in "${FAILED[@]}"; do
    warn "  - ${f}"
  done
fi

echo ""
log "다음 단계: ${OUTPUT_DIR} 디렉토리 전체를 폐쇄망 환경으로 복사 후"
log "  01-setup-local-registry.sh  →  02-import-and-push.sh  →  03-install-k3s-airgap.sh  순서로 실행"
echo "=============================================="
