resource "aws_security_group" "node" {
  name        = "${local.name}-node"
  description = "Kubernetes node: admin access restricted, application port public"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-node" }

  # Replacing a security group in use fails unless the new one exists first.
  lifecycle {
    create_before_destroy = true
  }
}

# One resource per rule: adding or removing a rule never rewrites the others.

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.node.id
  description       = "SSH from the administrator only"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "kubernetes_api" {
  security_group_id = aws_security_group.node.id
  description       = "Kubernetes API from the administrator only"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  security_group_id = aws_security_group.node.id
  description       = "Application NodePort"
  cidr_ipv4         = var.app_cidr
  ip_protocol       = "tcp"
  from_port         = var.app_node_port
  to_port           = var.app_node_port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "Outbound: package and image downloads"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
