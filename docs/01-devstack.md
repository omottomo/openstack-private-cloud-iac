# 1. DevStack 설치 — PC 한 대를 미니 클라우드로

> PC 한 대를 "미니 클라우드 데이터센터"로 만드는 단계. **DevStack**은 OpenStack의 핵심
> 컴포넌트를 한 대의 머신에 자동으로 설치·설정해 주는 공식 스크립트다. 이 단계가 끝나면
> 웹 브라우저에서 AWS 콘솔과 비슷한 관리 화면(Horizon)에 로그인할 수 있게 된다.

| 컴포넌트 | 역할 (비유) |
|---|---|
| Keystone | 인증 — 모든 요청의 로그인/권한 담당 (경비실) |
| Nova | VM 생성/관리 (서버 임대 창구) |
| Neutron | 가상 네트워크/라우터/방화벽 (네트워크 팀) |
| Glance | VM의 원본 OS 이미지 보관 (설치 CD 보관함) |
| Cinder | VM에 붙이는 추가 디스크 (외장하드 대여소) |
| Horizon | 웹 대시보드 (관리자 콘솔 화면) |

---

## 1-1. 사전 확인 — 하드웨어/OS

설치가 30분~1시간 걸리기 때문에, 조건 미달을 설치 도중에 발견하면 그 시간을 통째로 잃는다.
OpenStack은 "PC 안에 가상 컴퓨터를 여러 대 만드는" 소프트웨어이므로 (1) VM에게 나눠줄
RAM/디스크가 충분한지, (2) CPU가 가상화 기능(VT-x/AMD-V)을 지원하고 켜져 있는지를 먼저 본다.
하나라도 미달이면 설치는 되더라도 VM 생성 단계에서 실패한다.

```bash
free -h                              # 전체/사용 가능 RAM → 16GB 이상 권장
df -h /                              # 루트 디스크 여유 → 60GB 이상
egrep -c '(vmx|svm)' /proc/cpuinfo   # 가상화 플래그(vmx=Intel, svm=AMD) 개수 → 0보다 크면 지원
lsmod | grep kvm                     # 커널 kvm 모듈 → 안 나오면 BIOS에서 VT-x/AMD-V 활성화 필요
lsb_release -a                       # Ubuntu 22.04 LTS 권장 (DevStack 공식 지원 대상)
```

> **kvm이 뭔가?** 리눅스에 내장된 가상화 엔진. OpenStack(정확히는 Nova)이 VM을 만들 때
> 실제로 일을 하는 건 kvm이다. 이 모듈이 없으면 VM이 소프트웨어 에뮬레이션으로 돌아가
> 견딜 수 없이 느려진다.

**실측 환경**: RAM 16GB, 디스크 여유 97GB, vCPU 8, Ubuntu 22.04 LTS, NIC 1개(`enp2s0`).

## 1-2. 사전 확인 — 네트워크

이 구성의 뼈대는 **집 공유기 LAN(192.168.0.0/24)을 OpenStack의 "외부 네트워크"로 그대로
쓰는 것**이다. VM에 부여할 **Floating IP**(외부에서 VM에 접속할 때 쓰는 LAN상의 IP)를
공유기가 다른 기기에 나눠주는 DHCP 범위와 **겹치지 않게** 미리 정해둬야 한다. 겹치면
스마트폰이 받아간 IP를 VM도 쓰겠다고 나서서 IP 충돌이 난다.

공유기 관리 페이지에서 확인·설정한 값:

| 항목 | 값 | 이유 |
|---|---|---|
| 공유기 DHCP 할당 범위 | `192.168.0.2 ~ 192.168.0.199` | 기존 기기들이 쓰는 대역 |
| Floating IP 대역 | `192.168.0.200 ~ 192.168.0.220` | DHCP 범위 **밖**에서 연속 20개 |
| 호스트 PC 고정 IP | `192.168.0.67` (MAC 기반 DHCP 예약) | 재부팅마다 바뀌면 설정 파일과 실제가 어긋나 전부 깨진다 |
| 공유기 "AP 격리" | 꺼짐 확인 | 켜져 있으면 노트북 → VM 접속이 안 되는데 원인 찾기가 매우 어렵다 |

AP 격리 확인은 노트북(WiFi)에서 `ping 192.168.0.67`이 되는지로 충분하다.

## 1-3. 사전 확인 — NIC 이름

`local.conf`에 "어느 랜카드를 외부 통신용으로 쓸지"를 정확한 이름으로 적어야 한다.

```bash
ip -br addr    # 호스트 IP가 붙어 있는 인터페이스 이름을 기록
# enp2s0  UP  192.168.0.67/24 ...
```

## 1-4. stack 유저 생성

DevStack 설치 스크립트(`stack.sh`)는 root가 아닌 **일반 유저**로 실행하도록 설계돼 있다.
root로 실행하면 중간에 권한 문제로 실패한다.

```bash
sudo useradd -s /bin/bash -d /opt/stack -m stack                        # 홈이 /opt/stack인 stack 유저 생성
sudo chmod +x /opt/stack                                                # 다른 서비스가 /opt/stack 안으로 들어갈 수 있게
echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack    # 설치 중 필요한 sudo를 비밀번호 없이
sudo -u stack -i                                                        # 이후 명령은 전부 stack 유저로
```

## 1-5. DevStack 다운로드

반드시 **stable 브랜치**를 지정한다. 기본값 master는 개발자들이 실시간으로 수정 중인
브랜치라, 받는 시점에 따라 그냥 깨져 있을 수 있다.

```bash
git clone https://opendev.org/openstack/devstack -b stable/2025.1
cd devstack
```

설치 전 <https://releases.openstack.org> 에서 현재 maintained 상태인 최신 릴리스를 확인하고
브랜치명을 결정한다.

## 1-6. local.conf 작성

`local.conf`는 DevStack의 **유일한 설정 파일**이다. "관리자 비밀번호는 무엇으로, 어느
랜카드로, 어느 IP 대역을 VM 외부 접속용으로 쓸지"만 적으면 `stack.sh`가 나머지 수백 개
설정을 알아서 채운다.

```ini
[[local|localrc]]
ADMIN_PASSWORD=<ADMIN_PASSWORD>       # Horizon/CLI 관리자(admin) 로그인 비밀번호
DATABASE_PASSWORD=$ADMIN_PASSWORD     # 내부 DB(MariaDB) 비밀번호 — 편의상 동일하게
RABBIT_PASSWORD=$ADMIN_PASSWORD       # 내부 메시지 큐(RabbitMQ) 비밀번호
SERVICE_PASSWORD=$ADMIN_PASSWORD      # 각 컴포넌트가 Keystone에 로그인할 때 쓰는 비밀번호

# ---- 네트워크 (1-2, 1-3에서 확인한 값) ----
HOST_IP=192.168.0.67                  # 이 PC의 고정 IP
PUBLIC_INTERFACE=enp2s0               # 실제 NIC 이름
FLOATING_RANGE=192.168.0.0/24         # "외부 네트워크" = 집 LAN 전체 대역
Q_FLOATING_ALLOCATION_POOL=start=192.168.0.200,end=192.168.0.220  # VM에 나눠줄 범위 (DHCP 범위 밖!)
PUBLIC_NETWORK_GATEWAY=192.168.0.1    # 공유기 IP (VM이 외부로 나갈 때 거치는 관문)

# ---- 리소스 ----
GIT_BASE=https://opendev.org          # 소스 받을 서버 (기본 GitHub보다 안정적)
VOLUME_BACKING_FILE_SIZE=30G          # Cinder가 볼륨을 만들 때 쓸 저장 공간 크기
```

> **이 설정의 핵심 아이디어**: `FLOATING_RANGE`를 집 LAN 대역으로 잡으면 OpenStack이 만드는
> "외부(public) 네트워크"가 곧 집 LAN이 된다. 그래서 노트북에서 VM의 Floating IP로 바로
> 접속할 수 있다. 클라우드 밖의 사용자가 서비스에 접근하는 구조를 1대 규모로 재현한 것.

**주의 1 — 설치 중 네트워크 단절.** `PUBLIC_INTERFACE`로 지정한 랜카드가 가상 스위치(br-ex)에
편입되는 순간 호스트 네트워크가 끊길 수 있다. **SSH로 설치하지 말고 PC 앞에 앉아 로컬
콘솔에서 실행할 것.**

**주의 2 — 아웃바운드 블랙홀** ([troubleshooting #5](troubleshooting.md)). DevStack은
`PUBLIC_NETWORK_GATEWAY`로 지정한 IP를 br-ex에 **직접 부여**한다. 이 구성처럼 실제 공유기
IP를 지정하면 서버가 게이트웨이를 사칭하게 되어 **설치 후 서버의 인터넷 아웃바운드가 전면
차단**된다(LAN 내부 통신은 정상이라 알아채기 어렵다). `stack.sh`가 마지막에 자동 실행하는
`local.sh`로 상쇄한다:

```bash
# devstack/local.sh  (chmod +x 필요)
sudo ip addr del 192.168.0.1/24 dev br-ex 2>/dev/null || true
```

## 1-7. 설치 실행

```bash
./stack.sh    # 패키지 설치, 소스 클론, 서비스 기동까지 전자동. 30분~1시간
```

실패하면 **재실행 전에 반드시 정리한다.** dirty 재실행은 매번 다른 에러를 만들어 진단
시간을 태운다 ([troubleshooting #3](troubleshooting.md)):

```bash
./unstack.sh && ./clean.sh
sudo systemctl stop "devstack@*"    # unstack이 놓친 좀비 프로세스까지 확실히 정지
./stack.sh
```

## 1-8. 검증

"설치 스크립트가 끝났다"와 "클라우드가 실제로 동작한다"는 다르다. CLI와 웹 양쪽에서
확인한다.

```bash
source openrc admin admin     # admin 인증 정보를 현재 셸에 로드
openstack service list        # keystone/nova/neutron/glance/cinder/placement가 보이면 정상
openstack hypervisor list     # 이 PC가 VM을 돌릴 하이퍼바이저로 등록됐는지
```

- 호스트 브라우저에서 `http://<HOST_IP>/dashboard` (Horizon) 로그인
- 노트북에서도 같은 주소로 접속 — LAN에서 접근 가능함을 확인
- (호스트가 VM이라면) **이 시점에 스냅샷 생성** — DevStack은 재부팅에 취약해서, 잘 되는
  시점을 저장해 두면 사고 시 되돌릴 수 있다

## 자주 만나는 문제

| 증상 | 우선 확인 |
|---|---|
| `stack.sh` 실패 | 마지막 에러 50줄, 디스크/RAM 여유(`df -h`, `free -h`), 브랜치가 stable인지 |
| 설치 중 네트워크 끊김 | 정상 현상일 수 있음(br-ex 편입 순간) — 로컬 콘솔이면 그대로 진행됨 |
| 클린 재설치했는데 같은 에러 | 초기화 범위 밖에서 생존한 프로세스 의심 — `sudo systemctl stop "devstack@*"` ([#3](troubleshooting.md)) |
| DNS 해석 전면 실패 | systemd-resolved 스텁 고장 — `resolvectl status`의 `Current Scopes` 확인 ([#1](troubleshooting.md)) |
| `unstack.sh` 후 서버 네트워크 단절 | 물리 NIC 설정 미복원 — 콘솔에서 `ip link set <nic> up && netplan apply` ([#2](troubleshooting.md)) |

**다음**: [2. 인프라 구성과 IaC 전환](02-infrastructure.md)
