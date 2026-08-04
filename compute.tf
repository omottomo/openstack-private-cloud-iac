data "openstack_compute_flavor_v2" "small" {
  name = var.flavor_name
}

resource "openstack_images_image_v2" "ubuntu" {
  name             = var.image_name
  local_file_path  = var.image_local_path
  disk_format      = "qcow2"
  container_format = "bare"
  visibility       = "public"
}

resource "openstack_compute_keypair_v2" "mykey" {
  name       = "mykey"
  public_key = file(pathexpand(var.public_key_path))
}

resource "openstack_compute_instance_v2" "db" {
  name      = "db-vm"
  image_id  = openstack_images_image_v2.ubuntu.id
  flavor_id = data.openstack_compute_flavor_v2.small.id
  key_pair  = openstack_compute_keypair_v2.mykey.name

  network {
    port = openstack_networking_port_v2.db.id
  }

  user_data = templatefile("${path.module}/templates/db-init.yaml.tftpl", {
    db_password = var.db_password
  })

  depends_on = [openstack_networking_router_interface_v2.internal]
}

resource "openstack_compute_instance_v2" "web" {
  name      = "web-vm"
  image_id  = openstack_images_image_v2.ubuntu.id
  flavor_id = data.openstack_compute_flavor_v2.small.id
  key_pair  = openstack_compute_keypair_v2.mykey.name

  network {
    port = openstack_networking_port_v2.web.id
  }

  user_data = templatefile("${path.module}/templates/web-init.yaml.tftpl", {
    db_host     = openstack_networking_port_v2.db.all_fixed_ips[0]
    db_password = var.db_password
  })

  depends_on = [openstack_networking_router_interface_v2.internal]
}

resource "openstack_networking_floatingip_v2" "web" {
  pool = var.external_network_name
}

resource "openstack_networking_floatingip_associate_v2" "web" {
  floating_ip = openstack_networking_floatingip_v2.web.address
  port_id     = openstack_networking_port_v2.web.id
}
