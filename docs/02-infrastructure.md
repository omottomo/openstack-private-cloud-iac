# 2. 인프라와 서비스 — Terraform + cloud-init

빈 클라우드 위에 게시판 서비스를 올린다. OpenStack 리소스(네트워크·SG·VM·볼륨·Floating IP)는
**Terraform**이, VM 내부 설정(볼륨 마운트, MySQL, Flask 앱)은 **cloud-init**이 담당한다.
현업에서 가장 보편적인 조합이다.

`terraform apply` 한 번으로 빈 클라우드에서 게시판과 모니터링 대시보드까지 올라오고,
`destroy` → `apply`로 언제든 동일하게 재구축된다. 이 재현 가능성이 수동 구축 대비 IaC의 핵심 가치다.

> 처음에는 전부 `openstack` CLI로 손으로 만들었다. 그 과정에서 리소스 생성 순서를 틀려
> 실패했고([#6](troubleshooting.md#6-vm-생성-시-no-network-found-for-internal-net)),
> 그게 Terraform 전환의 직접적인 동기가 됐다. 의존 관계를 코드가 계산하면 순서를 틀릴 수 없다.

---

## 2.1 전체 구성

```
                     집 LAN (192.168.0.0/24) = OpenStack의 "외부(public) 네트워크"
                                    │
                          Floating IP .200~.220
                    ┌───────────────┴───────────────┐
                    │                               │
              ┌─────▼─────┐                   ┌─────▼──────┐
              │  web-vm   │                   │monitoring-vm│
              │ Flask :80 │                   │ Grafana:3000│
              │ node_exp  │                   │ Prom   :9090│
              └─────┬─────┘                   └─────┬──────┘
                    │      internal-net 10.0.10.0/24│
                    └───────────────┬───────────────┘
                                    │
                              ┌─────▼─────┐
                              │   db-vm   │  Floating IP 없음
                              │ MySQL:3306│  = 밖에서 안 보인다
                              │ node_exp  │
                              └─────┬─────┘
                                    │
                            Cinder 볼륨 10GB
                            /var/lib/mysql
```

| 파일 | 담당 |
|---|---|
| `terraform/network.tf` | internal-net, subnet, router, 각 VM의 포트 |
| `terraform/security.tf` | web-sg / db-sg / monitoring-sg |
| `terraform/compute.tf` | Glance 이미지, 키페어, web-vm / db-vm, web의 Floating IP |
| `terraform/storage.tf` | Cinder 볼륨 + db-vm 부착 |
| `terraform/monitoring.tf` | monitoring-vm + Floating IP |
| `terraform/identity.tf` | openstack-exporter용 Keystone 계정과 롤 |
| `terraform/templates/*.tftpl` | 각 VM의 cloud-init |

---

## 2.2 네트워크

DevStack이 이미 만들어 둔 public 네트워크는 **생성이 아니라 조회**(`data`)로 가져온다.
Terraform이 관리하지 않는 기존 리소스를 참조하는 표준 패턴이다.

```hcl
data "openstack_networking_network_v2" "public" {
  name = var.external_network_name    # "public"
}
```

내부 네트워크 `10.0.10.0/24`를 만들고, 라우터로 public에 연결한다. 라우터가 있어야 VM이
인터넷으로 나갈 수 있고(패키지 설치에 필요) Floating IP도 이 라우터를 통해 동작한다.
서브넷의 `dns_nameservers`를 빼먹으면 VM에서 `apt install`이 안 된다.

VM은 네트워크에 직접 붙이지 않고 **포트(NIC)를 명시적으로 만들어** 붙인다. 그래야
Security Group을 포트에 걸 수 있고, db-vm에 고정 IP를 줄 수 있다.

```hcl
resource "openstack_networking_port_v2" "db" {
  name               = "db-port"
  network_id         = openstack_networking_network_v2.internal.id
  security_group_ids = [openstack_networking_secgroup_v2.db.id]
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.internal.id
    ip_address = var.db_fixed_ip      # 10.0.10.10 — 재생성해도 항상 같다
  }
}
```

db-vm의 IP를 고정한 이유: 수동 구축 때는 VM을 다시 만들 때마다 IP가 바뀌어서 웹 앱의
DB 접속 주소를 매번 고쳐야 했다. 고정해 두면 그 고리가 끊긴다.
(실제로는 web-vm의 cloud-init에 Terraform이 db 포트의 IP를 주입하므로 고정이 없어도 동작하지만,
사람이 디버깅할 때 주소가 항상 같은 편이 훨씬 낫다.)

## 2.3 Security Group — 이 구성의 보안 설계

Security Group은 **VM 단위 방화벽**이다. 기본값이 "들어오는 트래픽 전부 차단"이므로 필요한
포트만 뚫는다. 설계 의도는 하나다: **db-vm을 외부에서 절대 직접 건드릴 수 없게 한다.**

| 그룹 | 허용 | 출발지 |
|---|---|---|
| web-sg | 22, 80 | LAN 대역 |
| web-sg | 9100 (node_exporter) | **monitoring-sg 소속 VM** |
| db-sg | 3306 | **web-sg 소속 VM** |
| db-sg | 22 | 내부망 대역만 (관리용) |
| db-sg | 9100 | **monitoring-sg 소속 VM** |
| monitoring-sg | 22, 3000, 9090 | LAN 대역 |

굵게 표시한 것이 핵심이다. 출발지를 IP가 아니라 **보안 그룹 소속**으로 지정한다.

```hcl
resource "openstack_networking_secgroup_rule_v2" "db_mysql" {
  direction         = "ingress"
  protocol          = "tcp"
  port_range_min    = 3306
  port_range_max    = 3306
  remote_group_id   = openstack_networking_secgroup_v2.web.id   # IP가 아니라 그룹
  security_group_id = openstack_networking_secgroup_v2.db.id
}
```

web-vm의 IP가 바뀌어도 규칙이 그대로 유효하고, web-sg를 단 VM이 늘어나면 자동으로 허용된다.
AWS 보안 그룹의 그룹 참조와 같은 개념이다.

db-vm에는 Floating IP를 주지 않는다. 그래서 접속 경로는 항상
`내 PC → (Floating IP) web-vm → (내부 IP) db-vm`이다. 이 "web-vm을 발판 삼는 구조" 자체가
private 네트워크 경계가 실재한다는 증거다.

## 2.4 스토리지

Cinder 볼륨 10GB를 만들어 db-vm에 붙이고, VM 안에서 `/var/lib/mysql`에 마운트한 **뒤에**
MySQL을 설치한다. 순서가 중요하다 — 마운트 후에 설치해야 DB 초기 데이터가 볼륨 위에 생성된다.
그래야 "VM을 지워도 데이터는 볼륨에 남는다"가 성립한다.

## 2.5 cloud-init — VM 내부 설정

cloud-init은 VM 첫 부팅 시 1회 실행되는 초기화 에이전트다. Terraform이 `templatefile()`로
값을 주입한다.

**db-vm** ([`templates/db-init.yaml.tftpl`](../terraform/templates/db-init.yaml.tftpl))

```yaml
runcmd:
  - for i in $(seq 1 60); do [ -b /dev/vdb ] && break; sleep 5; done   # 볼륨 부착 대기
  - blkid /dev/vdb || mkfs.ext4 /dev/vdb                               # 이미 포맷됐으면 건드리지 않는다
  - mount /dev/vdb /var/lib/mysql
  - echo '/dev/vdb /var/lib/mysql ext4 defaults,nofail 0 2' >> /etc/fstab
  - apt-get install -y mysql-server                                    # 마운트 후에 설치
  - sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' ...             # 실제 차단은 db-sg가 담당
```

볼륨 대기 루프와 `blkid` 가드가 있는 이유: cloud-init은 볼륨 부착보다 먼저 실행될 수 있고,
가드 없이 `mkfs`를 돌리면 재부팅 때마다 DB가 날아간다.

**web-vm** ([`templates/web-init.yaml.tftpl`](../terraform/templates/web-init.yaml.tftpl)) —
Flask 게시판 앱과 systemd 유닛을 심는다. DB 주소는 Terraform이 db 포트의 실제 IP를 주입한다.

```hcl
user_data = templatefile("${path.module}/templates/web-init.yaml.tftpl", {
  db_host     = openstack_networking_port_v2.db.all_fixed_ips[0]
  db_password = var.db_password
})
```

이 참조 한 줄이 곧 의존 관계 선언이다 — Terraform은 db 포트를 먼저 만든 뒤 web-vm을 만든다.
순서를 사람이 기억할 필요가 없다.

**monitoring-vm** ([`templates/monitoring-init.yaml.tftpl`](../terraform/templates/monitoring-init.yaml.tftpl)) —
Docker로 Prometheus + Grafana + openstack-exporter를 띄운다. 수집 대상 IP도 Terraform이 주입한다.

---

## 2.6 모니터링 — 두 개의 시야

Prometheus + Grafana는 OpenStack 운영에서 사실상 표준 조합이다. 여기서는 시야를 둘로 나눴다.

**테넌트 시야** — VM 안에서 본 상태. web-vm/db-vm의 node_exporter(9100)가 CPU·메모리·디스크를
노출하고 Prometheus가 긁어간다. "내 서버가 잘 돌고 있나"의 관점.

**오퍼레이터 시야** — 클라우드를 운영하는 쪽에서 본 상태. `openstack-exporter`가 Keystone에
로그인해 OpenStack API를 긁어 서비스 상태와 용량을 메트릭으로 노출한다. "하이퍼바이저에 아직
VM을 몇 대 더 올릴 수 있나", "nova-compute가 살아 있나"의 관점.

이 exporter 계정은 Terraform이 만든다. admin을 그대로 쓰지 않고 `reader` 롤만 준 전용 계정이다.

```hcl
resource "openstack_identity_user_v3" "exporter" {
  name     = "prometheus-exporter"
  password = var.exporter_password
}
resource "openstack_identity_role_assignment_v3" "exporter" { ... }
```

> exporter를 붙일 때 컨테이너가 아예 뜨지 않아 한참 헤맸는데, 원인은 인증이 아니라
> **같은 이름의 cloud-init 템플릿이 두 벌 있어서 Terraform이 읽지 않는 쪽을 고쳤던 것**이었다.
> apply는 계속 성공했다 — 성공적으로 옛 설정을 재현하면서.
> [#8](troubleshooting.md#8-openstack-exporter-컨테이너가-아예-뜨지-않음)

---

## 2.7 배포

```bash
./scripts/02-bootstrap.sh                      # 이미지·키페어·clouds.yaml·tfvars 준비
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

인증 정보는 코드에 없다. `providers.tf`는 `cloud = "devstack-admin"` 한 줄뿐이고, 실제 자격증명은
DevStack이 만들어 둔 `~/.config/openstack/clouds.yaml`에서 읽는다. OpenStack 표준 방식이다.

```hcl
provider "openstack" {
  cloud = "devstack-admin"
}
```

`terraform.tfvars`(비밀번호 평문)와 `clouds.yaml`, `tfstate`는 `.gitignore`로 커밋이 차단돼 있다.

---

## 2.8 CI 파이프라인

IaC 코드에 대한 검사를 자동화한다. 잡은 넷:

| 잡 | 잡는 것 |
|---|---|
| `terraform fmt -check` | 포맷 |
| `tflint` | 품질 결함 (변수 타입 누락 등) |
| `terraform validate` | 문법·타입 |
| `tfsec` | 보안 설정 |

**`apply`는 파이프라인에 두지 않는다.** DevStack 호스트는 LAN 안에 있어 CI 러너가 도달할 수
없고, 클라우드 자격증명을 CI에 두고 싶지도 않다. 검사까지가 CI의 몫이고 적용은 사람이 한다.

원래는 노트북에 GitLab CE + docker-executor 러너를 띄워 로컬에서 돌렸다. 저장소를 GitHub로
옮기면서 같은 잡 넷을 GitHub Actions로 이전했다
([`.github/workflows/terraform.yml`](../.github/workflows/terraform.yml)).

파이프라인을 붙이면서 두 가지를 배웠다:

- **첫 실행은 전부 실패했다.** 검사 로직이 아니라 도구 이미지의 ENTRYPOINT 문제였다.
  `hashicorp/terraform` 같은 단일 바이너리 이미지는 러너가 넘기는 셸 명령을 terraform의
  하위 명령으로 오해한다. [#9](troubleshooting.md#9-ci-첫-파이프라인-전면-실패--도구-이미지의-entrypoint)
- **`validate` 통과는 코드가 좋다는 뜻이 아니다.** tflint를 붙인 첫 실행에서 변수 9개의 타입
  누락이 즉시 나왔다. 사람이 3일간 못 본 결함이다.
  [#10](troubleshooting.md#10-tflint가-변수-9개의-타입-누락으로-job-실패)

그리고 형상관리 자체에 대해 하나 더. 한동안 저장소의 IaC 코드는 **호스트에서 가져온 것이 아니라
문서에서 복원한 것**이었고, 실제로 31줄 차이가 있었다. 그대로 apply했으면 모니터링 기능이
통째로 사라지는 회귀가 났을 것이다. 문서는 코드의 사본이지 원본이 아니다.
[#11](troubleshooting.md#11-형상관리된-iac가-실환경과-달랐다)

---

다음: [3. 검증](03-verification.md)
