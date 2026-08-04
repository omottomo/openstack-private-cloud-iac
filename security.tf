resource "openstack_networking_secgroup_v2" "web" {
  name        = "web-sg"
  description = "web-vm: allow SSH/HTTP from LAN"
}

resource "openstack_networking_secgroup_rule_v2" "web_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.lan_cidr
  security_group_id = openstack_networking_secgroup_v2.web.id
}

resource "openstack_networking_secgroup_rule_v2" "web_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = var.lan_cidr
  security_group_id = openstack_networking_secgroup_v2.web.id
}

resource "openstack_networking_secgroup_v2" "db" {
  name        = "db-sg"
  description = "db-vm: MySQL from web-sg only, SSH from internal net"
}

resource "openstack_networking_secgroup_rule_v2" "db_mysql" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 3306
  port_range_max    = 3306
  remote_group_id   = openstack_networking_secgroup_v2.web.id
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_secgroup_rule_v2" "db_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.internal_cidr
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_secgroup_v2" "monitoring" {
  name        = "monitoring-sg"
  description = "monitoring-vm: Grafana/Prometheus UI from LAN"
}

resource "openstack_networking_secgroup_rule_v2" "monitoring_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.lan_cidr
  security_group_id = openstack_networking_secgroup_v2.monitoring.id
}

resource "openstack_networking_secgroup_rule_v2" "monitoring_grafana" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 3000
  port_range_max    = 3000
  remote_ip_prefix  = var.lan_cidr
  security_group_id = openstack_networking_secgroup_v2.monitoring.id
}

resource "openstack_networking_secgroup_rule_v2" "monitoring_prometheus" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 9090
  port_range_max    = 9090
  remote_ip_prefix  = var.lan_cidr
  security_group_id = openstack_networking_secgroup_v2.monitoring.id
}

resource "openstack_networking_secgroup_rule_v2" "web_node_exporter" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 9100
  port_range_max    = 9100
  remote_group_id   = openstack_networking_secgroup_v2.monitoring.id
  security_group_id = openstack_networking_secgroup_v2.web.id
}

resource "openstack_networking_secgroup_rule_v2" "db_node_exporter" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 9100
  port_range_max    = 9100
  remote_group_id   = openstack_networking_secgroup_v2.monitoring.id
  security_group_id = openstack_networking_secgroup_v2.db.id
}
