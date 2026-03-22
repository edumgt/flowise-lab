#!/usr/bin/env bash
# ============================================================
# 02-import-and-push.sh
# [폐쇄망 VM(Ubuntu)에서 실행]
#
# 역할: 외부에서 복사해온 tar 이미지 파일들을
#       1) k3s containerd로 import (k3s가 직접 사용)
#       2) 로컬 레지스트리(registry.local:5000)로 push
#          (kustomize overlay에서 이미지 참조 대체용)
#
# 사전 조건:
#   - 01-setup-local-registry.sh 실행 완료
#   - ./images/ 디렉토리에 tar 파일들 존재
#
# 실행 방법:
#   chmod +x 02-import-and-push.sh
#   ./02-import-and-push.sh
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[IMPORT]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}   $1"; }
err()  { echo -e "${RED}[ERR]${NC}    $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/images"
IMAGES_FILE="${SCRIPT_DIR}/images.txt"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
REGISTRY="registry.local:5000"

# ── 사전 확인 ────────────────────────────────────────────
[[ -d "${IMAGES_DIR}" ]] || err "images 디렉토리가 없습니다: ${IMAGES_DIR}"
command -v docker &>/dev/null || err "docker 명령어를 찾을 수 없습니다."

# ── Docker 로컬 레지스트리 tag alias ──────────────────────
# 로컬 레지스트리 NodePort로도 접근 가능하도록 alias
REGISTRY_ENDPOINT="${NODE_IP}:30500"

log "이미지 import 및 push 시작..."
log "로컬 레지스트리: ${REGISTRY_ENDPOINT}"

FAILED=()

# ── 이미지 목록을 읽어 tar 파일 이름과 매핑 ─────────────
mapfile -t IMAGES < <(grep -v '^\s*#' "${IMAGES_FILE}" | grep -v '^\s*$')

for IMAGE in "${IMAGES[@]}"; do
  # tar 파일명 역산 (00-pull-and-export.sh 규칙과 동일)
  FILENAME="${IMAGE//\//__}"
  FILENAME="${FILENAME//:/_}.tar"
  FILEPATH="${IMAGES_DIR}/${FILENAME}"

  if [[ ! -f "${FILEPATH}" ]]; then
    warn "tar 파일 없음, 건너뜀: ${FILEPATH}"
    FAILED+=("${IMAGE}")
    continue
  fi

  log "Docker load: ${FILEPATH}"
  docker load -i "${FILEPATH}"

  # 원본 이미지에 레지스트리 prefix 붙여 태그
  # quay.io/metallb/controller:v0.14.8  →  registry.local:5000/metallb/controller:v0.14.8
  # registry.k8s.io/ingress-nginx/...   →  registry.local:5000/ingress-nginx/...
  STRIPPED="${IMAGE##*/}"           # 마지막 경로 세그먼트 (이름:태그)
  # 네임스페이스 포함 경로 구성: 원본 이미지에서 레지스트리 부분 제거
  if [[ "${IMAGE}" == *"/"* ]]; then
    # 첫 번째 슬래시 앞이 레지스트리 주소인지 판단
    FIRST_SEGMENT="${IMAGE%%/*}"
    if [[ "${FIRST_SEGMENT}" == *"."* || "${FIRST_SEGMENT}" == *":"* ]]; then
      # 첫 세그먼트가 레지스트리 주소 (점 또는 콜론 포함)
      IMAGE_PATH="${IMAGE#*/}"   # 레지스트리 제거
    else
      IMAGE_PATH="${IMAGE}"
    fi
  else
    IMAGE_PATH="${IMAGE}"
  fi

  NEW_TAG="${REGISTRY_ENDPOINT}/${IMAGE_PATH}"
  log "  tag: ${IMAGE} → ${NEW_TAG}"
  docker tag "${IMAGE}" "${NEW_TAG}"

  log "  push: ${NEW_TAG}"
  docker push "${NEW_TAG}"

  # registry.local:5000 alias도 태그 (k8s YAML에서 참조하는 주소)
  NEW_TAG_ALIAS="${REGISTRY}/${IMAGE_PATH}"
  docker tag "${IMAGE}" "${NEW_TAG_ALIAS}" 2>/dev/null || true

  log "  ✓ 완료"
done

# ── k3s containerd에도 직접 import (레지스트리 없이 사용 가능) ──
log ""
log "k3s containerd import (air-gap 로컬 캐시)..."
for IMAGE in "${IMAGES[@]}"; do
  FILENAME="${IMAGE//\//__}"
  FILENAME="${FILENAME//:/_}.tar"
  FILEPATH="${IMAGES_DIR}/${FILENAME}"
  [[ -f "${FILEPATH}" ]] || continue
  log "  ctr import: $(basename "${FILEPATH}")"
  sudo k3s ctr images import "${FILEPATH}" || warn "  ctr import 실패: ${FILEPATH}"
done

# ── 결과 요약 ────────────────────────────────────────────
echo ""
echo "=============================================="
log "import/push 완료"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "처리 실패한 이미지 (tar 파일 없음):"
  for f in "${FAILED[@]}"; do
    warn "  - ${f}"
  done
fi
log "레지스트리 이미지 목록 확인:"
log "  curl http://${REGISTRY_ENDPOINT}/v2/_catalog"
echo ""
log "다음 단계: 03-install-k3s-airgap.sh 실행 (아직 k3s 미설치 시)"
log "또는: kubectl apply -k ../airgap/ (kustomize air-gap overlay 배포)"
echo "=============================================="
