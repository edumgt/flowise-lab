# AI-Flowise-RAG — VMware + K3s + MetalLB + Ingress 배포 가이드

WSL2 환경에서 VMware Workstation VM을 생성하고, Ubuntu 22.04 위에 k3s를 설치한 뒤
AI-Flowise-RAG 전체 스택을 최소 리소스(1 레플리카)로 배포하는 가이드입니다.

---

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [VMware 네트워크 설정](#2-vmware-네트워크-설정)
3. [사전 요구사항](#3-사전-요구사항)
4. [온라인 모드 (인터넷 연결)](#4-온라인-모드-빠른-시작)
5. [폐쇄망 모드 (air-gap)](#5-폐쇄망-모드-air-gap)
6. [MetalLB & Ingress 설명](#6-metallb--ingress-설명)
7. [내부 DNS (hosts 파일)](#7-내부-dns-hosts-파일)
8. [서비스 접근 URL](#8-서비스-접근-url)
9. [리소스 최소화 설정](#9-리소스-최소화-설정)
10. [트러블슈팅](#10-트러블슈팅)

---

## 1. 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────────────┐
│  Windows 11 (Host)                                                  │
│                                                                     │
│  ┌──────────────┐    ┌──────────────────────────────────────────┐  │
│  │   WSL2       │    │  VMware Workstation (NAT: VMnet8)         │  │
│  │  172.x.x.x   │    │                                          │  │
│  │              │    │  ┌──────────────────────────────────────┐│  │
│  │  setup-      │    │  │  Ubuntu 22.04 VM (192.168.100.xxx)   ││  │
│  │  vmware-     │───▶│  │                                      ││  │
│  │  k8s.sh      │SSH │  │  k3s (Kubernetes)                    ││  │
│  │              │    │  │  ┌────────────────────────────────┐  ││  │
│  └──────────────┘    │  │  │  namespace: bankrag             │  ││  │
│                      │  │  │                                │  ││  │
│  ┌──────────────┐    │  │  │  qdrant  redis  minio          │  ││  │
│  │  Browser     │    │  │  │  flowise jaeger prometheus      │  ││  │
│  │  (hosts 파일)│    │  │  │  grafana otel-collector         │  ││  │
│  │              │    │  │  │  api-gateway                   │  ││  │
│  │  *.bankrag   │    │  │  └────────────────────────────────┘  ││  │
│  │  .local      │    │  │                                      ││  │
│  │  ──────────  │    │  │  MetalLB  (IP: 192.168.100.200)      ││  │
│  │  192.168.100 │    │  │  NGINX Ingress (Host-based routing)  ││  │
│  │  .200        │───▶│  └──────────────────────────────────────┘│  │
│  └──────────────┘    └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. VMware 네트워크 설정

### VMware Workstation 네트워크 모드

| 모드 | 가상 스위치 | VM IP 대역 | 인터넷 | 외부 LAN 접근 |
|------|------------|-----------|--------|--------------|
| **NAT** (권장) | VMnet8 | 192.168.x.0/24 (사설) | ✅ (NAT 공유) | netsh 포워딩 필요 |
| Bridged | VMnet0 | LAN 대역 직접 | ✅ | ✅ (직접 접근) |
| Host-only | VMnet1 | 192.168.y.0/24 (사설) | ❌ | ❌ |

### NAT 모드 IP 확인 방법

```
VMware Workstation → Edit → Virtual Network Editor
→ VMnet8 선택
→ Subnet IP: 192.168.100.0   (예시)
→ Subnet Mask: 255.255.255.0
→ [DHCP Settings] → Starting IP / Ending IP 확인
```

### MetalLB IP 풀 선택 기준

MetalLB는 VMware DHCP 범위 밖의 고정 IP를 사용해야 합니다.

```
예시: VMware NAT 기본 설정
  서브넷:      192.168.100.0/24
  DHCP 범위:   192.168.100.128 ~ 192.168.100.253
  호스트(VMnet8): 192.168.100.1

권장 MetalLB 풀: 192.168.100.200 ~ 192.168.100.220
  → DHCP 시작 주소를 .221 이상으로 변경 필요:
     Virtual Network Editor → VMnet8 → DHCP Settings
     → Starting IP: 192.168.100.221
```

### WSL2 → VMware NAT VM 통신 설정

WSL2는 `172.x.x.x` 가상 네트워크를 사용하므로 VMware NAT(`192.168.x.x`)로의 라우팅을 수동 추가해야 합니다.

```bash
# Windows 호스트 IP 확인 (WSL2 관점)
WIN_HOST_IP=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}')
echo "Windows Host: ${WIN_HOST_IP}"

# VMware NAT 서브넷으로 라우팅 추가
sudo ip route add 192.168.100.0/24 via "${WIN_HOST_IP}"

# 라우팅 확인
ip route show | grep 192.168.100
```

> **주의**: WSL2 재시작 시 라우팅이 초기화됩니다. `/etc/wsl.conf` 설정 또는
> `setup-vmware-k8s.sh`가 자동으로 재추가합니다.

### Windows 방화벽 설정

VMware NAT 어댑터(VMnet8)에서 VM으로의 트래픽을 허용해야 합니다.

```powershell
# (관리자 PowerShell) VMnet8 어댑터에서 SSH, HTTP 허용
New-NetFirewallRule -DisplayName "VMware-VMnet8-SSH" `
    -Direction Inbound -InterfaceAlias "VMware Network Adapter VMnet8" `
    -Protocol TCP -LocalPort 22 -Action Allow

New-NetFirewallRule -DisplayName "VMware-VMnet8-HTTP" `
    -Direction Inbound -InterfaceAlias "VMware Network Adapter VMnet8" `
    -Protocol TCP -LocalPort 80,443 -Action Allow
```

---

## 3. 사전 요구사항

| 항목 | 최소 | 권장 |
|------|------|------|
| CPU | 4코어 (호스트) | 8코어+ |
| RAM | 16 GB (호스트) | 32 GB |
| Disk | 100 GB 여유 | 200 GB |
| OS | Windows 10 21H2+ | Windows 11 |
| WSL2 | Ubuntu 20.04+ | Ubuntu 22.04 |
| VMware | Workstation Player 17+ | Workstation Pro 17+ |

```bash
# WSL2 버전 확인
wsl --status

# VMware 설치 확인 (WSL에서)
ls "/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
```

---

## 4. 온라인 모드 (빠른 시작)

```bash
# 1. 레포지토리 루트로 이동
cd /path/to/AI-Flowise-RAG

# 2. 스크립트 실행 권한 부여
chmod +x deploy/k8s-vmware/setup-vmware-k8s.sh
chmod +x deploy/k8s-vmware/airgap/*.sh

# 3. 실행 (NAT 네트워크 기본값 사용)
./deploy/k8s-vmware/setup-vmware-k8s.sh

# 4. MetalLB IP 범위를 직접 지정하는 경우
./deploy/k8s-vmware/setup-vmware-k8s.sh \
    --metallb-range 192.168.100.200-192.168.100.220

# 5. 이미 VM이 있고 k3s만 재배포하는 경우
./deploy/k8s-vmware/setup-vmware-k8s.sh \
    --skip-vm \
    --metallb-range 192.168.100.200-192.168.100.220
```

---

## 5. 폐쇄망 모드 (air-gap)

### 5.1 폐쇄망에서 K8s YAML 사용 시 필요한 처리 목록

폐쇄망 환경에서는 외부 인터넷 접근이 불가능하므로 아래 항목을 사전에 준비해야 합니다.

```
┌─────────────────────────────────────────────────────────────────────┐
│  폐쇄망 배포를 위한 필수 준비 사항                                   │
├──────────────────────────────┬──────────────────────────────────────┤
│  항목                        │  처리 방법                          │
├──────────────────────────────┼──────────────────────────────────────┤
│ 1. 컨테이너 이미지           │ 인터넷 PC에서 docker pull + save    │
│    (모든 이미지 공개 레지스트│ 폐쇄망에 복사 후 docker load        │
│    리에서 다운로드 불가)     │ 내부 레지스트리(registry.local)에 push │
├──────────────────────────────┼──────────────────────────────────────┤
│ 2. 이미지 참조 경로 변경     │ kustomize overlay의 images 필드로   │
│    (docker.io → 내부 레지스  │ 모든 이미지 newName 치환            │
│    트리)                     │ airgap/kustomization.yaml 참조      │
├──────────────────────────────┼──────────────────────────────────────┤
│ 3. imagePullPolicy 변경      │ IfNotPresent 설정 (Always는 외부    │
│    (Always → IfNotPresent)   │ 레지스트리 접근 시도함)             │
├──────────────────────────────┼──────────────────────────────────────┤
│ 4. k3s 바이너리 / 번들       │ GitHub Releases에서 사전 다운로드   │
│    (설치 스크립트가 인터넷   │ k3s + k3s-airgap-images-amd64.tar  │
│    에서 다운로드)            │ 03-install-k3s-airgap.sh 사용       │
├──────────────────────────────┼──────────────────────────────────────┤
│ 5. MetalLB / Ingress YAML    │ 인터넷 PC에서 curl로 다운로드       │
│    (kubectl apply URL 형태)  │ 폐쇄망에 복사 후 파일로 apply       │
│                              │ 00-pull-and-export.sh 가 자동 처리  │
├──────────────────────────────┼──────────────────────────────────────┤
│ 6. 내부 DNS / 인증서         │ /etc/hosts 파일로 이름 해석          │
│    (외부 DNS 조회 불가)      │ HTTPS 필요 시 self-signed 인증서 생성│
├──────────────────────────────┼──────────────────────────────────────┤
│ 7. Grafana 플러그인 / 업데이 │ GF_ANALYTICS_CHECK_FOR_UPDATES=false │
│    트 체크 (인터넷 통신 시도)│ GF_ANALYTICS_REPORTING_ENABLED=false │
├──────────────────────────────┼──────────────────────────────────────┤
│ 8. 커스텀 앱 이미지 빌드     │ 인터넷 PC에서 docker build + save   │
│    (api-gateway 등)          │ 폐쇄망 레지스트리에 push            │
└──────────────────────────────┴──────────────────────────────────────┘
```

### 5.2 폐쇄망 배포 단계별 절차

```
[인터넷 연결 PC]                    [폐쇄망 VM]
      │                                   │
      │ 1. 이미지 & 바이너리 준비          │
      │ $ ./airgap/00-pull-and-export.sh   │
      │   → ./airgap/images/ 생성          │
      │                                   │
      │ 2. USB/HDD/파일서버로 전송 ───────▶│
      │   airgap/images/ 디렉토리          │
      │                                   │
      │                           3. k3s air-gap 설치
      │                           $ sudo ./airgap/03-install-k3s-airgap.sh
      │                                   │
      │                           4. 로컬 레지스트리 배포
      │                           $ ./airgap/01-setup-local-registry.sh
      │                                   │
      │                           5. 이미지 import & push
      │                           $ ./airgap/02-import-and-push.sh
      │                                   │
      │                           6. 앱 배포 (kustomize overlay)
      │                           $ kubectl apply -k deploy/k8s-vmware/airgap/
      │                                   │
```

### 5.3 단계별 스크립트

```bash
# ── [인터넷 PC / WSL] ────────────────────────────────────────────
# 1. 모든 이미지 pull + tar 저장 + k3s 바이너리 + MetalLB/Ingress YAML
cd deploy/k8s-vmware
chmod +x airgap/*.sh
./airgap/00-pull-and-export.sh
# 출력: airgap/images/ 디렉토리 (수십 GB)

# USB/네트워크로 폐쇄망 VM에 전송
rsync -avz airgap/images/ user@airgap-vm:/home/user/airgap/images/
# 또는 USB 마운트 후 복사

# ── [폐쇄망 VM] ─────────────────────────────────────────────────
# 2. k3s air-gap 설치 (인터넷 없이)
sudo ./airgap/03-install-k3s-airgap.sh

# 3. 내부 레지스트리(registry.local:5000) 배포
./airgap/01-setup-local-registry.sh

# 4. 이미지 import → 레지스트리 push
./airgap/02-import-and-push.sh

# 5. kustomize overlay로 앱 배포 (이미지 경로 자동 치환)
kubectl apply -k deploy/k8s-vmware/airgap/

# 6. 배포 상태 확인
kubectl get pods -n bankrag
kubectl get svc  -n bankrag
```

### 5.4 Kustomize overlay 동작 원리

```yaml
# airgap/kustomization.yaml 핵심 부분

images:
  # 공개 레지스트리 이미지를 내부 레지스트리로 자동 교체
  - name: qdrant/qdrant
    newName: registry.local:5000/qdrant/qdrant
    newTag: v1.9.5
  # ...모든 이미지에 대해 동일하게 적용...

patches:
  # 모든 Deployment 의 imagePullPolicy를 IfNotPresent로 강제
  - patch: |-
      spec:
        template:
          spec:
            containers:
              - name: not-used
                imagePullPolicy: IfNotPresent
    target:
      kind: Deployment
      labelSelector: "app.kubernetes.io/part-of=bankrag"
```

---

## 6. MetalLB & Ingress 설명

### MetalLB (Layer2 모드)

```
K8s LoadBalancer 서비스 생성
         │
         ▼
MetalLB Controller
  IPAddressPool 에서 IP 선택 (예: 192.168.100.200)
         │
         ▼
MetalLB Speaker (각 노드에서 실행)
  ARP 응답: "192.168.100.200 = VM의 MAC 주소"
         │
         ▼
같은 L2 세그먼트(VMnet8)에 있는 클라이언트가
192.168.100.200 으로 직접 접근 가능
```

### NGINX Ingress (호스트 기반 라우팅)

```
클라이언트 요청: http://grafana.bankrag.local/
         │
         ▼ (192.168.100.200:80 → MetalLB → NGINX Ingress)
NGINX Ingress Controller
  Host: grafana.bankrag.local
         │
         ▼ (Ingress 규칙 매칭)
Service: grafana:3000 (ClusterIP)
         │
         ▼
Pod: grafana (bankrag 네임스페이스)
```

### 설치 확인

```bash
# MetalLB 상태
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system

# Ingress 상태 및 External IP 확인
kubectl get svc ingress-nginx-controller -n ingress-nginx
# NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP       PORT(S)
# ingress-nginx-controller   LoadBalancer   10.96.x.x      192.168.100.200   80:xxx/TCP

# Ingress 라우팅 규칙 확인
kubectl get ingress -n bankrag
```

---

## 7. 내부 DNS (hosts 파일)

`setup-vmware-k8s.sh`가 자동으로 등록하지만, 수동으로 등록할 때는 아래를 참고하세요.

### WSL2 `/etc/hosts`

```bash
# MetalLB Ingress IP 확인
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Ingress IP: ${INGRESS_IP}"

# /etc/hosts 에 추가
sudo tee -a /etc/hosts <<EOF

# AI-Flowise-RAG (bankrag) – $(date +%Y-%m-%d)
${INGRESS_IP}  api-gateway.bankrag.local
${INGRESS_IP}  flowise.bankrag.local
${INGRESS_IP}  qdrant.bankrag.local
${INGRESS_IP}  jaeger.bankrag.local
${INGRESS_IP}  prometheus.bankrag.local
${INGRESS_IP}  grafana.bankrag.local
${INGRESS_IP}  minio.bankrag.local
EOF
```

### Windows `C:\Windows\System32\drivers\etc\hosts`

관리자 권한 메모장 또는 PowerShell에서 수정:

```powershell
# (관리자 PowerShell)
$INGRESS_IP = "192.168.100.200"  # 실제 MetalLB IP로 교체
$HOSTS_FILE = "C:\Windows\System32\drivers\etc\hosts"
$ENTRIES = @"

# AI-Flowise-RAG (bankrag)
$INGRESS_IP  api-gateway.bankrag.local
$INGRESS_IP  flowise.bankrag.local
$INGRESS_IP  qdrant.bankrag.local
$INGRESS_IP  jaeger.bankrag.local
$INGRESS_IP  prometheus.bankrag.local
$INGRESS_IP  grafana.bankrag.local
$INGRESS_IP  minio.bankrag.local
"@
Add-Content -Path $HOSTS_FILE -Value $ENTRIES
```

### WSL2 재시작 시 라우팅 자동 복구

WSL2가 재시작되면 추가한 라우팅이 사라집니다. 아래를 `~/.bashrc`에 추가하세요:

```bash
# ~/.bashrc 에 추가
bankrag_route() {
  WIN_IP=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}')
  sudo ip route add 192.168.100.0/24 via "${WIN_IP}" 2>/dev/null || true
}
bankrag_route  # 자동 실행
```

---

## 8. 서비스 접근 URL

| 서비스 | URL | 자격증명 |
|--------|-----|---------|
| FE + API Gateway | http://api-gateway.bankrag.local | - |
| Flowise | http://flowise.bankrag.local | admin / admin1234 |
| Qdrant Dashboard | http://qdrant.bankrag.local/dashboard | - |
| Jaeger UI | http://jaeger.bankrag.local | - |
| Prometheus | http://prometheus.bankrag.local | - |
| Grafana | http://grafana.bankrag.local | admin / admin1234 |
| MinIO Console | http://minio.bankrag.local | minio / minio1234 |

---

## 9. 리소스 최소화 설정

각 서비스는 1 레플리카, 최소 리소스 요청으로 구성됩니다.

| 서비스 | CPU Request | CPU Limit | Mem Request | Mem Limit |
|--------|------------|-----------|-------------|-----------|
| qdrant | 100m | 500m | 256Mi | 512Mi |
| redis | 50m | 200m | 64Mi | 128Mi |
| minio | 100m | 300m | 128Mi | 512Mi |
| flowise | 200m | 500m | 256Mi | 512Mi |
| api-gateway | 100m | 300m | 128Mi | 256Mi |
| jaeger | 100m | 300m | 128Mi | 256Mi |
| otel-collector | 50m | 200m | 64Mi | 128Mi |
| prometheus | 100m | 300m | 256Mi | 512Mi |
| grafana | 50m | 200m | 64Mi | 128Mi |
| **합계** | **~850m** | **~2800m** | **~1344Mi** | **~2944Mi** |

**VM 권장 사양**: vCPU 4, RAM 8 GB (k3s 오버헤드 포함)

### 추가 최적화 팁

```bash
# Jaeger: 인메모리 모드 (재시작 시 트레이스 초기화)
# → SPAN_STORAGE_TYPE=memory (기본 설정)

# Prometheus: 보존 기간 단축 (기본 7일)
# → --storage.tsdb.retention.time=3d

# k3s 자체 리소스 줄이기
# → --disable coredns (내부 DNS 불필요 시)
# → --disable local-storage (외부 스토리지 사용 시)
```

---

## 10. 트러블슈팅

### MetalLB IP가 할당되지 않음

```bash
# MetalLB 로그 확인
kubectl logs -n metallb-system -l app=metallb,component=controller

# IP 풀 확인
kubectl describe ipaddresspool bankrag-pool -n metallb-system

# 주요 원인:
# 1. IP 풀이 DHCP 범위와 겹침 → VMware DHCP 범위 조정
# 2. metallb-system이 준비 안 됨 → 잠시 대기
# 3. L2Advertisement 미적용 → kubectl apply -f k8s/01-metallb-config.yaml
```

### VM SSH 접속 안 됨

```bash
# 라우팅 확인
ip route show | grep 192.168.100

# 직접 ping 테스트
ping 192.168.100.xxx

# vmrun으로 VM IP 확인
"/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe" \
    getGuestIPAddress "/path/to/vm.vmx"
```

### 폐쇄망에서 이미지 pull 실패

```bash
# imagePullPolicy 확인
kubectl get deployment -n bankrag -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].imagePullPolicy}{"\n"}{end}'

# 이미지 로컬 캐시 확인
sudo k3s ctr images ls | grep qdrant

# 레지스트리에서 이미지 목록 확인
curl http://registry.local:5000/v2/_catalog
curl http://192.168.100.xxx:30500/v2/_catalog
```

### Ingress 404 / 서비스 연결 안 됨

```bash
# Ingress 규칙 확인
kubectl describe ingress bankrag-ingress -n bankrag

# NGINX 로그 확인
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50

# 서비스 엔드포인트 확인
kubectl get endpoints -n bankrag
```

### WSL2 hosts 파일 영구 적용

WSL2는 재시작 시 `/etc/hosts`를 Windows에서 재생성합니다.
`/etc/wsl.conf`에 아래 설정을 추가하면 자동 덮어쓰기를 방지합니다:

```ini
# /etc/wsl.conf
[network]
generateHosts = false
generateResolvConf = false
```
