#!/usr/bin/env bash
# terraform apply 전에 필요한 전제를 채운다.
#   - Ubuntu 22.04 클라우드 이미지 (Glance에 올릴 원본)
#   - SSH 키페어 (VM 로그인용)
#   - clouds.yaml에 devstack-admin 항목이 있는지 확인 (providers.tf가 이 이름으로 인증한다)
#   - terraform/terraform.tfvars 생성
#
# 사용법: ./scripts/02-bootstrap.sh
# root가 아니라 clouds.yaml을 가진 유저(보통 stack)로 실행할 것.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
# shellcheck source=scripts/detect.sh
source "$SCRIPT_DIR/detect.sh"

IMAGE_URL=${IMAGE_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}
IMAGE_PATH=${IMAGE_PATH:-$HOME/jammy-server-cloudimg-amd64.img}
CLOUDS_YAML=${CLOUDS_YAML:-$HOME/.config/openstack/clouds.yaml}
TFVARS="$REPO_DIR/terraform/terraform.tfvars"

if [ "$(id -u)" -eq 0 ]; then
  echo "root로 실행하지 말 것 — clouds.yaml은 stack 유저 홈에 있다." >&2
  exit 1
fi

echo "== 1/4 클라우드 이미지 =="
if [ -f "$IMAGE_PATH" ]; then
  echo "  이미 있음 — $IMAGE_PATH"
else
  echo "  다운로드 (~600MB): $IMAGE_URL"
  curl -fL --progress-bar -o "$IMAGE_PATH" "$IMAGE_URL"
fi

echo "== 2/4 SSH 키페어 =="
PUBKEY=${PUBKEY:-$HOME/.ssh/id_rsa.pub}
if [ -f "$PUBKEY" ]; then
  echo "  이미 있음 — $PUBKEY"
else
  ssh-keygen -t rsa -b 4096 -N '' -f "${PUBKEY%.pub}"
  echo "  생성 — $PUBKEY"
fi

echo "== 3/4 clouds.yaml =="
if [ ! -f "$CLOUDS_YAML" ]; then
  cat >&2 <<EOF
  $CLOUDS_YAML 이 없다.
  DevStack 설치가 정상 종료했다면 자동 생성된다. stack 유저로 실행 중인지 확인할 것.
EOF
  exit 1
fi
# providers.tf가 cloud = "devstack-admin" 으로 인증하므로 그 항목의 auth_url을 그대로 쓴다.
AUTH_URL=$(python3 - "$CLOUDS_YAML" <<'PY'
import sys, yaml
clouds = yaml.safe_load(open(sys.argv[1]))["clouds"]
if "devstack-admin" not in clouds:
    sys.exit("clouds.yaml에 devstack-admin 항목이 없다. 있는 항목: " + ", ".join(clouds))
print(clouds["devstack-admin"]["auth"]["auth_url"])
PY
)
echo "  devstack-admin 확인 — auth_url=$AUTH_URL"

echo "== 4/4 terraform.tfvars =="
if [ -f "$TFVARS" ]; then
  echo "  이미 있음 — 덮어쓰지 않는다: $TFVARS"
  echo "  다시 만들려면 이 파일을 지우고 실행할 것."
else
  detect_network
  gen_pw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
  umask 077
  cat >"$TFVARS" <<EOF
# 02-bootstrap.sh가 생성. .gitignore로 커밋이 차단돼 있다 (비밀번호 평문).
image_local_path = "$IMAGE_PATH"
os_auth_url      = "$AUTH_URL"
public_key_path  = "$PUBKEY"
lan_cidr         = "$LAN_CIDR"

db_password            = "$(gen_pw)"
grafana_admin_password = "$(gen_pw)"
exporter_password      = "$(gen_pw)"
EOF
  echo "  생성 — $TFVARS (비밀번호 3종은 랜덤 생성)"
fi

cat <<EOF

준비 완료. 다음:

  terraform -chdir=terraform init
  terraform -chdir=terraform apply
  ./scripts/99-verify.sh

Grafana admin 비밀번호는 $TFVARS 에 있다:
  grep grafana_admin_password "$TFVARS"
EOF
