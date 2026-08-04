# 2. 인프라 구성과 IaC 전환

> 빈 클라우드 위에 2-tier 웹 서비스를 올린다. AWS로 치면 AMI 등록 → VPC/서브넷 → 보안그룹
> → EC2 + EBS + EIP에 해당한다.
>
> 처음에는 `openstack` CLI로 **손으로** 만들었고, 그다음 같은 구성을 **Terraform + cloud-init**
> 코드로 옮겼다. 이 문서는 그 순서를 그대로 따라간다 — 손으로 해봐야 코드가 무엇을 대신하는지
> 알 수 있기 때문이다.
>
> **코드는 이 문서가 아니라 저장소 루트의 `.tf` 파일이 원본이다.** 문서에 붙여넣은 코드는
> 붙여넣은 시점에 멈춘다는 것을 실제로 겪었다 ([troubleshooting #11](troubleshooting.md)).
> 그래서 여기서는 설계 의도만 설명하고 코드는 파일을 가리킨다.

---

## 2-1. 수동 구축 — CLI로 한 번

만드는 순서가 곧 의존 관계다. 네트워크가 없으면 VM을 만들 수 없다
(순서를 건너뛰어 실패한 기록: [troubleshooting #6](troubleshooting.md)).

### ① OS 이미지 등록 (Glance)

```bash
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img   # ~600MB
openstack image create "ubuntu-22.04" --file jammy-server-cloudimg-amd64.img \
  --disk-format qcow2 --container-format bare --public
```

### ② 내부 네트워크 + 라우터 (Neutron)

VM들이 연결될 **내부 전용 네트워크**(`10.0.10.0/24`)와, 그것을 외부(= 집 LAN)와 이어주는
**가상 라우터**. 이 라우터가 있어야 VM이 인터넷으로 나갈 수 있고(패키지 설치에 필요),
Floating IP도 이 라우터를 통해 동작한다.

```bash
openstack network create internal-net
openstack subnet create internal-subnet --network internal-net \
  --subnet-range 10.0.10.0/24 --dns-nameserver 8.8.8.8   # DNS 없으면 VM에서 apt install이 안 된다
openstack router create main-router
openstack router set main-router --external-gateway public   # 바깥쪽을 public(=집 LAN)에 연결
openstack router add subnet main-router internal-subnet      # 안쪽을 내부 서브넷에 연결
```

### ③ Security Group — 이 구성의 보안 설계

Security Group은 **VM 단위 방화벽**이다. 기본값은 "들어오는 트래픽 전부 차단"이므로 필요한
포트만 연다. 설계 의도는 명확하다 — **web-vm은 LAN 사용자에게 열고, db-vm은 web-vm에서 오는
DB 접속(3306)만 허용해 외부에서 절대 직접 못 건드리게 한다.**

```bash
openstack security group create web-sg
openstack security group rule create web-sg --protocol tcp --dst-port 22 --remote-ip 192.168.0.0/24
openstack security group rule create web-sg --protocol tcp --dst-port 80 --remote-ip 192.168.0.0/24

openstack security group create db-sg
openstack security group rule create db-sg --protocol tcp --dst-port 3306 --remote-group web-sg
  # IP가 아니라 "web-sg 그룹 소속 VM"이 출발지 — web-vm의 IP가 바뀌어도 규칙이 그대로 유효
openstack security group rule create db-sg --protocol tcp --dst-port 22 --remote-ip 10.0.10.0/24
```

`--remote-group`이 핵심이다. IP 기반 규칙은 VM을 재생성할 때마다 깨지지만, 그룹 기반 규칙은
"누구인가"로 허용하므로 깨지지 않는다.

### ④ VM + 볼륨 + Floating IP

db-vm에는 Cinder 볼륨(독립적인 가상 디스크)을 붙인다. DB 데이터를 VM 본체가 아닌 볼륨에 두면
**VM이 삭제돼도 데이터는 남는다**. Floating IP는 **web-vm에만** 줘서 db-vm을 외부에서 보이지
않게 한다.

```bash
openstack keypair create mykey > ~/mykey.pem && chmod 600 ~/mykey.pem
openstack server create web-vm --image ubuntu-22.04 --flavor m1.small \
  --network internal-net --security-group web-sg --key-name mykey
openstack server create db-vm  --image ubuntu-22.04 --flavor m1.small \
  --network internal-net --security-group db-sg  --key-name mykey

openstack volume create db-data --size 10        # 10GB 빈 가상 디스크
openstack server add volume db-vm db-data        # VM 안에서 /dev/vdb로 보임

openstack floating ip create public
openstack server add floating ip web-vm <할당된 IP>
```

## 2-2. 서비스 배포 — 2-tier 게시판

db-vm은 Floating IP가 없으므로 밖에서 직접 못 들어간다. 항상
`내 PC → (Floating IP로) web-vm → (내부 IP로) db-vm` 순서로 건너간다. 이 **web-vm을
발판(bastion) 삼는 구조 자체가 private 네트워크 설계의 증거**다.

### db-vm — 볼륨 마운트 후 MySQL 설치

순서가 중요하다. **마운트 → 설치** 여야 DB 초기 데이터가 볼륨 위에 생성된다.

```bash
lsblk                                                  # vdb가 10G로 보이는지
sudo mkfs.ext4 /dev/vdb                                # ⚠️ 대상이 vdb인지 재확인 — 안의 데이터 전부 삭제
sudo mkdir -p /var/lib/mysql
sudo mount /dev/vdb /var/lib/mysql
echo '/dev/vdb /var/lib/mysql ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab   # 재부팅 후 자동 마운트

sudo apt update && sudo apt install -y mysql-server    # 초기 데이터가 볼륨에 생성됨
df -h /var/lib/mysql                                   # 데이터 디렉토리가 /dev/vdb 위인지 확인

sudo sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
  # 기본값 127.0.0.1 → 모든 인터페이스. 실제 차단은 db-sg(3306은 web-sg에서만)가 담당하므로 안전
sudo systemctl restart mysql

sudo mysql -e "CREATE DATABASE board;
CREATE USER 'app'@'%' IDENTIFIED BY '<DB_PASSWORD>';
GRANT ALL ON board.* TO 'app'@'%';"
```

### web-vm — Flask 게시판

글을 저장/조회하는 최소한의 앱을 80 포트로 띄운다. 코드는
[`templates/web-init.yaml.tftpl`](../templates/web-init.yaml.tftpl)의 `app.py` 부분에 있다
(약 25줄).

```bash
sudo apt update && sudo apt install -y python3-pip mysql-client
sudo pip3 install flask pymysql        # ⚠️ sudo로 설치 — 이유는 troubleshooting #7

mysql -h <db-vm 내부 IP> -u app -p board -e "SELECT 1;"   # DB 연결부터 확인
sudo python3 app.py                    # 80 포트는 특권 포트라 sudo 필요
```

## 2-3. IaC 전환 — Terraform + cloud-init

여기까지 손으로 타이핑한 과정 전체를 코드로 옮긴다. **OpenStack 리소스**(네트워크/SG/VM/
볼륨/Floating IP)는 **Terraform**이, **VM 내부 설정**(볼륨 마운트, MySQL, Flask 앱)은
**cloud-init**(VM 첫 부팅 시 1회 실행되는 초기화 에이전트)이 담당한다.

완성되면 `terraform apply` **한 번**으로 빈 클라우드에서 게시판까지 자동으로 올라오고,
`destroy` → `apply`로 언제든 동일하게 재구축할 수 있다. **이 재현 가능성이 수동 구축 대비
IaC의 핵심 가치**다.

### 파일 구성

| 파일 | 대응하는 수동 작업 |
|---|---|
| [`version.tf`](../version.tf) | Terraform/provider 버전 고정 (`>= 1.5`, provider `~> 3.0`) |
| [`providers.tf`](../providers.tf) | 인증 — `cloud = "devstack-admin"`으로 `clouds.yaml`에 위임 |
| [`variables.tf`](../variables.tf) | 환경마다 달라지는 값 (CIDR, 경로, 비밀번호) |
| [`network.tf`](../network.tf) | 2-1 ② 네트워크/서브넷/라우터 + **포트** |
| [`security.tf`](../security.tf) | 2-1 ③ Security Group |
| [`compute.tf`](../compute.tf) | 2-1 ①④ 이미지/키페어/VM/Floating IP |
| [`storage.tf`](../storage.tf) | 2-1 ④ Cinder 볼륨 |
| [`monitoring.tf`](../monitoring.tf), [`identity.tf`](../identity.tf) | 모니터링 — [3. 모니터링](03-monitoring.md) |
| [`templates/*.tftpl`](../templates) | 2-2 VM 내부 설정 전체 |

### 수동 구축과 달라진 점

코드로 옮기면서 그냥 옮기지 않고 고친 것들:

**① 포트를 명시적으로 만든다.** 수동 구축 때는 Nova가 VM의 NIC(포트)를 암묵적으로
만들었다. 직접 선언하면 ⓐ db-vm에 **고정 IP**(`10.0.10.10`)를 줄 수 있고 ⓑ Floating IP를
포트에 정확히 연결할 수 있다. 고정 IP 덕분에 **VM을 재생성해도 앱의 DB 주소를 고칠 필요가
없다** — 수동 때는 매번 IP를 확인해 `app.py`를 고쳐야 했다.

**② 인증 정보가 코드에 없다.** `providers.tf`는 DevStack이 만들어 둔 `clouds.yaml`을 읽는다.
키페어도 "생성"이 아니라 기존 개인키에서 뽑은 **공개키만 등록**한다 — 개인키가 tfstate에
남지 않는다.

```bash
ssh-keygen -y -f ~/mykey.pem > ~/mykey.pub    # 개인키에서 공개키만 추출
```

**③ 앱이 systemd 서비스가 됐다.** 수동 때는 터미널에서 `sudo python3 app.py`로 띄워서
터미널을 닫으면 죽었다. cloud-init이 `board.service`를 등록하므로 재부팅해도 살아 있다.

**④ pip 설치가 root 환경으로 간다.** `runcmd`는 root로 실행되므로
[troubleshooting #7](troubleshooting.md)(유저 pip 설치를 root가 못 보던 문제)이 구조적으로
사라진다.

**⑤ 실행 순서를 사람이 기억하지 않는다.** 명령의 "실행 순서"가 리소스 간 "참조 관계"로
표현되고, 순서는 Terraform이 계산한다. [troubleshooting #6](troubleshooting.md)의 순서 실수가
구조적으로 불가능해진다.

### cloud-init에서 조심할 것

- **`packages:` 키로 MySQL을 설치하면 안 된다.** `packages`는 `runcmd`보다 **먼저** 실행되므로
  볼륨을 마운트하기 전에 MySQL이 깔려 데이터가 루트 디스크에 생긴다. "마운트 → 설치" 순서를
  지키려고 전부 `runcmd` 안에 넣었다.
- **볼륨 부착은 부팅보다 늦다.** `/dev/vdb`가 생길 때까지 최대 5분 대기하는 루프를 넣었다.
- **포맷은 멱등이어야 한다.** `blkid /dev/vdb || mkfs.ext4 /dev/vdb` — 이미 포맷돼 있으면
  건너뛰어 데이터를 보존한다.
- **템플릿 안의 셸 변수**는 `$${var}`로 이스케이프한다 (`${...}`는 Terraform 몫).

### 적용

```bash
cp terraform.tfvars.example terraform.tfvars   # 실제 값 기입 — 이 파일은 커밋 금지(.gitignore)

terraform init       # provider 다운로드 + .terraform.lock.hcl 생성 (lock 파일은 커밋한다)
terraform validate   # 문법·참조 검증
terraform plan       # 실행 계획 — 핵심은 destroy가 0인 것
terraform apply
terraform output web_floating_ip
```

수동으로 만든 리소스가 남아 있으면 이름 충돌로 실패한다. **수동 리소스를 전부 지우고
코드로 처음부터 재생성하는 것 자체가 "코드만으로 전체를 재현할 수 있다"는 증명**이다.
생성의 역순으로 지운다: Floating IP 해제·반납 → VM → 볼륨 → 라우터 인터페이스/게이트웨이 →
라우터 → 서브넷 → 네트워크 → SG → 키페어 → 이미지.

```bash
terraform destroy && terraform apply                       # 재현성 확인
curl http://$(terraform output -raw web_floating_ip)/      # 동일하게 동작하면 성공
```

## 자주 만나는 문제

| 증상 | 우선 확인 |
|---|---|
| VM 생성 실패 "No valid host" | `nova-compute` 로그, 호스트 RAM/디스크 잔량, `openstack hypervisor list` |
| VM이 ACTIVE인데 응답 없음 | `openstack console log show web-vm` |
| web-vm → db-vm 3306 실패 | db-sg 규칙(`--remote-group web-sg`), `bind-address` 변경 여부, MySQL 재시작 |
| VM 간 통신이 이유 없이 느림 | MTU (VXLAN 오버헤드로 1450 필요) — `ping -M do -s 1422 <상대IP>` |
| VM에서 apt/pip 안 됨 | 서브넷의 DNS 설정, 라우터 external gateway 연결 상태 |
| `terraform init` 실패 | 호스트 DNS — [troubleshooting #1](troubleshooting.md)과 동일 계열 |
| 인증 오류 (401 / could not find cloud) | `~/.config/openstack/clouds.yaml`에 `devstack-admin` 항목 있는지 |
| apply 중 "already exists" | 같은 이름의 수동 리소스가 남아 있다 |
| curl 연결 거부 | cloud-init이 아직 실행 중 — `openstack console log show`, 수 분 소요 |
| 앱은 뜨는데 500 | db-vm이 아직 MySQL 설치 중. 계속되면 web-vm에서 `mysql -h 10.0.10.10 -u app -p` |
| cloud-init이 뭘 했는지 모르겠음 | VM 안에서 `sudo cat /var/log/cloud-init-output.log` |
| Floating IP가 이전과 다름 | 정상 — 재할당은 IP를 보장하지 않는다. 항상 `terraform output`으로 읽는다 |

**다음**: [3. 모니터링](03-monitoring.md)
