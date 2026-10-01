# Latest Ubuntu 24.04 LTS published by Canonical, unless an AMI is pinned.
data "aws_ami" "ubuntu" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "admin" {
  count = var.ssh_public_key == null ? 0 : 1

  key_name   = "${local.name}-admin"
  public_key = var.ssh_public_key
}

resource "aws_instance" "node" {
  ami                    = coalesce(var.ami_id, try(data.aws_ami.ubuntu[0].id, null))
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = try(aws_key_pair.admin[0].key_name, null)

  # Installs k3s (single-node Kubernetes) at first boot.
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    k3s_version = var.k3s_version
  })
  user_data_replace_on_change = true

  # IMDSv2 only: a pod cannot steal instance credentials with a plain GET.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = { Name = "${local.name}-node" }
}
