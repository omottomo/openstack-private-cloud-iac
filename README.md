# OpenStack Private Cloud — 로컬 PC 한 대로 구축한 사설 클라우드

[![terraform](https://github.com/omottomo/openstack-private-cloud-iac/actions/workflows/terraform.yml/badge.svg)](https://github.com/omottomo/openstack-private-cloud-iac/actions/workflows/terraform.yml)

집에 있는 PC 한 대에 **DevStack(OpenStack)** 을 직접 설치하고, 그 위에 VM 3대와
**게시판 웹서비스 + 모니터링 스택**을 Terraform으로 배포한 학습 프로젝트다.

클론해서 `00 → 01 → 02 → apply → 99` 순서로 실행하면 빈 PC에서 동작하는 서비스까지
전 과정이 재현된다.

---

## 왜 만들었나

OpenStack을 문서로 읽으면 "Nova는 컴퓨트, Neutron은 네트워크"까지는 안다. 그런데
**직접 설치해 보면 문서에 없는 것들이 나온다.**

- 물리 NIC을 가상 스위치에 편입시키는 순간 호스트 네트워크가 끊긴다
- 게이트웨이 IP를 잘못 지정하면 서버가 자기 자신을 게이트웨이로 알고 인터넷이 통째로 죽는다
- `terraform apply`가 성공해도 내 수정이 반영되지 않을 수 있다

이런 것들은 실제로 겪어야 알게 된다. 그 과정 전체를
[**트러블슈팅 기록 11건**](docs/troubleshooting.md)으로 남겼고, 이 저장소에서 가장 읽을 만한
부분이라고 생각한다.

---

## 아키텍처

![아키텍처](docs/architecture.svg)

```
                     집 LAN (192.168.0.0/24) = OpenStack의 "외부(public) 네트워크"
                                    │
                          Floating IP .200~.220
                    ┌───────────────┴───────────────┐
              ┌─────▼─────┐                   ┌─────▼───────┐
              │  web-vm   │                   │monitoring-vm│
              │ Flask :80 │                   │ Grafana:3000│
              └─────┬─────┘                   └─────┬───────┘
                    │      internal-net 10.0.10.0/24│
                    └───────────────┬───────────────┘
                              ┌─────▼─────┐
                              │   db-vm   │  Floating IP 없음
                              │ MySQL:3306│  = 밖에서 안 보인다
                              └─────┬─────┘
                              Cinder 볼륨 10GB
```

| 구성 요소 | 내용 |
|---|---|
| 호스트 | Ubuntu 22.04 LTS, 16GB RAM, 단일 노드 all-in-one |
| OpenStack | DevStack `stable/2025.1` — Keystone / Nova / Neutron / Glance / Cinder / Horizon |
| IaC | Terraform ≥ 1.5 + `terraform-provider-openstack` ~> 3.0 |
| VM 내부 | cloud-init |
| 모니터링 | Prometheus + Grafana + openstack-exporter (Docker) |
| CI | GitHub Actions — fmt / tflint / validate / tfsec |

**설계 의도는 하나다: db-vm을 외부에서 절대 직접 건드릴 수 없게 한다.**
db-vm에는 Floating IP가 없고, MySQL 3306은 **IP가 아니라 web-sg 보안 그룹 소속**에만 열려 있다.
web-vm의 IP가 바뀌어도 규칙은 그대로 유효하다.

집 LAN을 그대로 OpenStack의 public 네트워크로 선언했기 때문에, VM의 Floating IP가 곧 LAN상의
IP가 되고 같은 LAN의 노트북에서 브라우저로 바로 들어갈 수 있다. 그 대가로 치른 문제도 있다
([#5](docs/troubleshooting.md#5-br-ex가-공유기-ip를-사칭하여-서버-아웃바운드-전면-블랙홀)).

---

## 재현 방법

```bash
./scripts/00-precheck.sh                   # RAM/디스크/가상화/네트워크 점검
sudo ./scripts/01-install-devstack.sh      # DevStack 설치. 30~60분, 로컬 콘솔에서만
./scripts/02-bootstrap.sh                  # 이미지·SSH키·tfvars 준비
terraform -chdir=terraform init
terraform -chdir=terraform apply
./scripts/99-verify.sh                     # VM 3대 + 볼륨 + FIP + HTTP 응답 검증
```

> ⚠️ `01`은 **SSH로 실행하지 말 것.** 설치 중 랜카드가 가상 스위치 br-ex에 편입되는 순간
> 호스트 네트워크가 끊긴다. 스크립트도 실행 전에 경고하고 확인을 받는다.

네트워크 값(NIC, 호스트 IP, 게이트웨이, LAN 대역, Floating IP 범위)은 전부 자동 감지하며
환경변수로 덮어쓸 수 있다. `terraform.tfvars`는 `02`가 생성하고 비밀번호 3종은 랜덤이다.

| 파일/디렉터리 | 내용 |
|---|---|
| `scripts/` | 설치·부트스트랩·검증 |
| `terraform/` | OpenStack 리소스 정의 |
| `terraform/templates/` | 각 VM의 cloud-init |
| `docs/` | 설치기 · 설계 · 검증 · 트러블슈팅 |

---

## 결과

| | |
|---|---|
| ![네트워크 토폴로지](docs/images/network-topology.jpg) | ![게시판](docs/images/board-post-saved.jpg) |
| 내부망 · 라우터 · VM 3대 | 노트북에서 Floating IP로 접속한 게시판 |
| ![Prometheus](docs/images/prometheus-targets.jpg) | ![Grafana](docs/images/grafana-operator.jpg) |
| 수집 대상 전부 UP | 오퍼레이터 시야 대시보드 |

---

## 삽질 기록

전체 11건: [docs/troubleshooting.md](docs/troubleshooting.md)

**br-ex가 공유기 IP를 사칭해 아웃바운드가 통째로 죽었다**
([#5](docs/troubleshooting.md#5-br-ex가-공유기-ip를-사칭하여-서버-아웃바운드-전면-블랙홀))
LAN 내부는 멀쩡한데 인터넷만 안 되는 비대칭 장애. `ip -br addr` 한 줄에 답이 있었다 —
br-ex에 공유기 IP가 붙어 있었다. `local.sh`로 상쇄해 이제 재발하지 않는다.

**"클린 재설치했는데 같은 에러"의 진범은 좀비 프로세스였다**
([#3](docs/troubleshooting.md#3-재설치-시-neutron-초기-네트워크-생성-503))
unstack + clean 후에도 동일한 503. `ActiveEnterTimestamp`가 초기화 전 시각을 가리키고 있었다 —
neutron-api가 unstack의 정지를 빠져나가 살아남아 새 DB를 초기화하지 않은 것.

**apply는 계속 성공했는데 수정이 반영되지 않았다**
([#8](docs/troubleshooting.md#8-openstack-exporter-컨테이너가-아예-뜨지-않음))
같은 이름의 cloud-init 템플릿이 두 벌 있었고, Terraform이 읽지 않는 쪽을 고치고 있었다.
에러가 아니라 "성공적으로 옛 설정을 재현"한 것이라 출력만 봐서는 알 수 없었다.

---

## 한계

실습 규모라 의도적으로 축소한 것들이다. 표준 방식을 알고 남겨뒀다.

| 이 구성 | 표준 |
|---|---|
| Flask `app.run()`을 root로 80 포트 직접 구동 | gunicorn/uWSGI + nginx, 비특권 유저 |
| tfstate 로컬 파일 | Swift/S3 원격 백엔드 + 상태 잠금 |
| `terraform.tfvars` 평문 (커밋만 차단) | Vault / SOPS |
| 단일 노드 all-in-one | 컨트롤러 / 컴퓨트 / 네트워크 노드 분리, HA |
| 관리망·서비스망 미분리 | 관리망 · 서비스망 · 스토리지망 분리 |
| CI는 검사까지만 | 승인 게이트를 둔 apply 자동화 |

---

## 문서

- [1. DevStack 설치](docs/01-devstack.md) — 사전 점검, `local.conf`, 설치 중 만나는 함정
- [2. 인프라와 서비스](docs/02-infrastructure.md) — Terraform 리소스 설계, 보안 그룹, cloud-init, CI
- [3. 검증](docs/03-verification.md) — 무엇을 어떻게 확인했는가
- [트러블슈팅 11건](docs/troubleshooting.md) — 증상 → 가설 → 확인 → 근본 원인 → 해결
