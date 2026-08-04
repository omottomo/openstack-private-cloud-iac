# 3. 모니터링 — 두 가지 시야

> 구축만 하고 끝내면 "만들어봤다"에서 멈춘다. 운영에 필요한 최소한인 **관측**까지 같은
> IaC 패턴으로 얹었다. monitoring-vm 한 대를 Terraform으로 추가하고, cloud-init이 Docker로
> Prometheus/Grafana/openstack-exporter를 띄운다.

---

## 3-1. 모니터링의 두 가지 시야

| 시야 | 질문 | 데이터 출처 |
|---|---|---|
| **테넌트** | 내 VM/서비스가 건강한가 | VM 안의 node_exporter(:9100) |
| **오퍼레이터** | 클라우드 자체가 건강한가 — nova/neutron 서비스 생존, 하이퍼바이저 여유 용량 | OpenStack admin API |

핵심 통찰: **시야를 가르는 것은 "무엇을 보느냐"(데이터 출처)이지, 수집기가 어디서 도느냐가
아니다.** 오퍼레이터 시야의 데이터는 전부 OpenStack admin API가 주는 것이므로, 그 API를 긁는
openstack-exporter는 어디서 돌든 같은 데이터를 얻는다. 그래서 monitoring-vm 안에 컨테이너
하나로 추가할 수 있고, 덕분에 **오퍼레이터 시야까지 Terraform 관리 범위에 들어온다.**

## 3-2. 구성

```
┌──────────────────────── DevStack 호스트 (서버 1대) ────────────────────────┐
│                                                                          │
│  컨트롤 플레인: nova-api / neutron / keystone / cinder ...                  │
│       ▲                          ⚠ 호스트 OS 자체는 감시 안 됨 (한계 ①)      │
│       │ admin API로 조회                                                   │
│  ─────┼────────────── KVM/libvirt (데이터 플레인) ────────────────────────  │
│       │                                                                   │
│  ┌────┴────────────────────────┐   ┌──────────────┐   ┌──────────────┐    │
│  │ monitoring-vm               │   │ web-vm       │   │ db-vm        │    │
│  │  Prometheus ────────────────┼──▶│ node_exporter│   │ node_exporter│    │
│  │  Grafana        긁는다(9100) │───┼──────────────┼──▶│    (9100)    │    │
│  │  openstack-exporter          │   │ Flask 앱     │   │ MySQL        │    │
│  └─────────────────────────────┘   └──────────────┘   └──────────────┘    │
│         ⚠ 호스트가 죽으면 같이 죽음 (한계 ②)                                  │
│           단, nova-api 등 서비스만 죽은 경우엔 살아서 "DOWN"을 관측 가능 ✅      │
└──────────────────────────────────────────────────────────────────────────┘
```

- **Prometheus / Grafana** — [`templates/monitoring-init.yaml.tftpl`](../templates/monitoring-init.yaml.tftpl)이
  Docker Compose로 띄운다. 이미지 버전을 고정했다 (Terraform provider 버전을 고정하는 것과 같은 이유).
  Grafana 데이터소스는 파일 프로비저닝으로 자동 등록 — UI 수작업 없음.
- **node_exporter** — web/db의 cloud-init에서 apt로 설치. 접근은 SG가 통제한다:
  9100은 **monitoring-sg 소속 VM에서만** 허용 (db-sg의 3306 규칙과 같은 그룹 기반 패턴).
- **openstack-exporter** — [`identity.tf`](../identity.tf)가 전용 Keystone 계정
  (`prometheus-exporter`)을 만들고, exporter 컨테이너가 그 계정으로 admin API를 긁는다.
  포트를 밖으로 열지 않는다 — Prometheus가 같은 compose 네트워크 안에서 서비스 이름으로 접근하므로
  SG 규칙이 아예 필요 없다.

## 3-3. 설계 판단 — 왜 감시자를 클라우드 안에 뒀나

프로덕션 OpenStack의 원칙은 **모니터링은 장애 반경(blast radius) 밖에 둔다**이다. 별도 물리
서버에서 Prometheus/Grafana/Alertmanager를 돌려, 클라우드가 통째로 죽어도 관측과 알림이
살아 있게 한다. 이 프로젝트는 그 원칙을 지키지 못했다. 왜 그런 선택을 했는지가 이 절이다.

### ① IaC 경계선: Terraform은 "API 리소스로 표현되는 것"만 다룬다

Terraform의 OpenStack provider는 OpenStack **API를 호출하는 클라이언트**다. VM·네트워크·SG처럼
API 리소스로 존재하는 것만 선언할 수 있고, **호스트 OS의 패키지·systemd 유닛은 API에 존재하지
않으므로 관리할 수 없다.**

- **openstack-exporter** — admin API를 긁는 클라이언트일 뿐이므로 어디서든 돌 수 있다
  → monitoring-vm 안 컨테이너로 넣으면 **Terraform 관할** ✅
- **호스트의 node_exporter / libvirt_exporter** — DevStack 호스트에 직접 설치해야 한다
  → Terraform 불가. 범위에서 제외했다. `null_resource` + `remote-exec`로 밀어넣는 방법은
  상태 추적이 안 되고 destroy로 정리되지 않아 선언성이 사라지므로 채택하지 않았다.

이 경계는 현업의 분업과 같은 자리에 그어진다. 프로덕션은 도구가 3층으로 갈린다 — 1층 물리
노드 프로비저닝(MAAS/Ironic), 2층 OpenStack 배포 + 오퍼레이터 모니터링(Kolla-Ansible 등),
3층 테넌트 리소스(Terraform). exporter류는 2층에서 배포 도구가 플래그 하나로 깐다. 이 프로젝트는
1~2층을 DevStack 설치로 갈음하고 3층을 코드화한 셈이다.

### ② 왜 VM 안이어도 관측이 되나

"감시 대상 안에 감시자를 두면 같이 죽지 않나?" — OpenStack에서 **nova-api가 죽어도 이미 떠
있는 VM은 계속 돈다.** VM을 실제로 돌리는 것은 호스트의 KVM/libvirt(데이터 플레인)이고,
nova/neutron/keystone(컨트롤 플레인)은 "새로 만들거나 바꾸는" 역할만 하기 때문이다. 관제탑이
꺼져도 비행 중인 비행기는 계속 난다.

- **컨트롤 플레인 서비스 사망** (오퍼레이터 모니터링이 잡아야 할 장애의 대부분)
  → monitoring-vm은 살아서 "서비스 DOWN"을 **관측할 수 있다** ✅
- **호스트 자체 사망** (전원, 커널 패닉) → monitoring-vm도 같이 죽는다 ⚠

### ③ 단일 노드에는 "밖"이 없다

호스트 사망 시나리오를 커버하려고 Prometheus를 호스트 위로 옮겨도, **호스트가 죽으면 호스트
위의 Prometheus도 똑같이 죽는다.** 현업의 해법은 "호스트에 두기"가 아니라 "**다른 서버**에
두기"인데 서버가 1대라 그 선택지가 없다.

| 위치 | 얻는 것 | 잃는 것 |
|---|---|---|
| VM 안 (채택) | 전부 Terraform 코드 관리, 재현 가능 | 호스트 사망 시 같이 죽음 |
| 호스트 위 | — (호스트 사망 시 어차피 같이 죽음) | IaC 밖으로 나감, 수동 설치 |

한계는 어느 쪽이든 같으므로 IaC 이점이 남는 쪽을 택했다.

**의도적으로 포기한 것**: ① 호스트 자체의 재현성·감시 ② 모니터링 독립성(감시 대상 밖 배치 —
단일 노드에서는 구조적으로 불가능) ③ Alertmanager 알림·Loki 로그 수집·Thanos 장기 보존.

## 3-4. 적용

cloud-init은 첫 부팅에만 실행되므로, 모니터링 설정을 바꿨다면 monitoring-vm만 갈아끼운다.

```bash
terraform plan     # identity 리소스 + monitoring-vm replace만 뜨는지 확인
terraform apply -replace=openstack_compute_instance_v2.monitoring
                   # web/db VM과 게시판 데이터는 무사
```

`Plan:`에 web-vm/db-vm이 **포함되지 않아야** 한다. 포함돼 있으면 apply 전에 중단한다.
"일부 리소스만 안전하게 교체"가 성립하는 것이 IaC의 실익이다.

## 3-5. 실행 결과 — 계획과 달랐던 것

**① 롤은 `admin`을 썼다.** 원칙은 읽기 전용 `reader`지만, nova의 서비스 목록
API(`os-services`)는 기본 정책이 admin 전용이라 `reader`로는 `openstack_nova_agent_state`가
나오지 않는다. **모니터링 계정이 admin 권한을 갖는 것 자체가 한계**다.

**② `openstack_nova_free_disk_bytes`는 없다.** openstack-exporter 1.7.0이 내보내는 51개
지표에 하이퍼바이저 계열이 없다. 용량은 **Placement 지표로 본다** — 이쪽이 더 정확한 출처다
(스케줄러가 실제로 참조하는 재고 정보이므로):

```promql
openstack_placement_resource_total                                              # 총량 (VCPU / MEMORY_MB / DISK_GB)
openstack_placement_resource_usage                                              # 사용량
100 * openstack_placement_resource_usage / openstack_placement_resource_total   # 사용률 %
```

실측: DISK_GB 60/97 (61.9%), MEMORY_MB 6144/15933 (38.6%), VCPU 3/8 (37.5%).

**③ 대시보드는 커뮤니티 import 대신 직접 정의했다.** 수집되는 지표를 먼저 확인한 뒤 그 지표만으로
패널을 짰다 — 커뮤니티 대시보드는 다른 배포판(하이퍼바이저 지표 등)을 전제해 빈 패널이 생기기
쉽다. 정의는 [`grafana-operator-dashboard.json`](grafana-operator-dashboard.json)에 있다
(패널 10개 — 서비스 API 상태, nova/neutron 에이전트 상태 표, Placement 사용률 게이지, 자원 추이,
테넌트별 vCPU, VM 상태).

```bash
# UI Import 대신 API로 등록 — 대시보드도 코드로 관리
curl -u admin:<GRAFANA_ADMIN_PASSWORD> -H "Content-Type: application/json" \
  -X POST http://<monitoring_fip>:3000/api/dashboards/db \
  -d @docs/grafana-operator-dashboard.json
# 주의: JSON 안의 데이터소스 uid는 이 환경의 프로비저닝 결과값.
# monitoring-vm을 새로 만들면 /api/datasources로 uid를 확인해 치환한다.
```

**④ 적용 과정에서 장애 1건.** 수정을 `templatefile()`이 참조하지 않는 중복 템플릿에 넣어
exporter 컨테이너가 아예 생성되지 않았다 → [troubleshooting #8](troubleshooting.md).
교훈 둘: 템플릿 수정 전에 `grep -n templatefile *.tf`로 실제 참조 경로를 확인할 것,
그리고 **apply 성공은 의도한 변경이 반영됐다는 뜻이 아니라는 것**.

## 3-6. 한계

| 항목 | 내용 |
|---|---|
| 롤 권한 | exporter 계정이 `admin` — 최소 권한 원칙 위반 |
| 비밀번호 평문 | exporter 비밀번호가 tfstate와 VM 내 `clouds.yaml`에 평문으로 남음 (Vault/SOPS 자리) |
| 호스트 감시 부재 | 호스트 OS·libvirt 지표 없음 (§3-3 ①) |
| 모니터링 독립성 | 감시 대상 안에 위치 (§3-3 ③) |
| 메모리 | monitoring-vm(2GB)에 컨테이너 3개 — `docker stats`로 여유 확인 필요 |

## 자주 만나는 문제

| 증상 | 우선 확인 |
|---|---|
| Grafana(3000)/Prometheus(9090) 접속 불가 | Docker 이미지 pull이 오래 걸림 — VM 안에서 `sudo docker ps`, 그다음 monitoring-sg 규칙 |
| Prometheus targets DOWN | ① node_exporter 설치 미완 (`curl localhost:9100/metrics`) ② web-sg/db-sg의 9100 규칙(remote_group=monitoring-sg) 누락 |
| openstack 잡만 DOWN | exporter 컨테이너 존재 확인 → `clouds.yaml` 인증 정보 → Keystone 도달성(`curl <auth_url>`) |
| apply 후 VM이 느림 | 호스트 메모리 부족 — VM 3대(6GB)가 부담이면 monitoring 리소스만 빼고 본체 2대로 |

**다음**: [4. 형상관리와 CI](04-ci.md)
