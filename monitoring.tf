resource "openstack_compute_instance_v2" "monitoring" {
  name      = "monitoring-vm"
  image_id  = openstack_images_image_v2.ubuntu.id
  flavor_id = data.openstack_compute_flavor_v2.small.id
  key_pair  = openstack_compute_keypair_v2.mykey.name

  network {
    port = openstack_networking_port_v2.monitoring.id
  }

  user_data = templatefile("${path.module}/templates/monitoring-init.yaml.tftpl", {
    web_ip                 = openstack_networking_port_v2.web.all_fixed_ips[0]
    db_ip                  = openstack_networking_port_v2.db.all_fixed_ips[0]
    grafana_admin_password = var.grafana_admin_password
    auth_url               = var.os_auth_url
    exporter_password      = var.exporter_password
  })

  depends_on = [openstack_networking_router_interface_v2.internal]
}

resource "openstack_networking_floatingip_v2" "monitoring" {
  pool = var.external_network_name
}

resource "openstack_networking_floatingip_associate_v2" "monitoring" {
  floating_ip = openstack_networking_floatingip_v2.monitoring.address
  port_id     = openstack_networking_port_v2.monitoring.id
}
