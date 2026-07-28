resource "openstack_blockstorage_volume_v3" "db_data" {
  name = "db-data"
  size = 10
}

resource "openstack_compute_volume_attach_v2" "db_data" {
  instance_id = openstack_compute_instance_v2.db.id
  volume_id   = openstack_blockstorage_volume_v3.db_data.id
}
