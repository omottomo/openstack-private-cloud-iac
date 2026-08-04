#!/usr/bin/env bash
# 배포 결과 검증. 스크린샷으로만 증명하던 것을 스크립트가 증명한다.
#
# 사용법: ./scripts/99-verify.sh
# 하나라도 실패하면 exit 1.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
export OS_CLOUD=${OS_CLOUD:-devstack-admin}

FAIL=0
ok() { printf '  [OK]   %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  FAIL=1
}

echo "== VM =="
SERVERS=$(openstack server list -f value -c Name -c Status)
for vm in web-vm db-vm monitoring-vm; do
  if grep -q "^$vm ACTIVE$" <<<"$SERVERS"; then
    ok "$vm ACTIVE"
  else
    bad "$vm — 현재: $(grep "^$vm " <<<"$SERVERS" || echo '없음')"
  fi
done

echo "== 볼륨 =="
# db-data가 in-use = db-vm에 붙어 있다 = MySQL 데이터가 Cinder 볼륨 위에 있다.
if openstack volume list -f value -c Name -c Status | grep -q '^db-data in-use$'; then
  ok "db-data in-use (db-vm에 부착됨)"
else
  bad "db-data 볼륨이 in-use가 아니다"
fi

echo "== Floating IP =="
# web/monitoring에만 붙어야 한다. db-vm에 붙어 있으면 private 경계가 깨진 것이다.
FIP_COUNT=$(openstack floating ip list -f value -c "Fixed IP Address" | grep -cv '^None$')
if [ "$FIP_COUNT" -eq 2 ]; then
  ok "Floating IP 2개 연결 (web-vm, monitoring-vm)"
else
  bad "연결된 Floating IP가 ${FIP_COUNT}개 — 2개여야 한다"
fi

echo "== 게시판 서비스 =="
WEB_IP=$(terraform -chdir="$REPO_DIR/terraform" output -raw web_floating_ip 2>/dev/null)
if [ -z "$WEB_IP" ]; then
  bad "terraform output에서 web_floating_ip를 읽지 못했다 (state가 있는 곳에서 실행할 것)"
else
  # cloud-init이 끝나기 전이면 아직 응답하지 않는다. 최대 2분 기다린다.
  for _ in $(seq 1 24); do
    BODY=$(curl -fsS --max-time 5 "http://$WEB_IP" 2>/dev/null) && break
    sleep 5
  done
  if grep -q 'Board' <<<"${BODY:-}"; then
    ok "http://$WEB_IP 응답 정상"
  else
    bad "http://$WEB_IP 응답 없음 또는 본문에 Board 없음"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "전부 통과. 게시판: http://$WEB_IP"
  echo "Grafana:  $(terraform -chdir="$REPO_DIR/terraform" output -raw grafana_url 2>/dev/null)"
else
  echo "검증 실패 — docs/troubleshooting.md 를 볼 것."
fi
exit "$FAIL"
