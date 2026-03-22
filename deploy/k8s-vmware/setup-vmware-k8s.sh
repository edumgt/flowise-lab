#!/usr/bin/env bash
# ==============================================================================
# setup-vmware-k8s.sh
# ==============================================================================
# WSL2 환경에서 실행하여 VMware VM 위에 K3s + AI-Flowise-RAG 스택을 배포합니다.
#
# 지원 모드:
#   온라인 모드 (기본): 인터넷에서 이미지와 바이너리를 다운로드합니다.
#   폐쇄망 모드 (--airgap): 사전 준비된 이미지 파일을 사용합니다.
#                           airgap/00-pull-and-export.sh 를 먼저 실행하세요.
#
# 사용법:
#   ./setup-vmware-k8s.sh                          # 온라인 모드
#   ./setup-vmware-k8s.sh --airgap                 # 폐쇄망 모드
#   ./setup-vmware-k8s.sh --help                   # 도움말
#   ./setup-vmware-k8s.sh --metallb-range X.X.X.X-X.X.X.X
#
# 사전 조건:
#   - Windows 10/11 + WSL2 (Ubuntu 20.04/22.04)
#   - VMware Workstation Pro/Player 설치
#   - Ubuntu 22.04 Server ISO (자동 다운로드 또는 --iso-path 지정)
#   - 호스트 사양: CPU 4코어+, RAM 16GB+, Disk 100GB+
# ==============================================================================
set -euo pipefail

# ── 색상 / 로깅 ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()    { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }
header() { echo -e "\n${BLUE}${BOLD}══ $* ══${NC}"; }
step()   { echo -e "${CYAN}  ▶ $*${NC}"; }

# ── 인자 파싱 ─────────────────────────────────────────────────────────────────
AIRGAP_MODE=false
SKIP_VM_CREATE=false
SKIP_K3S=false
ISO_PATH=""
METALLB_IP_RANGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --airgap)          AIRGAP_MODE=true ;;
    --skip-vm)         SKIP_VM_CREATE=true ;;
    --skip-k3s)        SKIP_K3S=true ;;
    --iso-path)        ISO_PATH="$2"; shift ;;
    --metallb-range)   METALLB_IP_RANGE="$2"; shift ;;
    --help|-h)
      echo "사용법: $0 [옵션]"
      echo "  --airgap             폐쇄망 모드 (이미지 인터넷 다운로드 없음)"
      echo "  --skip-vm            VM 생성 건너뜀 (이미 존재하는 경우)"
      echo "  --skip-k3s           k3s 설치 건너뜀"
      echo "  --iso-path PATH      Ubuntu ISO 경로 지정 (WSL 경로)"
      echo "  --metallb-range CIDR MetalLB IP 범위 (예: 192.168.100.200-192.168.100.220)"
      exit 0
      ;;
    *) warn "알 수 없는 옵션: $1" ;;
  esac
  shift
done

# ── 경로 설정 ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
AIRGAP_DIR="${SCRIPT_DIR}/airgap"
VM_INIT_DIR="${SCRIPT_DIR}/vm-init"

# ── VMware 설정 ───────────────────────────────────────────────────────────────
# VMware Workstation 기본 설치 경로 (WSL 경로 형식)
# 32bit 경로 우선, 없으면 64bit 경로 시도
VMWARE_WIN_PATH_32="/mnt/c/Program Files (x86)/VMware/VMware Workstation"
VMWARE_WIN_PATH_64="/mnt/c/Program Files/VMware/VMware Workstation"

if [[ -f "${VMWARE_WIN_PATH_32}/vmrun.exe" ]]; then
  VMRUN="${VMWARE_WIN_PATH_32}/vmrun.exe"
  VMWARE_PATH="${VMWARE_WIN_PATH_32}"
elif [[ -f "${VMWARE_WIN_PATH_64}/vmrun.exe" ]]; then
  VMRUN="${VMWARE_WIN_PATH_64}/vmrun.exe"
  VMWARE_PATH="${VMWARE_WIN_PATH_64}"
else
  VMRUN=""
  VMWARE_PATH=""
fi

# ── VM 설정 ───────────────────────────────────────────────────────────────────
VM_NAME="bankrag-k8s"
VM_CPU=4                    # 최소 4 vCPU (k3s + 서비스)
VM_MEMORY=8192              # 8 GB RAM
VM_DISK_GB=60               # 60 GB 디스크
VM_USER="ubuntu"
VM_PASS="ubuntu1234"
VM_SSH_KEY="${HOME}/.ssh/bankrag_vm_ed25519"

# Windows 경로로 VM 디렉토리 (WSL에서 vmrun 에 전달)
WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r' || echo "User")
VM_DIR_WIN="C:\\Users\\${WIN_USER}\\Virtual Machines\\${VM_NAME}"
VM_DIR_WSL="/mnt/c/Users/${WIN_USER}/Virtual Machines/${VM_NAME}"
VMX_FILE="${VM_DIR_WIN}\\${VM_NAME}.vmx"

# Ubuntu ISO
UBUNTU_ISO_URL="https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
UBUNTU_ISO_NAME="ubuntu-22.04.5-live-server-amd64.iso"
ISO_DOWNLOAD_DIR="/tmp/bankrag-iso"

# ── 네트워크 설정 ─────────────────────────────────────────────────────────────
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │                  VMware Workstation 네트워크 구성 설명                  │
# ├─────────────────────────────────────────────────────────────────────────┤
# │                                                                         │
# │  [권장] NAT 모드 (VMnet8)                                               │
# │  ─────────────────────────────────────────────────────────────────────  │
# │  • VMware가 내부 가상 스위치 VMnet8 생성                               │
# │  • VM IP: VMware DHCP가 자동 할당 (기본: 192.168.x.128~.254)           │
# │  • Windows 호스트 VMnet8 어댑터 IP: 192.168.x.1 (게이트웨이 역할)      │
# │  • VMware NAT 서비스(vmnat.exe)가 인터넷 공유                          │
# │  • 외부 LAN에서 VM 접근: netsh 포트포워딩 필요                          │
# │                                                                         │
# │  VMware NAT 서브넷 확인 방법:                                           │
# │    VMware Workstation → Edit → Virtual Network Editor                   │
# │    → VMnet8 선택 → Subnet IP / Subnet mask 확인                        │
# │                                                                         │
# │  [MetalLB IP 풀 설정]                                                   │
# │  MetalLB는 K8s LoadBalancer 서비스에 외부 IP를 할당합니다.              │
# │  VMware DHCP 범위와 겹치지 않는 고정 IP 구간을 사용해야 합니다.         │
# │                                                                         │
# │  예: VMware NAT DHCP = 192.168.100.128~192.168.100.254                  │
# │      → DHCP 시작 주소를 .200으로 줄이고                                 │
# │        MetalLB 풀 = 192.168.100.200~192.168.100.220 사용                │
# │                                                                         │
# │  VMware Virtual Network Editor에서 DHCP 범위 수정:                      │
# │    VMnet8 → DHCP Settings → Starting IP: 192.168.100.221               │
# │                                                                         │
# │  WSL2 → VMware NAT 네트워크 라우팅 설명:                                │
# │  ─────────────────────────────────────────────────────────────────────  │
# │  WSL2는 172.x.x.x 별도 가상 네트워크 사용 → VMware NAT(192.168.x.x)와 │
# │  직접 통신 불가. Windows 호스트가 양쪽 네트워크에 연결되어 있으므로,    │
# │  WSL2에서 VMware NAT 서브넷으로의 라우팅을 추가합니다:                  │
# │                                                                         │
# │    # Windows 호스트 IP (WSL2 관점)                                      │
# │    WIN_IP=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}')  │
# │    sudo ip route add 192.168.100.0/24 via $WIN_IP                       │
# │                                                                         │
# │  [Bridged 모드]                                                          │
# │  • VM이 물리 LAN에 직접 연결 (공유기 DHCP에서 IP 할당)                 │
# │  • 같은 LAN의 모든 기기에서 VM IP 직접 접근 가능                        │
# │  • MetalLB IP 풀 = LAN 서브넷에서 사용하지 않는 고정 IP 구간 사용       │
# │                                                                         │
# └─────────────────────────────────────────────────────────────────────────┘
#
VMWARE_NAT_CIDR="${VMWARE_NAT_CIDR:-192.168.100.0/24}"
VMWARE_NAT_GATEWAY="${VMWARE_NAT_GATEWAY:-192.168.100.1}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-192.168.100.200-192.168.100.220}"

# K3s 버전
K3S_VERSION="v1.30.3+k3s1"
METALLB_VERSION="v0.14.8"
INGRESS_NGINX_VERSION="v1.11.2"

# 내부 DNS 도메인
DOMAIN_SUFFIX="bankrag.local"
SERVICES=("api-gateway" "flowise" "qdrant" "jaeger" "prometheus" "grafana" "minio")

# ==============================================================================
# 함수 정의
# ==============================================================================

# ── WSL2 환경 확인 ────────────────────────────────────────────────────────────
check_wsl() {
  header "WSL2 환경 확인"

  if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
    err "WSL 환경이 아닙니다. WSL2에서 실행하세요."
  fi

  if ! grep -qi "WSL2\|microsoft-standard" /proc/version 2>/dev/null; then
    warn "WSL1로 감지됩니다. WSL2 권장: wsl --set-version Ubuntu 2"
  fi

  # WSL2 Windows 호스트 IP 감지
  WIN_HOST_IP=$(cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
  log "Windows 호스트 IP (WSL2 관점): ${WIN_HOST_IP}"
  log "WSL2 확인 완료"
}

# ── VMware 설치 확인 ──────────────────────────────────────────────────────────
check_vmware() {
  header "VMware Workstation 확인"

  if [[ -z "${VMRUN}" || ! -f "${VMRUN}" ]]; then
    warn "vmrun.exe를 찾을 수 없습니다."
    warn "VMware Workstation을 설치하거나 경로를 확인하세요:"
    warn "  기본 경로: C:\\Program Files (x86)\\VMware\\VMware Workstation"
    echo ""
    echo -e "${CYAN}[VMware Workstation 설치 안내]${NC}"
    echo "  1. https://www.vmware.com/products/workstation-player.html 에서 다운로드"
    echo "  2. Windows에서 설치 실행 (관리자 권한)"
    echo "  3. 설치 완료 후 이 스크립트를 다시 실행하세요"
    echo ""
    read -rp "VMware 설치 후 계속하시겠습니까? [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || exit 0
    check_vmware  # 재귀 재확인
    return
  fi

  log "vmrun 발견: ${VMRUN}"

  # vmrun 실행 테스트
  if ! "${VMRUN}" list &>/dev/null 2>&1; then
    warn "vmrun 실행 실패 – VMware 서비스가 실행 중인지 확인하세요."
  else
    log "VMware 정상 동작 확인"
  fi
}

# ── Ubuntu ISO 준비 ───────────────────────────────────────────────────────────
prepare_iso() {
  header "Ubuntu 22.04 Server ISO 준비"

  if [[ -n "${ISO_PATH}" ]]; then
    [[ -f "${ISO_PATH}" ]] || err "ISO 파일 없음: ${ISO_PATH}"
    UBUNTU_ISO="${ISO_PATH}"
    log "ISO 경로 지정: ${UBUNTU_ISO}"
    return
  fi

  mkdir -p "${ISO_DOWNLOAD_DIR}"
  UBUNTU_ISO="${ISO_DOWNLOAD_DIR}/${UBUNTU_ISO_NAME}"

  if [[ -f "${UBUNTU_ISO}" ]]; then
    log "ISO 이미 존재: ${UBUNTU_ISO}"
    return
  fi

  if ${AIRGAP_MODE}; then
    err "폐쇄망 모드에서는 --iso-path 로 Ubuntu ISO 경로를 지정해야 합니다."
  fi

  log "Ubuntu 22.04 Server ISO 다운로드 중..."
  log "URL: ${UBUNTU_ISO_URL}"
  curl -L --progress-bar -o "${UBUNTU_ISO}" "${UBUNTU_ISO_URL}"
  log "ISO 다운로드 완료: ${UBUNTU_ISO}"
}

# ── Seed ISO 생성 (Ubuntu autoinstall용) ─────────────────────────────────────
create_seed_iso() {
  header "Autoinstall Seed ISO 생성"

  SEED_ISO="/tmp/bankrag-seed.iso"

  # genisoimage 또는 mkisofs 확인
  if command -v genisoimage &>/dev/null; then
    ISO_CMD="genisoimage"
  elif command -v mkisofs &>/dev/null; then
    ISO_CMD="mkisofs"
  else
    log "genisoimage 설치 중..."
    sudo apt-get install -y genisoimage -q
    ISO_CMD="genisoimage"
  fi

  # cloud-init user-data 에서 비밀번호 해시 생성
  if command -v openssl &>/dev/null; then
    PASS_HASH=$(openssl passwd -6 "${VM_PASS}")
    # user-data 의 플레이스홀더 해시를 실제 해시로 교체
    sed "s|\\\$6\\\$rounds=4096\\\$bankragsalt.*|${PASS_HASH}|" \
      "${VM_INIT_DIR}/user-data" > /tmp/bankrag-user-data
  else
    cp "${VM_INIT_DIR}/user-data" /tmp/bankrag-user-data
  fi

  # SSH 공개키가 있으면 user-data에 추가
  if [[ -f "${VM_SSH_KEY}.pub" ]]; then
    PUB_KEY=$(cat "${VM_SSH_KEY}.pub")
    sed -i "s|authorized-keys: \[\]|authorized-keys:\n      - \"${PUB_KEY}\"|" \
      /tmp/bankrag-user-data
  fi

  log "Seed ISO 생성 중: ${SEED_ISO}"
  ${ISO_CMD} \
    -output "${SEED_ISO}" \
    -volid cidata \
    -joliet -rock \
    /tmp/bankrag-user-data \
    "${VM_INIT_DIR}/meta-data"

  log "Seed ISO 생성 완료: ${SEED_ISO}"
}

# ── SSH 키 생성 ───────────────────────────────────────────────────────────────
setup_ssh_key() {
  if [[ ! -f "${VM_SSH_KEY}" ]]; then
    step "VM 접속용 SSH 키 생성: ${VM_SSH_KEY}"
    ssh-keygen -t ed25519 -f "${VM_SSH_KEY}" -N "" -C "bankrag-vm-key"
  fi
  log "SSH 키: ${VM_SSH_KEY}"
}

# ── VMware VM 생성 ────────────────────────────────────────────────────────────
create_vm() {
  header "VMware VM 생성"

  if ${SKIP_VM_CREATE}; then
    log "--skip-vm 옵션으로 VM 생성 건너뜀"
    return
  fi

  # VMX 파일이 이미 존재하면 건너뜀
  if [[ -f "${VM_DIR_WSL}/${VM_NAME}.vmx" ]]; then
    log "VM 이미 존재: ${VM_DIR_WSL}/${VM_NAME}.vmx"
    return
  fi

  step "VM 디렉토리 생성: ${VM_DIR_WSL}"
  mkdir -p "${VM_DIR_WSL}"

  # Windows 경로 형식 변환 (WSL → Windows)
  UBUNTU_ISO_WIN=$(wslpath -w "${UBUNTU_ISO}")
  SEED_ISO_WIN=$(wslpath -w "/tmp/bankrag-seed.iso")

  step "VMX 구성 파일 생성..."
  cat > "${VM_DIR_WSL}/${VM_NAME}.vmx" <<VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "${VM_NAME}"

# ── CPU/메모리 설정 ──
numvcpus = "${VM_CPU}"
cpuid.coresPerSocket = "2"
memsize = "${VM_MEMORY}"

# ── 네트워크 설정 (NAT 모드 = VMnet8) ──
# 변경하려면 ethernet0.connectionType = "bridged" 또는 "hostonly"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "vmxnet3"
ethernet0.wakeOnPcktRcv = "FALSE"
ethernet0.addressType = "generated"

# ── 디스크 설정 ──
scsi0.present = "TRUE"
scsi0.virtualDev = "lsisas1068"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "${VM_NAME}.vmdk"
scsi0:0.redo = ""

# ── CD-ROM 1: Ubuntu 설치 ISO ──
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "${UBUNTU_ISO_WIN}"
sata0:0.startConnected = "TRUE"

# ── CD-ROM 2: Autoinstall Seed ISO (CIDATA) ──
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "${SEED_ISO_WIN}"
sata0:1.startConnected = "TRUE"

# ── BIOS/UEFI 설정 ──
firmware = "efi"
bios.bootDelay = "0"
bios.bootOrder = "CDROM,DISK"

# ── 기타 설정 ──
floppy0.present = "FALSE"
usb.present = "TRUE"
sound.present = "FALSE"
vmci0.present = "TRUE"
hpet0.present = "TRUE"
VMX

  # 디스크 생성
  step "VM 디스크 생성 (${VM_DISK_GB} GB)..."
  VMWARE_VDISKMANAGER="${VMWARE_PATH}/vmware-vdiskmanager.exe"
  if [[ -f "${VMWARE_VDISKMANAGER}" ]]; then
    "${VMWARE_VDISKMANAGER}" -c \
      -s "${VM_DISK_GB}GB" \
      -a lsilogic \
      -t 0 \
      "$(wslpath -w "${VM_DIR_WSL}/${VM_NAME}.vmdk")"
  else
    warn "vmware-vdiskmanager.exe 를 찾을 수 없습니다."
    warn "VMware Workstation GUI에서 수동으로 VM을 생성하세요."
    warn "  1. VMware → File → New Virtual Machine"
    warn "  2. Custom → Ubuntu 64bit → ${VM_CPU}vCPU / ${VM_MEMORY}MB / ${VM_DISK_GB}GB"
    warn "  3. 생성 후 Ubuntu ISO + Seed ISO를 CD-ROM으로 마운트"
    read -rp "VM 수동 생성 완료 후 Enter 키를 누르세요..." _
    return
  fi

  log "VM 생성 완료: ${VM_DIR_WSL}/${VM_NAME}.vmx"
}

# ── VM 시작 및 Ubuntu 설치 대기 ──────────────────────────────────────────────
start_and_wait_vm() {
  header "VM 시작 및 Ubuntu 자동 설치 대기"

  local VMX_WIN="${VMX_FILE}"

  step "VM 시작..."
  "${VMRUN}" -T ws start "${VMX_WIN}" nogui || \
    "${VMRUN}" -T ws start "${VMX_WIN}"

  log "Ubuntu 자동 설치가 진행 중입니다."
  log "완료까지 약 10~20분 소요됩니다."
  log "VMware Workstation에서 설치 진행 상황을 확인할 수 있습니다."
  echo ""

  # VM IP 감지를 위해 최대 30분 대기
  local TIMEOUT=1800
  local ELAPSED=0
  VM_IP=""

  while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    VM_IP=$("${VMRUN}" -T ws getGuestIPAddress "${VMX_WIN}" 2>/dev/null || true)
    if [[ -n "${VM_IP}" && "${VM_IP}" != "0.0.0.0" ]]; then
      log "VM IP 감지: ${VM_IP}"
      break
    fi
    echo -n "."
    sleep 30
    ELAPSED=$((ELAPSED + 30))
  done

  if [[ -z "${VM_IP}" ]]; then
    warn "VM IP 자동 감지 실패. VM IP를 수동으로 입력하세요:"
    read -rp "VM IP 주소: " VM_IP
  fi

  log "VM IP: ${VM_IP}"

  # WSL2 → VMware NAT 라우팅 추가
  setup_wsl_routing
}

# ── WSL2 라우팅 설정 ──────────────────────────────────────────────────────────
setup_wsl_routing() {
  header "WSL2 → VMware NAT 라우팅 설정"
  #
  # [설명]
  # WSL2는 172.x.x.x 대역의 가상 네트워크를 사용합니다.
  # VMware NAT(VMnet8)는 192.168.x.x 대역을 사용합니다.
  # Windows 호스트는 두 네트워크에 모두 연결되어 있으므로
  # WSL2에서 Windows 호스트를 경유하는 라우팅을 추가합니다.
  #

  WIN_HOST_IP=$(cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
  VMWARE_NAT_NET=$(echo "${VMWARE_NAT_CIDR}" | cut -d'/' -f1)

  step "WSL2 라우팅 추가: ${VMWARE_NAT_CIDR} via ${WIN_HOST_IP}"
  if ! ip route show | grep -q "${VMWARE_NAT_CIDR}"; then
    sudo ip route add "${VMWARE_NAT_CIDR}" via "${WIN_HOST_IP}" dev eth0 2>/dev/null || \
      warn "라우팅 추가 실패 – 수동으로 실행: sudo ip route add ${VMWARE_NAT_CIDR} via ${WIN_HOST_IP}"
  else
    log "라우팅 이미 존재"
  fi

  # SSH 연결 테스트
  step "VM SSH 연결 테스트 (최대 120초 대기)..."
  for i in $(seq 1 24); do
    if ssh -o StrictHostKeyChecking=no \
           -o ConnectTimeout=5 \
           -o PasswordAuthentication=no \
           -i "${VM_SSH_KEY}" \
           "${VM_USER}@${VM_IP}" "echo ok" &>/dev/null 2>&1; then
      log "SSH 연결 성공!"
      return
    fi
    sleep 5
    echo -n "."
  done
  echo ""

  # 비밀번호 인증으로 재시도
  warn "키 기반 SSH 연결 실패. 비밀번호 인증으로 시도합니다."
  warn "비밀번호: ${VM_PASS}"
}

# ── SSH 원격 명령 실행 헬퍼 ─────────────────────────────────────────────────
vm_ssh() {
  ssh -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -i "${VM_SSH_KEY}" \
      "${VM_USER}@${VM_IP}" "$@"
}

vm_scp() {
  scp -o StrictHostKeyChecking=no \
      -i "${VM_SSH_KEY}" \
      "$@"
}

# ── k3s 설치 ─────────────────────────────────────────────────────────────────
install_k3s() {
  header "k3s (경량 Kubernetes) 설치"

  if ${SKIP_K3S}; then
    log "--skip-k3s 옵션으로 k3s 설치 건너뜀"
    return
  fi

  step "VM 커널 파라미터 적용..."
  vm_ssh "sudo sysctl --system" || true

  if ${AIRGAP_MODE}; then
    log "폐쇄망 모드: 03-install-k3s-airgap.sh 사용"
    vm_scp -r "${AIRGAP_DIR}" "${VM_USER}@${VM_IP}:/home/${VM_USER}/airgap"
    vm_ssh "chmod +x /home/${VM_USER}/airgap/*.sh && \
            sudo /home/${VM_USER}/airgap/03-install-k3s-airgap.sh"
  else
    step "k3s ${K3S_VERSION} 설치 (온라인)..."
    vm_ssh "curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION='${K3S_VERSION}' \
      sh -s - \
        --disable servicelb \
        --disable traefik \
        --write-kubeconfig-mode 644"
  fi

  step "k3s 준비 대기..."
  vm_ssh "
    for i in \$(seq 1 30); do
      kubectl get nodes &>/dev/null && break
      sleep 5; echo -n '.'
    done; echo ''
    kubectl get nodes
  "
  log "k3s 설치 완료"
}

# ── MetalLB 설치 ─────────────────────────────────────────────────────────────
install_metallb() {
  header "MetalLB 설치 (Layer2 모드)"
  #
  # [MetalLB 역할]
  # K8s에서 type: LoadBalancer 서비스 생성 시 외부 IP를 할당합니다.
  # VMware NAT 가상 스위치(L2 세그먼트) 내에서 ARP를 통해 IP를 공개합니다.
  # NGINX Ingress Controller 의 Service(LoadBalancer)에 MetalLB IP가 할당되고,
  # 해당 IP를 /etc/hosts 에 등록하면 모든 서비스 도메인으로 접근 가능합니다.
  #

  local METALLB_MANIFEST="https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

  if ${AIRGAP_MODE}; then
    METALLB_MANIFEST="/home/${VM_USER}/airgap/images/install-yaml/metallb-native.yaml"
    step "MetalLB 설치 (로컬 YAML)..."
    vm_ssh "kubectl apply -f '${METALLB_MANIFEST}'"
  else
    step "MetalLB 설치 (온라인)..."
    vm_ssh "kubectl apply -f '${METALLB_MANIFEST}'"
  fi

  step "MetalLB webhook 준비 대기 (최대 3분)..."
  vm_ssh "kubectl rollout status deployment/controller -n metallb-system --timeout=180s"

  # MetalLB IP 풀 설정 (YAML에 작성된 IP 범위를 실제 값으로 교체)
  step "MetalLB IP 풀 설정: ${METALLB_IP_RANGE}"
  # 01-metallb-config.yaml 의 IP 범위를 런타임 값으로 치환
  sed "s|192.168.100.200-192.168.100.220|${METALLB_IP_RANGE}|g" \
    "${K8S_DIR}/01-metallb-config.yaml" > /tmp/metallb-config-patched.yaml

  vm_scp /tmp/metallb-config-patched.yaml "${VM_USER}@${VM_IP}:/tmp/01-metallb-config.yaml"
  vm_ssh "kubectl apply -f /tmp/01-metallb-config.yaml"

  log "MetalLB 설치 완료"
}

# ── NGINX Ingress Controller 설치 ────────────────────────────────────────────
install_ingress() {
  header "NGINX Ingress Controller 설치"

  local INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"

  if ${AIRGAP_MODE}; then
    INGRESS_MANIFEST="/home/${VM_USER}/airgap/images/install-yaml/ingress-nginx-deploy.yaml"
    step "NGINX Ingress 설치 (로컬 YAML)..."
    vm_ssh "kubectl apply -f '${INGRESS_MANIFEST}'"
  else
    step "NGINX Ingress 설치 (온라인)..."
    vm_ssh "kubectl apply -f '${INGRESS_MANIFEST}'"
  fi

  step "NGINX Ingress 준비 대기 (최대 3분)..."
  vm_ssh "kubectl rollout status deployment/ingress-nginx-controller \
           -n ingress-nginx --timeout=180s"

  # Ingress Service를 NodePort에서 LoadBalancer로 변경 (MetalLB가 IP 할당)
  step "Ingress Service를 LoadBalancer 타입으로 변경..."
  vm_ssh "kubectl patch svc ingress-nginx-controller \
    -n ingress-nginx \
    -p '{\"spec\":{\"type\":\"LoadBalancer\"}}'"

  log "NGINX Ingress 설치 완료"
}

# ── 커스텀 앱 이미지 빌드 및 push ────────────────────────────────────────────
build_and_push_apps() {
  header "커스텀 앱 이미지 빌드"
  #
  # api-gateway, indexing-worker, langchain-js, llamaindex-py 는
  # 소스 빌드가 필요합니다. VM의 로컬 레지스트리에 push합니다.
  #

  REGISTRY_URL="${VM_IP}:30500"
  step "로컬 레지스트리 insecure 설정 (WSL Docker)..."
  sudo mkdir -p /etc/docker
  if ! grep -q "${REGISTRY_URL}" /etc/docker/daemon.json 2>/dev/null; then
    echo "{\"insecure-registries\":[\"${REGISTRY_URL}\"]}" | \
      sudo tee /etc/docker/daemon.json > /dev/null
    sudo systemctl restart docker 2>/dev/null || true
  fi

  local BUILD_SERVICES=("api-gateway" "indexing-worker" "langchain-js" "llamaindex-py")
  for SVC in "${BUILD_SERVICES[@]}"; do
    local SRC="${REPO_ROOT}/apps/${SVC}"
    if [[ -d "${SRC}" ]]; then
      step "빌드: ${SVC}"
      docker build -t "${REGISTRY_URL}/${SVC}:latest" "${SRC}"
      docker push "${REGISTRY_URL}/${SVC}:latest"
      log "  ✓ ${SVC} 빌드/push 완료"
    else
      warn "소스 디렉토리 없음: ${SRC} (건너뜀)"
    fi
  done
}

# ── K8s 매니페스트 배포 ───────────────────────────────────────────────────────
deploy_apps() {
  header "K8s 매니페스트 배포"

  # JWT_SECRET 자동 생성 (YAML 에 빈 값으로 정의되어 있으므로 반드시 주입)
  step "JWT_SECRET 생성 및 api-gateway-secret 패치..."
  local JWT_SECRET
  JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
  vm_ssh "kubectl create secret generic api-gateway-secret \
    --from-literal=JWT_SECRET='${JWT_SECRET}' \
    --from-literal=S3_ACCESS_KEY='minio' \
    --from-literal=S3_SECRET_KEY='minio1234' \
    -n bankrag \
    --dry-run=client -o yaml | kubectl apply -f -"
  log "JWT_SECRET 적용 완료"

  # config 파일들을 ConfigMap으로 생성
  step "bankrag-config ConfigMap 생성..."
  vm_scp "${REPO_ROOT}/config/tenants.yaml" "${VM_USER}@${VM_IP}:/tmp/tenants.yaml"
  vm_scp "${REPO_ROOT}/config/users.json"   "${VM_USER}@${VM_IP}:/tmp/users.json"
  vm_ssh "kubectl create configmap bankrag-config \
    --from-file=tenants.yaml=/tmp/tenants.yaml \
    --from-file=users.json=/tmp/users.json \
    -n bankrag \
    --dry-run=client -o yaml | kubectl apply -f -"

  # K8s YAML 파일들을 VM으로 복사
  step "K8s 매니페스트 복사..."
  vm_ssh "mkdir -p /tmp/bankrag-k8s"
  vm_scp "${K8S_DIR}/00-namespace.yaml"       "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/10-qdrant.yaml"          "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/11-redis.yaml"           "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/12-minio.yaml"           "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/13-flowise.yaml"         "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/14-api-gateway.yaml"     "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/15-jaeger.yaml"          "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/16-otel-collector.yaml"  "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/17-prometheus.yaml"      "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/18-grafana.yaml"         "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"
  vm_scp "${K8S_DIR}/19-ingress.yaml"         "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s/"

  # api-gateway YAML 의 레지스트리 IP 치환
  step "이미지 레지스트리 주소 치환 (registry.local → ${VM_IP}:30500)..."
  vm_ssh "
    sed -i 's|registry.local:5000|${VM_IP}:30500|g' /tmp/bankrag-k8s/14-api-gateway.yaml
  "

  # 배포
  step "K8s 리소스 배포..."
  if ${AIRGAP_MODE}; then
    # 폐쇄망: kustomize overlay 사용
    vm_scp -r "${AIRGAP_DIR}/kustomization.yaml" \
           "${VM_USER}@${VM_IP}:/tmp/bankrag-k8s-airgap/kustomization.yaml"
    vm_ssh "kubectl apply -k /tmp/bankrag-k8s-airgap/"
  else
    vm_ssh "kubectl apply -f /tmp/bankrag-k8s/ --recursive"
  fi

  step "배포 완료 대기 (핵심 서비스)..."
  local DEPLOYMENTS=("qdrant" "redis" "minio" "flowise" "jaeger" "prometheus" "grafana" "otel-collector")
  for D in "${DEPLOYMENTS[@]}"; do
    vm_ssh "kubectl rollout status deployment/${D} -n bankrag --timeout=120s" || \
      warn "${D} 준비 중 (계속 진행)..."
  done

  log "앱 배포 완료"
}

# ── MetalLB Ingress IP 감지 ───────────────────────────────────────────────────
get_ingress_ip() {
  header "MetalLB Ingress External IP 감지"

  local TIMEOUT=120
  local ELAPSED=0
  INGRESS_IP=""

  step "MetalLB가 Ingress에 IP를 할당하기를 대기..."
  while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    INGRESS_IP=$(vm_ssh \
      "kubectl get svc ingress-nginx-controller -n ingress-nginx \
       -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" || true)
    if [[ -n "${INGRESS_IP}" ]]; then
      log "Ingress External IP: ${INGRESS_IP}"
      return
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
  done
  echo ""

  warn "MetalLB IP 자동 감지 실패. VM IP를 대신 사용합니다."
  INGRESS_IP="${VM_IP}"
}

# ── /etc/hosts 업데이트 ───────────────────────────────────────────────────────
update_hosts() {
  header "/etc/hosts 업데이트 (내부 DNS)"
  #
  # [동작 원리]
  # MetalLB가 NGINX Ingress Service에 외부 IP(예: 192.168.100.200)를 할당합니다.
  # 이 IP로 오는 HTTP 요청은 Host 헤더를 보고 각 서비스로 라우팅됩니다.
  # /etc/hosts 에 IP → 도메인 매핑을 추가하면 브라우저에서 도메인으로 접근 가능합니다.
  #

  local HOSTS_FILE="/etc/hosts"
  local WIN_HOSTS_FILE="/mnt/c/Windows/System32/drivers/etc/hosts"

  log "Ingress IP: ${INGRESS_IP}"
  log "도메인 접미사: ${DOMAIN_SUFFIX}"

  # 기존 bankrag 항목 제거
  sudo sed -i "/${DOMAIN_SUFFIX}/d" "${HOSTS_FILE}"

  echo "" | sudo tee -a "${HOSTS_FILE}"
  echo "# ── AI-Flowise-RAG (bankrag) – MetalLB Ingress IP: ${INGRESS_IP} ──" | \
    sudo tee -a "${HOSTS_FILE}"

  for SVC in "${SERVICES[@]}"; do
    local HOST="${SVC}.${DOMAIN_SUFFIX}"
    echo "${INGRESS_IP}  ${HOST}" | sudo tee -a "${HOSTS_FILE}"
    log "  등록: ${INGRESS_IP}  ${HOST}"
  done

  # Windows hosts 파일 업데이트 (권한 있는 경우)
  if [[ -w "${WIN_HOSTS_FILE}" ]]; then
    step "Windows hosts 파일도 업데이트..."
    sed -i "/${DOMAIN_SUFFIX}/d" "${WIN_HOSTS_FILE}"
    echo "" >> "${WIN_HOSTS_FILE}"
    echo "# AI-Flowise-RAG (bankrag)" >> "${WIN_HOSTS_FILE}"
    for SVC in "${SERVICES[@]}"; do
      echo "${INGRESS_IP}  ${SVC}.${DOMAIN_SUFFIX}" >> "${WIN_HOSTS_FILE}"
    done
    log "Windows hosts 파일 업데이트 완료"
  else
    warn "Windows hosts 파일 쓰기 권한 없음."
    warn "관리자 권한으로 아래 내용을 추가하세요:"
    warn "  파일: C:\\Windows\\System32\\drivers\\etc\\hosts"
    echo ""
    echo "# AI-Flowise-RAG (bankrag)"
    for SVC in "${SERVICES[@]}"; do
      echo "${INGRESS_IP}  ${SVC}.${DOMAIN_SUFFIX}"
    done
    echo ""
  fi

  # WSL2에서 VMware NAT 라우팅 확인 및 재설정
  step "WSL2 라우팅 재확인..."
  WIN_HOST_IP=$(cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
  if ! ip route show | grep -q "${VMWARE_NAT_CIDR}"; then
    sudo ip route add "${VMWARE_NAT_CIDR}" via "${WIN_HOST_IP}" dev eth0 2>/dev/null || true
    log "WSL2 → VMware NAT 라우팅 추가 완료"
  fi
}

# ── Windows netsh 포트 포워딩 설정 안내 ──────────────────────────────────────
setup_port_forwarding_guide() {
  header "Windows 포트 포워딩 설정 (선택사항)"
  #
  # [목적]
  # 외부 LAN(다른 PC, 모바일 등)에서 Windows 호스트의 IP로 접근하면
  # VMware VM 안의 서비스로 포워딩합니다.
  #

  cat <<GUIDE

${CYAN}[외부 LAN 접근을 위한 Windows netsh 포트 포워딩]${NC}
관리자 권한 PowerShell 에서 실행:

# Ingress HTTP (80) 포워딩
netsh interface portproxy add v4tov4 \\
    listenaddress=0.0.0.0 listenport=80 \\
    connectaddress=${INGRESS_IP} connectport=80

# Ingress HTTPS (443) 포워딩 (HTTPS 설정 시)
netsh interface portproxy add v4tov4 \\
    listenaddress=0.0.0.0 listenport=443 \\
    connectaddress=${INGRESS_IP} connectport=443

# 포워딩 목록 확인
netsh interface portproxy show all

# 포워딩 제거
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=80

${YELLOW}Windows 방화벽 인바운드 규칙도 추가해야 합니다:${NC}
New-NetFirewallRule -DisplayName "BankRAG-HTTP" \\
    -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow

GUIDE
}

# ── 최종 요약 출력 ────────────────────────────────────────────────────────────
print_summary() {
  header "배포 완료 요약"

  cat <<SUMMARY

${GREEN}${BOLD}════════════════════════════════════════════════════════════════${NC}
${GREEN}${BOLD}   AI-Flowise-RAG K8s 배포 완료!${NC}
${GREEN}${BOLD}════════════════════════════════════════════════════════════════${NC}

${BOLD}▶ VM 정보${NC}
  VM 이름:    ${VM_NAME}
  VM IP:      ${VM_IP}
  OS:         Ubuntu 22.04 Server
  K8s:        k3s ${K3S_VERSION}

${BOLD}▶ 네트워크${NC}
  MetalLB IP: ${INGRESS_IP}
  Ingress:    NGINX (호스트 기반 라우팅)
  도메인:     *.${DOMAIN_SUFFIX}

${BOLD}▶ 서비스 접근 URL (브라우저)${NC}
  FE + API Gateway   http://api-gateway.${DOMAIN_SUFFIX}
  Flowise            http://flowise.${DOMAIN_SUFFIX}         (admin / admin1234)
  Qdrant             http://qdrant.${DOMAIN_SUFFIX}/dashboard
  Jaeger             http://jaeger.${DOMAIN_SUFFIX}
  Prometheus         http://prometheus.${DOMAIN_SUFFIX}
  Grafana            http://grafana.${DOMAIN_SUFFIX}         (admin / admin1234)
  MinIO              http://minio.${DOMAIN_SUFFIX}           (minio / minio1234)

${BOLD}▶ 내부 DNS 등록 파일${NC}
  WSL:     /etc/hosts  (자동 등록)
  Windows: C:\\Windows\\System32\\drivers\\etc\\hosts  (수동 등록 필요)

${BOLD}▶ K8s 관리 명령 (VM SSH 접속 후)${NC}
  ssh -i ${VM_SSH_KEY} ${VM_USER}@${VM_IP}
  kubectl get pods -n bankrag
  kubectl get svc  -n bankrag
  kubectl logs -f deployment/api-gateway -n bankrag

${BOLD}▶ 폐쇄망 재배포${NC}
  kubectl apply -k deploy/k8s-vmware/airgap/

${GREEN}${BOLD}════════════════════════════════════════════════════════════════${NC}

SUMMARY
}

# ==============================================================================
# 메인 실행 흐름
# ==============================================================================
main() {
  echo -e "${BLUE}${BOLD}"
  echo "  ██████╗  █████╗ ███╗   ██╗██╗  ██╗██████╗  █████╗  ██████╗"
  echo "  ██╔══██╗██╔══██╗████╗  ██║██║ ██╔╝██╔══██╗██╔══██╗██╔════╝"
  echo "  ██████╔╝███████║██╔██╗ ██║█████╔╝ ██████╔╝███████║██║  ███╗"
  echo "  ██╔══██╗██╔══██║██║╚██╗██║██╔═██╗ ██╔══██╗██╔══██║██║   ██║"
  echo "  ██████╔╝██║  ██║██║ ╚████║██║  ██╗██║  ██║██║  ██║╚██████╔╝"
  echo "  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝"
  echo -e "${NC}"
  echo -e "  AI-Flowise-RAG  │  VMware + K3s + MetalLB + Ingress 자동 배포"
  echo -e "  모드: $(${AIRGAP_MODE} && echo '폐쇄망(air-gap)' || echo '온라인')"
  echo ""

  check_wsl
  check_vmware
  setup_ssh_key
  prepare_iso
  create_seed_iso
  create_vm
  start_and_wait_vm

  install_k3s
  install_metallb
  install_ingress

  # 폐쇄망 모드: 로컬 레지스트리 먼저 설정
  if ${AIRGAP_MODE}; then
    log "폐쇄망 모드: 로컬 레지스트리 + 이미지 import..."
    vm_ssh "chmod +x /home/${VM_USER}/airgap/*.sh"
    vm_ssh "sudo /home/${VM_USER}/airgap/01-setup-local-registry.sh"
    vm_ssh "/home/${VM_USER}/airgap/02-import-and-push.sh"
  fi

  # 커스텀 앱 빌드 & push
  build_and_push_apps

  # K8s 리소스 배포
  vm_ssh "kubectl create namespace bankrag --dry-run=client -o yaml | kubectl apply -f -"
  deploy_apps

  # Ingress IP 감지 및 hosts 업데이트
  get_ingress_ip
  update_hosts
  setup_port_forwarding_guide
  print_summary
}

main "$@"
