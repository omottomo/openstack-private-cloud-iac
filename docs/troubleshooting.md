# 트러블슈팅 기록

DevStack을 로컬 PC에 올리고 게시판 서비스를 배포하기까지 실제로 겪은 장애 11건.
발생 즉시, 에러 메시지 원문 그대로 기록한 것을 정리했다. 기억으로 재구성한 글은
정확한 에러 메시지가 없어 쓸모가 없다.

**이 중 코드로 상쇄한 것들** — 같은 함정을 다시 밟지 않도록 저장소에 반영해 뒀다:

| 사건 | 반영된 곳 |
|---|---|
| [#2](#2-unstacksh-실행-후-서버-네트워크-완전-단절) 물리 NIC 미복원 | `scripts/01-install-devstack.sh` 실행 전 경고 + 확인 프롬프트 |
| [#5](#5-br-ex가-공유기-ip를-사칭하여-서버-아웃바운드-전면-블랙홀) br-ex 게이트웨이 사칭 | `scripts/local.sh.template` — stack.sh가 끝날 때마다 자동 상쇄 |
| [#10](#10-tflint가-변수-9개의-타입-누락으로-job-실패) 변수 타입 누락 | `.github/workflows/terraform.yml` tflint 잡 |
| [#11](#11-형상관리된-iac가-실환경과-달랐다) 코드 사본의 드리프트 | 실행되는 파일 자체를 저장소에 두는 것으로 해소 |

---

## #1 systemd-resolved 스텁 고장으로 DNS 해석 실패

**단계**: DevStack 설치, stack.sh 실행 중

**현상**: stack.sh가 horizon 저장소 clone 단계에서 실패. 같은 시점에 서버 안에서 돌리던
다른 도구도 API 접속 불가로 실패. 서로 무관해 보이는 두 장애가 동시에 터졌다.

```
[ERROR] /opt/stack/devstack/functions-common:712 git call failed: [git clone --no-checkout https://opendev.org/openstack/horizon.git /opt/stack/horizon]
```
```
API Error: Unable to connect to API (ENOTFOUND)
```

**가설**
1. 서버 외부 인터넷 단절 (게이트웨이/방화벽)
2. DNS 해석 실패 (ENOTFOUND = Node.js DNS 실패 코드 → 유력)
3. 프록시 설정 누락/오설정
4. opendev.org 일시 장애 (다른 API도 동시 실패했으므로 가능성 낮음)

**확인 과정** — 계층별로 분리 진단 (raw IP → DNS 스텁 → 상위 DNS 직접)

```
$ ping -c2 8.8.8.8
2 packets transmitted, 2 received, 0% packet loss        # raw 네트워크 정상

$ nslookup opendev.org            # 로컬 스텁(127.0.0.53) 경유
** server can't find opendev.org: SERVFAIL               # 스텁 실패
$ nslookup api.anthropic.com
** server can't find api.anthropic.com: SERVFAIL         # 도메인 무관, 전면 실패

$ nslookup opendev.org 8.8.8.8                           # 상위 DNS 직접 지정
Address: 38.108.68.97                                    # 정상
$ nslookup opendev.org 210.220.163.82                    # ISP DNS 직접
Address: 38.108.68.97                                    # 정상

$ resolvectl status
Link 2 (enp2s0)
    Current Scopes: none                                 # ← 핵심 증거
    DNS Servers: 210.220.163.82 219.250.36.130
Link 3 (ovs-system) / Link 4 (br-int) / Link 6 (br-ex)   # DevStack이 만든 OVS 브리지들
    Current Scopes: none

$ env | grep -i proxy                                    # 프록시 없음 → 가설 3 기각
```

**근본 원인**: systemd-resolved 스텁 리졸버(127.0.0.53)의 고장. enp2s0에 상위 DNS 서버가
등록돼 있음에도 `Current Scopes: none` — resolved가 해당 링크를 DNS 쿼리 경로로 쓰지 않아
모든 쿼리가 SERVFAIL. 상위 DNS 자체는 양쪽 다 정상이었으므로 순수하게 로컬 스텁 계층의 문제.
DevStack이 생성한 OVS 브리지(br-ex, br-int, ovs-system)가 등장한 시점과 맞물려 resolved의
링크 스코프가 깨진 것으로 판단. 두 에러는 증상만 다른 동일 원인.

**해결**: `/etc/resolv.conf` 심링크(→ stub-resolv.conf)를 제거하고 상위 DNS를 직접 가리키는
정적 파일로 교체 — 고장난 스텁 자체를 우회.

```bash
sudo rm /etc/resolv.conf
echo -e "nameserver 210.220.163.82\nnameserver 219.250.36.130\nnameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

**교훈**
- "무관해 보이는 장애 2개 동시 발생" = 공통 하위 계층(DNS/네트워크)부터 의심.
- 진단은 계층 분리로: raw IP(ping) → 로컬 스텁(nslookup) → 상위 DNS 직접(nslookup @server).
  각 단계가 용의자를 하나씩 기각한다.
- systemd-resolved 기반 우분투 + OVS/Neutron 조합에서는 resolved 스코프가 깨질 수 있다.
  정적 resolv.conf가 가장 단순하고 안정적인 우회.
- 주의: systemd-resolved 재시작/재부팅 시 심링크가 복원될 수 있다. 영구화하려면
  `sudo chattr +i /etc/resolv.conf`.

---

## #2 unstack.sh 실행 후 서버 네트워크 완전 단절

**단계**: DevStack 재설치 준비로 `./unstack.sh` 실행 직후

**현상**: unstack.sh를 실행하자 SSH 접속 불가. 원격에서 `ping 192.168.0.67` → 100% packet
loss. IP 계층 자체가 사라졌다. 모니터+키보드 직접 접속으로만 복구 가능했다.

```
(원격) ping 192.168.0.67: 3 packets transmitted, 0 packets received, 100.0% packet loss
(콘솔, netplan apply 시) cannot call Open vSwitch: ovsdb-server.service is not running
```

**가설**
1. unstack.sh가 br-ex를 정리하면서 enp2s0 설정(IP/링크)까지 날리고 원복하지 않음 (유력)
2. sshd 데몬 문제 (ping부터 실패하므로 기각)

**확인 과정** — 콘솔에서

```
ip a show br-ex        # 출력 없음 → br-ex는 이미 삭제됨. IP가 어디에도 없는 상태
```

**근본 원인**: `local.conf`의 `PUBLIC_INTERFACE=enp2s0` 설정. stack.sh는 이 설정으로 물리 NIC을
OVS 브리지 br-ex에 편입시킨다. unstack.sh는 브리지를 삭제할 뿐 물리 NIC의 링크 상태/IP 설정을
원래대로 복원하지 않는다(DevStack의 알려진 동작). 결과: enp2s0 링크 down + IP 무소속.

**해결**: 콘솔에서 두 줄.

```bash
sudo ip link set enp2s0 up
sudo netplan apply       # netplan yaml의 원래 설정을 재적용 → IP 복귀
```

`cannot call Open vSwitch` 메시지는 경고일 뿐이다 — unstack이 ovsdb-server를 꺼놔서 OVS 설정
부분만 건너뛴 것. 일반 이더넷 설정 적용은 성공했고 SSH가 즉시 복구됐다.

**교훈**
- `PUBLIC_INTERFACE`에 물리 NIC을 지정한 DevStack에서 **unstack.sh는 네트워크를 죽일 수 있다.**
  실행 전 콘솔 접근 수단 확보가 필수다. 복구는 `ip link set <nic> up && netplan apply` 2줄.
- ping부터 실패하면 SSH/서비스 계층 진단은 무의미 — 바로 콘솔로.
- NIC IP가 DHCP 동적 할당이면 `HOST_IP` 하드코딩과 어긋날 수 있다. 공유기 MAC 예약 또는
  netplan 고정 IP를 걸어둘 것.

---

## #3 재설치 시 neutron 초기 네트워크 생성 503

**단계**: DevStack 설치, #1·#2 해결 후 stack.sh 재실행 (당일 5회차+)

**현상**: DNS 문제 해결로 설치 대부분 통과. 마지막 초기 네트워크 생성
(`create_neutron_initial_network`)에서 실패.

```
Error while executing command: HttpException: 503, Unable to create the network. No tenant network is available for allocation.
```

**가설**
1. ML2 geneve 설정 누락 (vni_ranges 비어 있음)
2. 메모리 부족으로 서비스 사망
3. 이전 실패 설치 잔재로 neutron DB의 세그먼트 할당 테이블이 설정과 불일치 (유력)

**확인 과정**

```
$ grep -A3 "ml2_type_geneve\|tenant_network_types" /etc/neutron/plugins/ml2/ml2_conf.ini
tenant_network_types = geneve
[ml2_type_geneve]
vni_ranges = 1:65536          # 설정 정상 → 가설 1 기각

$ free -h                      # 15Gi 중 available 11Gi, OOM 로그 없음 → 가설 2 기각
$ systemctl list-units "devstack@*"
devstack@c-vol / n-sch / n-super-cond → failed   # 일부 서비스도 비정상 종료 상태
```

**1차 결론**: 실패한 설치 위에 unstack/clean 없이 stack.sh를 반복 실행해 DB·서비스·설정의
부분 상태가 뒤섞였다고 판단.

**해결(1차)**: 전체 초기화 후 재설치. stack 유저는 NOPASSWD sudo이므로 네트워크 복구 명령까지
한 체인으로 묶어 백그라운드 실행 — unstack이 br-ex를 지워 SSH가 끊겨도 서버 쪽에서
netplan apply까지 자동 진행되어 콘솔에 갈 필요가 없다.

```bash
nohup bash -c './unstack.sh; ./clean.sh; sudo ip link set enp2s0 up; sudo netplan apply' > /opt/stack/rebuild.log 2>&1 &
```

### #3 추가 분석 — 진범은 좀비 neutron-api

**현상**: unstack + clean으로 완전 초기화한 뒤 재설치했는데도 **완전히 동일한 지점, 동일한 503**.
"dirty 상태" 가설로는 설명이 안 된다.

```
$ mysql neutron -e "select count(*) from ml2_geneve_allocations;"
0                                   # 정상이면 65536행 (vni_ranges 1:65536)

$ journalctl -u devstack@neutron-api
ERROR ... HashRingIsEmpty: All 0 nodes were found offline.   # OVN 해시링도 0노드

$ systemctl show devstack@neutron-api -p ActiveEnterTimestamp
ActiveEnterTimestamp=22:14:55       # ← 결정적. unstack/clean/재설치 전부를 관통해 생존
```

unstack 로그에 `stop_process neutron-api` 시도는 있으나 실제로는 정지되지 않았고,
재설치의 `systemctl start devstack@neutron-api`는 이미 실행 중인 유닛에 no-op였다.

**정정된 근본 원인**: **clean 이전에 뜬 neutron-api 프로세스가 unstack.sh의 서비스 정지를
빠져나가 생존했다.** neutron ML2 플러그인은 프로세스 시작 시 geneve 세그먼트 할당 테이블
채우기와 OVN 해시링 노드 등록을 수행하는데, DB는 clean/재설치로 새로 만들어진 반면 프로세스는
재시작되지 않아 새 DB가 초기화 데이터 없이 방치됐다 → 할당 실패 503 + HashRingIsEmpty.

**해결**: 모든 devstack 유닛을 명시적으로 완전 정지한 뒤 재실행 — stack.sh의 start가 진짜
시작이 되게 한다.

```bash
sudo systemctl stop "devstack@*"
./stack.sh
```

**교훈**
- **stack.sh 실패 시 재실행 전 반드시 `./unstack.sh && ./clean.sh`.** dirty 재실행은 매번
  다른 에러를 만들어 진단 시간을 태운다.
- "클린 재설치했는데 같은 에러" = 초기화 범위 밖에서 생존한 상태(프로세스/캐시/커널 자원)를 의심.
- 프로세스 시작 시각(`ActiveEnterTimestamp`)과 데이터 생성 시각의 교차 검증이 좀비 프로세스
  진단의 핵심 기법.
- unstack.sh의 서비스 정지를 맹신하지 말 것 — 재설치 전 `systemctl stop "devstack@*"`를 습관화.

---

## #4 tempest 의존성 충돌로 설치 최종 단계 실패

**단계**: DevStack 설치. 본체는 전부 통과, 마지막 tempest venv 구성에서 실패

```
The conflict is caused by:
    openstackdocstheme 3.6.0 depends on dulwich>=0.15.0
    The user requested (constraint) dulwich===1.2.6
Additionally, some packages in these conflicts have no matching distributions available for your environment:
    dulwich
ERROR: ResolutionImpossible
ERROR: venv: could not install deps [-chttps://releases.openstack.org/constraints/upper/master, -r/opt/stack/tempest/requirements.txt, ...]
```

**근본 원인**: tempest는 branchless 프로젝트라 DevStack이 stable 브랜치여도 **항상 master 제약
파일**을 쓴다. 그 시점의 upstream master가 Python 3.12용 배포판이 없는 `dulwich===1.2.6`을
핀하고 있었다. 로컬 설정 문제가 아니라 업스트림 고장.

**해결**: 이 구성에 tempest(테스트 프레임워크)는 필요 없으므로 비활성화 후 재실행.

```bash
echo "disable_service tempest" >> /opt/stack/devstack/local.conf
sudo systemctl stop "devstack@*"    # 좀비 방지 (#3 교훈)
./stack.sh
```

**교훈**
- DevStack 실패 지점이 뒤로 갈수록 좋은 신호다 — 이번 실패는 본체 설치가 끝난 뒤 부가 도구에서 났다.
- 업스트림이 움직이는 대상(master 제약)에 의존하는 구성 요소는 어느 날 갑자기 깨진다.
  필요 없는 서비스는 `disable_service`로 표면적을 줄이는 것이 정답.

---

## #5 br-ex가 공유기 IP를 사칭하여 서버 아웃바운드 전면 블랙홀

가장 오래 잡고 있었던 사건이고, 이 구성의 핵심 아이디어(집 LAN을 public 네트워크로 사용)가
치르는 대가다.

**단계**: DevStack 설치 완료 후, 외부망 원격 접속(Tailscale) 구축 중

**현상**: 서버 tailnet IP로 ssh/ping 전부 timeout. 서버 자신도 `ping 8.8.8.8`,
`curl https://...` 등 **모든 아웃바운드 실패**. LAN 내부 SSH(192.168.0.67)는 정상 —
인터넷 방향만 죽은 비대칭 장애.

```
# 밖에서 본 서버 상태
100.103.84.3    tomo   linux  active; relay "waw"; offline, last seen 5m ago, tx 3276 rx 0

# 서버 헬스체크
# - Tailscale hasn't received a network map from the coordination server in 2m8s.

# 서버에서
$ ping -c 3 8.8.8.8
3 packets transmitted, 0 received, 100% packet loss
```

**가설**
1. tailscaled 데몬 문제 (재시작해도 동일 → 기각)
2. 서버 인터넷 아웃바운드 자체가 죽음 (`ping 8.8.8.8` 실패로 확정)
3. DevStack 네트워크 구성의 간섭 (유력 — local.conf가 집 LAN을 public 네트워크로 선언한다)

**확인 과정**

```
$ ip route
default via 192.168.0.1 dev br-ex          # 기본 라우트는 존재. 라우트 문제 아님

$ ip -br addr
br-ex   UNKNOWN   192.168.0.67/24 ... 192.168.0.1/24 ...   # ← 결정적. 공유기 IP가 br-ex에 있다

$ sudo ovs-vsctl show
Bridge br-ex
    Port enp2s0                            # 물리 NIC은 br-ex에 정상 편입

$ sudo iptables -t nat -L -n / -L FORWARD -n
# ts-*/LIBVIRT_* 체인뿐, 차단 규칙 없음 → iptables 기각
```

`tx 3276 rx 0`(보내지만 받는 게 0)이 초기 힌트였다 — 리턴 트래픽이 돌아오지 못하는 형태.

**근본 원인**: `local.conf`의 `PUBLIC_NETWORK_GATEWAY=192.168.0.1`(실제 공유기 IP)을 DevStack이
**br-ex 인터페이스에 직접 부여**한다. DevStack 설계상 이 옵션은 가짜 public 대역(기본
172.24.4.0/24)의 실존하지 않는 게이트웨이를 호스트가 대신 맡는 용도인데, 실존하는 공유기 IP를
지정하자 서버가 자기 자신을 게이트웨이로 인식했다. 기본 라우트(`via 192.168.0.1`)로 나가는
모든 패킷이 공유기가 아닌 로컬 br-ex로 회귀 → 아웃바운드 전면 블랙홀. LAN 내부 통신은
게이트웨이를 안 거치므로 멀쩡했다. (덤: 서버가 LAN에 게이트웨이 IP를 ARP 광고할 수 있어
다른 기기 통신까지 오염시킬 수 있는 위험 상태였다.)

**해결**: br-ex에서 사칭 IP만 제거. 라우팅은 진짜 공유기가 담당하면 되므로 Floating IP 동작에
영향이 없다.

```bash
sudo ip addr del 192.168.0.1/24 dev br-ex
```

적용 즉시 `ping 8.8.8.8` 정상.

**재발 방지**: `./stack.sh`를 다시 돌리면 DevStack이 이 IP를 또 부여한다. stack.sh가 마지막에
자동 실행하는 `local.sh`에 제거 명령을 넣어 영구화했다 — 이 저장소의
[`scripts/local.sh.template`](../scripts/local.sh.template)이 그것이고,
`01-install-devstack.sh`가 자동으로 배치한다.

**교훈**
- "LAN은 되는데 인터넷만 안 됨" = 게이트웨이 경로부터 의심. `ip -br addr`로 **있어서는 안 될
  IP가 어느 인터페이스에 붙어 있는지** 보는 것이 가장 빠른 진단이다.
- FLOATING_RANGE를 실제 LAN과 겹치게 쓰는 구성은 PUBLIC_NETWORK_GATEWAY 사칭이라는 대가가
  따른다 — 구성 자체는 유지하되 이 부작용만 상쇄하는 것이 정답.

---

## #6 VM 생성 시 "No Network found for internal-net"

**단계**: 수동 구축 중 VM 생성. 네트워크·SG 생성 단계를 건너뛰고 VM부터 만들려 했다.

```
No Network found for internal-net
```

```
$ openstack network list
→ public, private 두 개만 존재. internal-net 없음 — DevStack 기본 생성물만 있는 상태
```

**근본 원인**: 구축 순서(이미지 → 네트워크 → SG → VM)는 곧 리소스 의존 관계인데, 의존 대상이
없는 채로 VM 생성을 먼저 시도했다. Nova는 연결할 네트워크를 이름으로 조회하다 찾지 못하면
생성 요청 자체를 거부한다.

**교훈**
- runbook의 순서는 편의상 나열이 아니라 의존 그래프다.
- **이 의존 관계를 코드로 강제하는 것이 IaC의 핵심 가치다.** Terraform이라면 참조만 걸어두면
  순서를 알아서 계산한다. 수동 실행의 한계를 그대로 보여주는 사례라 Terraform 전환의 직접적인
  동기가 됐다.

---

## #7 sudo 실행 시 "No module named 'flask'"

**단계**: 수동 구축 중 web-vm 게시판 앱 기동

**현상**: `pip3 install flask pymysql`은 정상 완료됐는데, 80 포트 기동을 위해
`sudo python3 app.py`를 실행하자 flask 임포트에서 즉시 실패.

```
Traceback (most recent call last):
  File "/home/ubuntu/app.py", line 1, in <module>
    from flask import Flask, request, redirect
ModuleNotFoundError: No module named 'flask'
```

```
$ python3 -c "import flask; print(flask.__file__)"   # ubuntu 유저로는 성공
/home/ubuntu/.local/lib/python3.10/site-packages/flask/__init__.py
$ sudo python3 -c "import flask"                     # root로는 동일 에러 재현
```

**근본 원인**: 일반 유저의 `pip3 install`은 시스템 전역이 아닌 `~/.local/lib/.../site-packages`에
설치된다. `sudo python3`은 root로 실행되므로 그 경로를 보지 않는다 → "ubuntu에겐 있고 root에겐
없는" 모듈. **80 포트(특권 포트) 때문에 sudo를 붙이는 순간** 드러나는 함정이다.

**해결**: 전역 설치로 전환. 현재는 cloud-init(`templates/web-init.yaml.tftpl`)이 root로 실행되며
`pip3 install`을 전역에 수행하므로 이 문제가 구조적으로 발생하지 않는다.

**교훈**
- "설치한 유저"와 "실행하는 유저"가 다르면 파이썬 모듈 경로도 다르다.
- 정석은 venv + systemd 유닛, 또는 앱은 비특권 포트에 띄우고 앞단에 리버스 프록시를 두는 것이다.
  이 구성은 후자를 택하지 않았고, 그 한계는 README에 적어 뒀다.

---

## #8 openstack-exporter 컨테이너가 아예 뜨지 않음

**단계**: 모니터링에 openstack-exporter 추가

**현상**: 세 곳(clouds.yaml / docker-compose 서비스 / prometheus 잡)을 수정하고
`terraform apply -replace`로 monitoring-vm을 재생성했는데도 Prometheus에
`openstack_nova_agent_state` 결과가 비어 있다. 로그 조회 자체가 실패했다.

```
ubuntu@monitoring-vm:~$ sudo docker compose logs --tail 50 openstack-exporter
no configuration file provided: not found

ubuntu@monitoring-vm:~$ sudo docker compose -f /opt/monitoring/docker-compose.yml logs --tail 50 openstack-exporter
no such service: openstack-exporter
```

**확인 과정**: 첫 에러는 exporter 문제가 아니라 홈 디렉터리에서 실행해 compose 파일을 못 찾은
것이었다. `-f`로 경로를 주니 `no such service` — **compose 파일에 서비스 자체가 없다**.

```
$ sudo docker compose -f /opt/monitoring/docker-compose.yml ps
monitoring-grafana-1      grafana/grafana:11.1.0    ...  Up 11 minutes
monitoring-prometheus-1   prom/prometheus:v2.53.0   ...  Up 11 minutes
→ VM 재생성은 됐는데(11분 전 기동) exporter만 없다 = user_data 자체에 없었다

$ grep -c "openstack-exporter" terraform/monitoring-init.yaml.tftpl \
                               terraform/templates/monitoring-init.yaml.tftpl
terraform/monitoring-init.yaml.tftpl:3            ← 수정이 들어간 파일
terraform/templates/monitoring-init.yaml.tftpl:0  ← Terraform이 실제로 읽는 파일

$ grep -n templatefile terraform/monitoring.tf
13:  user_data = templatefile("${path.module}/templates/monitoring-init.yaml.tftpl", { ...
```

**근본 원인**: **같은 이름의 템플릿이 두 곳에 존재했다.** `templatefile()`이 참조하는 것은
`templates/` 쪽인데 수정은 루트 쪽에 들어갔다. Terraform 입장에서 user_data 입력값은 바뀐 것이
없으므로, `-replace`로 VM을 강제 재생성해도 **재생성 전과 똑같은 cloud-init**이 주입됐다.
에러가 아니라 "성공적으로 옛 설정을 재현"한 것이라 apply 출력만 봐서는 알아챌 수 없었다.

**부수 발견**: 그 루트 쪽 파일은 내용도 깨져 있었다 — ① 1행 `#cloud-config` 헤더 없음(헤더가
없으면 cloud-init이 파일 전체를 무시), ② 들여쓰기가 **탭 문자**(YAML은 탭 금지), ③ 터미널 폭에
걸려 단어 중간에서 줄바꿈. 경로가 맞았더라도 이 파일로는 cloud-init이 실패했을 상태였다.

**해결**: 실제 참조 경로에 반영하고, 혼동의 원인인 중복 파일을 삭제.

```bash
$ grep -P "\t" templates/monitoring-init.yaml.tftpl   # 탭 없음 확인 (출력 없어야 정상)
$ rm terraform/monitoring-init.yaml.tftpl             # 어느 .tf에서도 참조하지 않음 — 확인 후 삭제
$ terraform plan                                      # monitoring-vm만 replace로 뜨는지 확인
$ terraform apply                                     # web-vm/db-vm 무영향
```

**교훈**
- **템플릿을 고치기 전에 `templatefile()`의 실제 경로를 먼저 확인한다.**
  `grep -n templatefile *.tf` 한 줄이면 어느 파일이 진짜인지 확정된다.
- IaC에서 같은 이름의 파일이 두 곳에 있으면 그 자체가 사고 원인이다.
- **"apply가 성공했다"는 "의도한 변경이 들어갔다"와 다르다.** plan 출력에서 바꾸려던 속성이
  실제로 diff에 나타나는지 확인해야 한다. 아무 diff도 없이 replace만 뜬다면 그것이 곧
  "내 수정이 반영되지 않았다"는 신호다.

---

## #9 CI 첫 파이프라인 전면 실패 — 도구 이미지의 ENTRYPOINT

**단계**: IaC 검사 파이프라인 첫 실행

**현상**: 4개 job 중 `fmt`가 즉시 실패하고 뒤 스테이지는 skip. 로컬에서 같은 명령은 통과한다.

```
Terraform has no command named "sh". Did you mean "push"?

To see all of Terraform's top-level commands, run:
  terraform -help
ERROR: Job failed: exit code 1
```

**확인 과정**: 로컬에서 ENTRYPOINT를 명시적으로 바꿔 실행하니 정상 — 검사 로직 자체는 멀쩡함이
증명됐다.

```bash
docker run --rm -v "$PWD/terraform:/w" -w /w \
  --entrypoint terraform hashicorp/terraform:1.9 fmt -check -recursive -diff
# (출력 없음, 종료 코드 0)
```

**근본 원인**: `hashicorp/terraform` 이미지는 `ENTRYPOINT ["/bin/terraform"]`으로 빌드돼 있다.
러너는 job 스크립트를 컨테이너의 셸에 넘겨 실행하므로, ENTRYPOINT가 셸이 아닌 이미지는
스크립트 첫 단어를 terraform의 하위 명령으로 오해한다.

**해결**: 해당 job의 이미지 지정에서 ENTRYPOINT를 비운다.

```yaml
image:
  name: hashicorp/terraform:1.9
  entrypoint: [""]
```

**교훈**
- CI에서 쓰는 도구 이미지는 "셸이 있는 이미지"인지 먼저 확인한다. 단일 바이너리를 ENTRYPOINT로
  갖는 이미지(terraform, tflint, tfsec 등)는 전부 이 처리가 필요하다.
- 같은 명령이 로컬에서 되고 CI에서만 실패하면, 명령 자체보다 **실행 컨텍스트(ENTRYPOINT, 셸,
  네트워크)** 를 먼저 의심한다.

> 현재 이 저장소는 GitHub Actions를 쓰고, `hashicorp/setup-terraform` 액션이 바이너리를 직접
> 설치하므로 이 문제가 발생하지 않는다.

---

## #10 tflint가 변수 9개의 타입 누락으로 job 실패

**단계**: 파이프라인 첫 실행의 tflint job

**현상**: `terraform validate`는 통과하는데 tflint는 exit code 2로 실패.

```
Warning: `db_fixed_ip` variable has no type (terraform_typed_variables)

  on variables.tf line 34:
  34: variable "db_fixed_ip" {

ERROR: Job failed: exit code 2
```

**확인 과정**: 타입이 없는 변수가 정확히 9개 — `external_network_name`, `flavor_name`,
`image_name`, `internal_cidr`, `lan_cidr`, `dns_nameservers`, `db_fixed_ip`, `public_key_path`,
`exporter_role`.

**근본 원인**: `default` 값만 주면 Terraform이 타입을 추론하므로 `validate`는 통과한다.
즉 **문법 검사만으로는 걸러지지 않는 품질 결함**이며, 잘못된 타입의 값이 들어와도 apply
직전까지 발견되지 않는다.

**해결**: 9개 변수에 명시적 `type` 추가(문자열 8개, `dns_nameservers`는 `list(string)`) 후
`terraform fmt -recursive`. 재실행 시 tflint exit 0.

**교훈**
- **`validate` 통과 = 코드가 좋다는 뜻이 아니다.** 문법 검사와 품질 검사는 잡는 결함의 종류가
  다르므로 파이프라인에 둘 다 있어야 한다.
- 이 결함은 사람이 수동으로 검토할 때는 3일간 아무도 못 봤고, 파이프라인을 붙인 첫 실행에서
  즉시 9건이 나왔다.

---

## #11 형상관리된 IaC가 실환경과 달랐다

에러로 드러나지 않는 종류의 사고라 가장 위험했다.

**단계**: CI에 apply를 붙이기 직전

**현상**: "형상관리 저장소에 왜 호스트의 terraform 파일이 안 보이냐"는 의문에서 출발.
확인해 보니 저장소의 코드는 호스트에서 가져온 것이 아니라 **런북 마크다운에서 복원한 것**이었다.
두 벌이 같다는 보장이 없는 상태에서 apply를 눌렀다면 실환경이 문서 쪽 코드로 덮어써졌을 것이다.

**확인 과정**: 호스트에서 파일을 받아 주석·공백을 제거하고 비교.

```
.tf 8개                    : 기능적으로 동일 (차이는 전부 주석/정렬)
variables.tf               : 동일 + 나중에 추가한 type 선언
monitoring-init.yaml.tftpl : 31줄 차이 — 실제 기능 차이
```

**근본 원인**: 런북의 `monitoring-init.yaml.tftpl`이 **openstack-exporter 도입 이전 버전**이었다.
호스트 파일에는 있는 ① exporter용 `clouds.yaml` write_files ② Prometheus의
`job_name: openstack` 스크레이프 ③ `openstack-exporter` 컨테이너 정의가 전부 빠져 있었다.
그대로 apply했다면 **모니터링에서 오퍼레이터 시야가 사라지는 회귀**가 발생한다.
[#8](#8-openstack-exporter-컨테이너가-아예-뜨지-않음)의 "중복 템플릿" 사건과 같은 뿌리다 —
같은 파일이 여러 벌 존재하는 상태.

**해결**: 호스트 파일을 진실로 삼아 동기화하고, `versions.tf`를 호스트와 같은 `version.tf`로
개명(합쳐질 때 `terraform` 블록이 중복되는 사고 방지), 재현성을 위해 `.terraform.lock.hcl`도
저장소에 포함.

**교훈**
- **문서는 코드의 사본이지 원본이 아니다.** 런북에 붙여넣은 코드는 붙여넣은 시점에 멈춰 있고,
  이후 호스트에서 고친 내용은 따라오지 않는다. 형상관리의 대상은 **실행되는 파일 그 자체**여야 한다.
- **apply 전 `plan`으로 확인하는 절차가 이 사고를 막는 마지막 방어선이다.**
- 이 사건 자체가 "형상관리가 없으면 어느 코드가 진짜인지 아무도 확답할 수 없다"를 그대로 보여준다.
  지금 이 저장소가 실행되는 파일을 직접 담고 있는 이유다.
