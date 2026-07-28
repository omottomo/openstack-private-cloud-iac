variable "external_network_name" {
  type        = string
  description = "외부 네트워크 이름"
  default     = "public"
}

variable "flavor_name" {
  type        = string
  description = "VM 사양 (RAM 2GB)"
  default     = "m1.small"
}

variable "image_name" {
  type    = string
  default = "ubuntu-22.04"
}

variable "image_local_path" {
  description = "로컬에 받아둔 jammy 클라우드 이미지 경로"
  type        = string
}

variable "internal_cidr" {
  type        = string
  description = "VM 내부 네트워크 대역"
  default     = "10.0.10.0/24"
}

variable "lan_cidr" {
  type        = string
  description = "SG에서 SSH/HTTP를 허용할 LAN 대역"
  default     = "192.168.0.0/24"
}

variable "dns_nameservers" {
  type    = list(string)
  default = ["8.8.8.8"]
}

variable "db_fixed_ip" {
  type        = string
  description = "db-vm 고정 내부 IP"
  default     = "10.0.10.10"
}

variable "public_key_path" {
  type        = string
  description = "키페어에 등록할 공개키 경로"
  default     = "~/mykey.pub"
}

variable "db_password" {
  description = "MySQL app 계정 비밀번호"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin 계정 비밀번호"
  type        = string
  sensitive   = true
}

variable "exporter_role" {
  type        = string
  description = "exporter 계정에 부여할 롤"
  default     = "reader"
}

variable "exporter_password" {
  description = "prometheus-exporter 계정 비밀번호"
  type        = string
  sensitive   = true
}

variable "os_auth_url" {
  description = "Keystone 인증 URL"
  type        = string
}
