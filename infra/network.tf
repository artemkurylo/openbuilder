# -----------------------------------------------------------------------------
# Dedicated VPC with ONE public subnet, and no way in.
# -----------------------------------------------------------------------------
# Why a public subnet instead of a private subnet:
#
#   All access to this box is via SSM Session Manager, and the SSM agent is
#   strictly OUTBOUND: it long-polls ssmmessages/ec2messages/ssm over TCP 443.
#   Nothing ever connects in. That means the box needs egress to the internet
#   and nothing else.
#
#   The two ways to give a private subnet that egress both cost real money for
#   a single always-on t4g.medium:
#     * NAT gateway            ~ $32/mo  ($0.045/hr) + data processing
#     * VPC interface endpoints ~ $22/mo  (3 endpoints x ~$7.30/mo) + data
#
#   A public subnet with an internet gateway costs $0. Since the security group
#   below has ZERO ingress rules and the instance has no key pair and no sshd
#   exposure, a public IP is not an attack surface — there is nothing listening
#   and nothing permitted to reach it.
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security group: no ingress at all. Do not add one.
# -----------------------------------------------------------------------------
# There is deliberately no `ingress` block, no port 22, and no key pair on the
# instance. Shell access is `aws ssm start-session` (see the
# ssm_session_command output), which needs no inbound rule.
# -----------------------------------------------------------------------------

resource "aws_security_group" "instance" {
  name        = "${var.name_prefix}-instance"
  description = "openbuilder box: egress only, no ingress. Access is via SSM Session Manager."
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound. Needed for SSM (443), GitHub, OpenRouter, apt and npm."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-instance-sg"
  })
}
