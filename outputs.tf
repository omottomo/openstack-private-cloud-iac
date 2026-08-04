output "web_floating_ip" {
  description = "게시판 접속 주소"
  value       = openstack_networking_floatingip_v2.web.address
}

output "db_internal_ip" {
  value = openstack_networking_port_v2.db.all_fixed_ips[0]
}

output "grafana_url" {
  description = "Grafana 대시보드"
  value       = "http://${openstack_networking_floatingip_v2.monitoring.address}:3000"
}

output "prometheus_url" {
  description = "Prometheus UI"
  value       = "http://${openstack_networking_floatingip_v2.monitoring.address}:9090"
}
