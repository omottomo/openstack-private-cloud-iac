#!/usr/bin/env bash
# DevStack all-in-one 설치. 30~60분 걸린다.
#
# 사용법: sudo ./scripts/01-install-devstack.sh
#
# 값은 전부 자동 감지하며, 환경변수로 덮어쓸 수 있다:
#   HOST_IP  PUBLIC_INTERFACE  PUBLIC_NETWORK_GATEWAY  FLOATING_RANGE
#   FLOATING_POOL_START  FLOATING_POOL_END  ADMIN_PASSWORD  DEVSTACK_BRANCH
#   ASSUME_YES=1 로 확인 프롬프트 생략
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/detect.sh
source "$SCRIPT_DIR/detect.sh"

STACK_HOME=/opt/stack
DEVSTACK_DIR="$STACK_HOME/devstack"
# master는 개발자들이 실시간으로 고치는 브랜치라 받는 시점에 따라 그냥 깨져 있다. stable 고정.
DEVSTACK_BRANCH=${DEVSTACK_BRANCH:-stable/2025.1}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-secret}
VOLUME_BACKING_FILE_SIZE=${VOLUME_BACKING_FILE_SIZE:-30G}

if [ "$(id -u)" -ne 0 ]; then
  echo "root 권한이 필요하다: sudo $0" >&2
  exit 1
fi

detect_network

cat <<EOF

DevStack을 아래 설정으로 설치한다.

$(print_network)
  DevStack 브랜치         = $DEVSTACK_BRANCH
  Cinder 백킹 파일 크기   = $VOLUME_BACKING_FILE_SIZE

⚠️  경고 — SSH로 실행하지 말 것.
    설치 중 PUBLIC_INTERFACE($PUBLIC_INTERFACE)가 가상 스위치 br-ex에 편입되는 순간
    호스트 네트워크가 끊긴다. 원격 접속이라면 그 자리에서 설치가 중단된다.
    반드시 PC 앞에 앉아 로컬 콘솔에서 실행할 것.

⚠️  Floating IP 범위($FLOATING_POOL_START ~ $FLOATING_POOL_END)가 공유기 DHCP 범위와
    겹치지 않는지 확인했는가? 겹치면 IP 충돌이 난다.

EOF

if [ "${ASSUME_YES:-0}" != "1" ]; then
  read -r -p "위 설정으로 진행한다 [y/N]: " answer </dev/tty
  [[ "$answer" =~ ^[Yy]$ ]] || {
    echo "중단."
    exit 1
  }
fi

echo "== 1/5 stack 유저 =="
# stack.sh는 root가 아닌 일반 유저로 실행하도록 설계돼 있다. root로 돌리면 중간에 권한 문제로 실패한다.
if id stack &>/dev/null; then
  echo "  이미 존재 — 건너뜀"
else
  useradd -s /bin/bash -d "$STACK_HOME" -m stack
  echo "  stack 유저 생성"
fi
chmod +x "$STACK_HOME" # 다른 서비스가 /opt/stack 안으로 들어갈 수 있게
echo "stack ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/stack
chmod 440 /etc/sudoers.d/stack

echo "== 2/5 DevStack 소스 =="
if [ -d "$DEVSTACK_DIR/.git" ]; then
  echo "  이미 클론됨 — $DEVSTACK_BRANCH 로 갱신"
  sudo -u stack git -C "$DEVSTACK_DIR" fetch --depth 1 origin "$DEVSTACK_BRANCH"
  sudo -u stack git -C "$DEVSTACK_DIR" checkout FETCH_HEAD
else
  sudo -u stack git clone --depth 1 https://opendev.org/openstack/devstack \
    -b "$DEVSTACK_BRANCH" "$DEVSTACK_DIR"
fi

echo "== 3/5 local.conf 렌더 =="
export ADMIN_PASSWORD VOLUME_BACKING_FILE_SIZE
envsubst '${ADMIN_PASSWORD} ${HOST_IP} ${PUBLIC_INTERFACE} ${FLOATING_RANGE}
          ${FLOATING_POOL_START} ${FLOATING_POOL_END} ${PUBLIC_NETWORK_GATEWAY}
          ${VOLUME_BACKING_FILE_SIZE}' \
  <"$SCRIPT_DIR/local.conf.template" >"$DEVSTACK_DIR/local.conf"
chown stack:stack "$DEVSTACK_DIR/local.conf"
echo "  $DEVSTACK_DIR/local.conf"

echo "== 4/5 local.sh (br-ex 게이트웨이 사칭 상쇄) =="
envsubst '${PUBLIC_NETWORK_GATEWAY} ${LAN_PREFIXLEN}' \
  <"$SCRIPT_DIR/local.sh.template" >"$DEVSTACK_DIR/local.sh"
chown stack:stack "$DEVSTACK_DIR/local.sh"
chmod +x "$DEVSTACK_DIR/local.sh"
echo "  $DEVSTACK_DIR/local.sh"

echo "== 5/5 stack.sh 실행 (30~60분) =="
sudo -u stack -H bash -c "cd '$DEVSTACK_DIR' && ./stack.sh"

cat <<EOF

설치 완료.

  Horizon: http://$HOST_IP/dashboard  (admin / $ADMIN_PASSWORD)

확인:
  sudo -u stack -i
  source $DEVSTACK_DIR/openrc admin admin
  openstack service list      # keystone/nova/neutron/glance/cinder/placement
  openstack hypervisor list   # 이 PC가 하이퍼바이저로 등록됐는지

호스트가 VM이라면 지금 스냅샷을 뜰 것. DevStack은 재부팅에 취약하다.

다음: ./scripts/02-bootstrap.sh
EOF
