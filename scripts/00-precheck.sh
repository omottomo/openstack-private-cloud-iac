#!/usr/bin/env bash
# DevStack 설치 전 하드웨어/OS/네트워크 사전 점검.
#
# 설치는 30~60분 걸린다. 조건 미달을 설치 도중이나 설치 후에 발견하면
# 그 시간을 통째로 잃는다. 출발 전 차량 점검에 해당한다.
#
# 사용법: ./scripts/00-precheck.sh
set -uo pipefail

cd "$(dirname "$0")"
# shellcheck source=scripts/detect.sh
source ./detect.sh

FAIL=0
ok() { printf '  [OK]   %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  FAIL=1
}

echo "== 하드웨어 =="

# VM 3대(각 2GB) + DevStack 서비스 자체가 쓸 몫까지. 16GB 미만이면 VM 생성 단계에서 막힌다.
RAM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$RAM_MB" -ge 15000 ]; then
  ok "RAM ${RAM_MB}MB"
else
  bad "RAM ${RAM_MB}MB — 16GB 이상 필요"
fi

# DevStack 소스+이미지+Cinder 백킹 파일(30G)까지.
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$DISK_GB" -ge 60 ]; then
  ok "루트(/) 여유 ${DISK_GB}GB"
else
  bad "루트(/) 여유 ${DISK_GB}GB — 60GB 이상 필요"
fi

# CPU 가상화 지원(vmx=Intel, svm=AMD). 없으면 VM이 소프트웨어 에뮬레이션으로 돌아 못 쓸 만큼 느리다.
if [ "$(grep -Ec '(vmx|svm)' /proc/cpuinfo)" -gt 0 ]; then
  ok "CPU 가상화 지원(vmx/svm)"
else
  bad "CPU 가상화 미지원 — BIOS에서 VT-x/AMD-V 활성화 필요"
fi

# 지원과 별개로 커널 모듈이 실제로 올라와 있어야 한다.
if lsmod | grep -q '^kvm'; then
  ok "kvm 커널 모듈 로드됨"
else
  bad "kvm 모듈 없음 — BIOS 가상화 설정 확인 후 재부팅"
fi

echo
echo "== OS =="
# shellcheck source=/dev/null
source /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
  bad "${PRETTY_NAME:-unknown} — DevStack 공식 지원 대상은 Ubuntu"
elif [ "${VERSION_ID:-}" = "22.04" ]; then
  ok "${PRETTY_NAME:-unknown}"
else
  warn "${PRETTY_NAME:-unknown} — 이 구성은 22.04에서 검증했다. 다른 버전은 stack.sh가 중간에 깨질 수 있다"
fi

echo
echo "== 네트워크 (감지값) =="
if detect_network; then
  print_network
  ok "기본 경로 감지 성공"
else
  bad "네트워크 감지 실패"
fi

echo
cat <<'EOF'
== 스크립트가 확인할 수 없는 것 — 직접 볼 것 ==
  - 공유기 DHCP 할당 범위가 위 "Floating IP 할당 범위"와 겹치지 않는가?
    겹치면 스마트폰이 받아간 IP를 VM도 쓰겠다고 나서서 충돌한다.
  - 호스트 PC에 MAC 기반 고정 IP(DHCP reservation)를 걸어뒀는가?
    재부팅마다 IP가 바뀌면 local.conf와 실제가 어긋나 전부 깨진다.
  - 공유기의 "AP 격리"(무선 기기 간 통신 차단)가 꺼져 있는가?
    켜져 있으면 마지막 검증에서 노트북 → VM 접속이 안 되는데 원인을 찾기 매우 어렵다.
EOF

echo
if [ "$FAIL" -eq 0 ]; then
  echo "사전 점검 통과. 다음: sudo ./scripts/01-install-devstack.sh"
else
  echo "사전 점검 실패 — 위 [FAIL] 항목을 해결한 뒤 다시 실행할 것."
fi
exit "$FAIL"
