data "openstack_networking_network_v2" "public" {
  name = var.external_network_name
}

resource "openstack_networking_network_v2" "internal" {
  name = "internal-net"
}

resource "openstack_networking_subnet_v2" "internal" {
  name            = "internal-subnet"
  network_id      = openstack_networking_network_v2.internal.id
  cidr            = var.internal_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "main" {
  name                = "main-router"
  external_network_id = data.openstack_networking_network_v2.public.id
}

resource "openstack_networking_router_interface_v2" "internal" {
  router_id = openstack_networking_router_v2.main.id
  subnet_id = openstack_networking_subnet_v2.internal.id
}

resource "openstack_networking_port_v2" "web" {
  name               = "web-port"
  network_id         = openstack_networking_network_v2.internal.id
  security_group_ids = [openstack_networking_secgroup_v2.web.id]
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.internal.id
  }
}

resource "openstack_networking_port_v2" "db" {
  name               = "db-port"
  network_id         = openstack_networking_network_v2.internal.id
  security_group_ids = [openstack_networking_secgroup_v2.db.id]
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.internal.id
    ip_address = var.db_fixed_ip
  }
}

resource "openstack_networking_port_v2" "monitoring" {
  name               = "monitoring-port"
  network_id         = openstack_networking_network_v2.internal.id
  security_group_ids = [openstack_networking_secgroup_v2.monitoring.id]
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.internal.id
  }
}
