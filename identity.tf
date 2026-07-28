data "openstack_identity_project_v3" "admin" {
  name = "admin"
}

data "openstack_identity_role_v3" "exporter" {
  name = var.exporter_role
}

resource "openstack_identity_user_v3" "exporter" {
  name     = "prometheus-exporter"
  password = var.exporter_password
}

resource "openstack_identity_role_assignment_v3" "exporter" {
  user_id    = openstack_identity_user_v3.exporter.id
  project_id = data.openstack_identity_project_v3.admin.id
  role_id    = data.openstack_identity_role_v3.exporter.id
}
