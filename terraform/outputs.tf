output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "security_group_id" {
  description = "ID of the node's security group."
  value       = aws_security_group.node.id
}

output "instance_id" {
  description = "ID of the Kubernetes node."
  value       = aws_instance.node.id
}

output "node_public_ip" {
  description = "Public IP of the Kubernetes node."
  value       = aws_instance.node.public_ip
}

output "app_url" {
  description = "URL of the application once it is deployed."
  value       = "http://${aws_instance.node.public_ip}:${var.app_node_port}"
}

output "ssh_command" {
  description = "How to open a shell on the node."
  value       = var.ssh_public_key == null ? "SSH disabled (no ssh_public_key)" : "ssh ubuntu@${aws_instance.node.public_ip}"
}

output "kubeconfig_command" {
  description = "Fetches the cluster credentials and points them at the public IP."
  value       = var.ssh_public_key == null ? "SSH disabled (no ssh_public_key)" : "ssh ubuntu@${aws_instance.node.public_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/${aws_instance.node.public_ip}/' > kubeconfig.yaml"
}
