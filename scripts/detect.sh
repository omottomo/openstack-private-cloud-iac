#!/usr/bin/env bash
# 네트워크 값 자동 감지 — 00/01/02 스크립트가 공통으로 source 한다.
#
# 감지하는 값은 전부 "기본 경로(default route)가 나가는 랜카드" 기준이다.
# 환경변수로 미리 지정한 값이 있으면 그쪽을 우선한다 (NIC이 여러 장인 경우 대비).

detect_network() {
  local route
  route=$(ip -o -4 route show default | head -1)
  if [ -z "$route" ]; then
    echo "기본 경로(default route)가 없다. 유선 랜이 연결돼 있는지 확인할 것." >&2
    return 1
  fi

  # 예: "default via 192.168.0.1 dev enp2s0 proto dhcp ..."
  PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-$(awk '{print $5}' <<<"$route")}
  PUBLIC_NETWORK_GATEWAY=${PUBLIC_NETWORK_GATEWAY:-$(awk '{print $3}' <<<"$route")}

  # 그 랜카드에 붙은 IPv4 주소 (Floating IP가 아니라 호스트 자신의 주소)
  HOST_IP=${HOST_IP:-$(ip -o -4 addr show dev "$PUBLIC_INTERFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)}

  # 그 랜카드가 물린 대역. default 이외의 경로가 곧 서브넷이다. 예: 192.168.0.0/24
  # (default 경로에도 proto kernel이 붙는 환경이 있어 이름으로 걸러낸다)
  FLOATING_RANGE=${FLOATING_RANGE:-$(ip -o -4 route show dev "$PUBLIC_INTERFACE" | awk '$1 != "default" {print $1; exit}')}

  # Floating IP로 나눠줄 범위. 공유기 DHCP 범위와 겹치면 IP 충돌이 나므로
  # 대역 끝쪽(.200~.220)을 기본값으로 잡는다. 공유기 DHCP 설정을 반드시 눈으로 확인할 것.
  local prefix
  prefix=$(cut -d. -f1-3 <<<"$HOST_IP")
  FLOATING_POOL_START=${FLOATING_POOL_START:-"$prefix.200"}
  FLOATING_POOL_END=${FLOATING_POOL_END:-"$prefix.220"}

  # Security Group에서 SSH/HTTP를 허용할 대역 = 호스트가 속한 LAN
  LAN_CIDR=${LAN_CIDR:-$FLOATING_RANGE}

  # local.sh가 br-ex에서 주소를 뗄 때 쓸 프리픽스 길이 (보통 24)
  LAN_PREFIXLEN=${FLOATING_RANGE##*/}

  export PUBLIC_INTERFACE PUBLIC_NETWORK_GATEWAY HOST_IP \
    FLOATING_RANGE FLOATING_POOL_START FLOATING_POOL_END LAN_CIDR LAN_PREFIXLEN
}

print_network() {
  cat <<EOF
  PUBLIC_INTERFACE       = $PUBLIC_INTERFACE
  HOST_IP                = $HOST_IP
  PUBLIC_NETWORK_GATEWAY = $PUBLIC_NETWORK_GATEWAY
  FLOATING_RANGE         = $FLOATING_RANGE
  Floating IP 할당 범위  = $FLOATING_POOL_START ~ $FLOATING_POOL_END
EOF
}
