provider "aws" {
  region = var.aws_region
}

resource "random_pet" "suffix" {
  length = 2
}

locals {
  name_prefix               = "${var.name_prefix}-${random_pet.suffix.id}"
  e2e_private_key_file      = "${path.module}/.artifacts/e2e_rsa.pem"
  windows_password_data_raw = try(aws_instance.windows.password_data, "")
  windows_admin_password = (
    length(trimspace(local.windows_password_data_raw)) > 0
    ? rsadecrypt(local.windows_password_data_raw, tls_private_key.e2e.private_key_pem)
    : ""
  )
  nomad_edition_e2e = lower(trimspace(var.nomad_edition))
  nomad_version_e2e = length(trimspace(var.nomad_version)) > 0 ? trimspace(var.nomad_version) : (
    local.nomad_edition_e2e == "enterprise" ? "1.11.3+ent" : "1.11.3"
  )
  linux_inventory_entries = join("\n", compact([
    "linux-e2e ansible_host=${aws_instance.linux.public_ip} ansible_user=${var.linux_ssh_user} ansible_connection=ssh ansible_python_interpreter=/usr/bin/python3 ansible_ssh_private_key_file=${local.e2e_private_key_file} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'",
    var.deploy_redhat_client ? "redhat-e2e ansible_host=${aws_instance.redhat[0].public_ip} ansible_user=${var.redhat_ssh_user} ansible_connection=ssh ansible_python_interpreter=/usr/bin/python3 ansible_ssh_private_key_file=${local.e2e_private_key_file} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'" : ""
  ]))
  inventory_content = <<-EOT
    [linux]
    ${local.linux_inventory_entries}

    [windows]
    windows-e2e ansible_host=${aws_instance.windows.public_ip} ansible_user=${var.windows_admin_username} ansible_password=${local.windows_admin_password} ansible_connection=winrm ansible_port=5986 ansible_winrm_scheme=https ansible_winrm_transport=basic ansible_winrm_server_cert_validation=ignore ansible_winrm_operation_timeout_sec=60 ansible_winrm_read_timeout_sec=90

    [nomad_clients:children]
    linux
    windows
  EOT
  base_extra_vars = {
    nomad_server_address                 = local.effective_nomad_server_address
    nomad_datacenter                     = var.nomad_datacenter
    nomad_region                         = var.nomad_region
    nomad_client_intro_token             = var.client_introduction_token
    nomad_edition                        = local.nomad_edition_e2e
    nomad_version                        = local.nomad_version_e2e
    nomad_client_install_server_address  = local.effective_nomad_server_address
    nomad_client_install_datacenter      = var.nomad_datacenter
    nomad_client_install_intro_token     = var.client_introduction_token
    nomad_client_install_enable_raw_exec = true
  }
  rendered_extra_vars = yamlencode(merge(
    local.base_extra_vars,
    length(trimspace(var.nomad_license)) > 0 ? { nomad_license = var.nomad_license } : {}
  ))
  common_supported_availability_zones = sort(tolist(setintersection(
    toset(data.aws_ec2_instance_type_offerings.linux.locations),
    toset(data.aws_ec2_instance_type_offerings.windows.locations),
    var.deploy_redhat_client ? toset(data.aws_ec2_instance_type_offerings.redhat[0].locations) : toset(data.aws_availability_zones.available.names),
    var.deploy_nomad_server ? toset(data.aws_ec2_instance_type_offerings.nomad_server[0].locations) : toset(data.aws_availability_zones.available.names)
  )))
  supported_default_subnets = [
    for subnet_id in sort(data.aws_subnets.default.ids) : subnet_id
    if contains(local.common_supported_availability_zones, data.aws_subnet.default[subnet_id].availability_zone)
  ]
  selected_default_subnet = try(local.supported_default_subnets[0], null)
  effective_nomad_server_address = length(trimspace(var.nomad_server_address)) > 0 ? trimspace(var.nomad_server_address) : coalesce(
    try(aws_instance.nomad_server[0].private_dns, ""),
    aws_instance.nomad_server[0].private_ip
  )
}

resource "tls_private_key" "e2e" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

data "aws_ec2_instance_type_offerings" "linux" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.linux_instance_type]
  }
}

data "aws_ec2_instance_type_offerings" "windows" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.windows_instance_type]
  }
}

data "aws_ec2_instance_type_offerings" "redhat" {
  count         = var.deploy_redhat_client ? 1 : 0
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.redhat_instance_type]
  }
}

data "aws_ec2_instance_type_offerings" "nomad_server" {
  count         = var.deploy_nomad_server ? 1 : 0
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.nomad_server_instance_type]
  }
}

data "aws_ssm_parameter" "linux_ami" {
  name = var.linux_ami_ssm_parameter
}

data "aws_ssm_parameter" "windows_ami" {
  name = var.windows_ami_ssm_parameter
}

resource "aws_key_pair" "e2e" {
  key_name   = "${local.name_prefix}-key"
  public_key = tls_private_key.e2e.public_key_openssh
}

resource "terraform_data" "selected_default_subnet" {
  input = local.selected_default_subnet

  lifecycle {
    precondition {
      condition = local.selected_default_subnet != null
      error_message = format(
        "No default subnet in %s supports the requested EC2 instance types (%s, %s%s%s). Choose different instance types or use a region/default VPC with a compatible availability zone.",
        var.aws_region,
        var.linux_instance_type,
        var.windows_instance_type,
        var.deploy_redhat_client ? format(", %s", var.redhat_instance_type) : "",
        var.deploy_nomad_server ? format(", %s", var.nomad_server_instance_type) : ""
      )
    }
  }
}

resource "aws_security_group" "e2e_hosts" {
  name_prefix = "${local.name_prefix}-"
  description = "E2E access for Nomad Ansible test hosts"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH for Linux host"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "WinRM over HTTPS for Windows host"
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "Nomad HTTP API for E2E readiness checks"
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "Nomad RPC between E2E hosts"
    from_port   = 4647
    to_port     = 4647
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-hosts"
  })
}

resource "aws_instance" "nomad_server" {
  count                       = var.deploy_nomad_server ? 1 : 0
  ami                         = data.aws_ssm_parameter.linux_ami.value
  instance_type               = var.nomad_server_instance_type
  subnet_id                   = terraform_data.selected_default_subnet.output
  vpc_security_group_ids      = [aws_security_group.e2e_hosts.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.e2e.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    if command -v dnf >/dev/null 2>&1; then
      dnf install -y dnf-plugins-core
      dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
      dnf install -y nomad
    elif command -v yum >/dev/null 2>&1; then
      yum install -y yum-utils
      yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
      yum install -y nomad
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y gpg software-properties-common curl
      curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" >/etc/apt/sources.list.d/hashicorp.list
      apt-get update -y
      apt-get install -y nomad
    fi

    mkdir -p /etc/nomad.d /opt/nomad
    cat >/etc/nomad.d/server.hcl <<NOMAD
    datacenter = "${var.nomad_datacenter}"
    region     = "${var.nomad_region}"
    data_dir   = "/opt/nomad"
    bind_addr  = "0.0.0.0"

    server {
      enabled          = true
      bootstrap_expect = 1
    }

    client {
      enabled = false
    }
    NOMAD

    systemctl enable nomad
    systemctl restart nomad
  EOF

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-nomad-server"
    Role = "nomad-server-e2e"
  })
}

resource "aws_instance" "linux" {
  ami                         = data.aws_ssm_parameter.linux_ami.value
  instance_type               = var.linux_instance_type
  subnet_id                   = terraform_data.selected_default_subnet.output
  vpc_security_group_ids      = [aws_security_group.e2e_hosts.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.e2e.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    if command -v dnf >/dev/null 2>&1; then
      dnf install -y python3
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y python3
    fi
  EOF

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-linux"
    Role = "nomad-client-e2e-linux"
  })
}

resource "aws_instance" "redhat" {
  count                       = var.deploy_redhat_client ? 1 : 0
  ami                         = trimspace(var.redhat_ami_id)
  instance_type               = var.redhat_instance_type
  subnet_id                   = terraform_data.selected_default_subnet.output
  vpc_security_group_ids      = [aws_security_group.e2e_hosts.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.e2e.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    if command -v dnf >/dev/null 2>&1; then
      dnf install -y python3
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y python3
    fi
  EOF

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redhat"
    Role = "nomad-client-e2e-redhat"
  })
}

resource "aws_instance" "windows" {
  ami                         = data.aws_ssm_parameter.windows_ami.value
  instance_type               = var.windows_instance_type
  subnet_id                   = terraform_data.selected_default_subnet.output
  vpc_security_group_ids      = [aws_security_group.e2e_hosts.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.e2e.key_name
  get_password_data           = true
  user_data_replace_on_change = true

  user_data = <<-POWERSHELL
    <powershell>
    $ErrorActionPreference = "Stop"

    Set-Service -Name WinRM -StartupType Automatic
    if ((Get-Service -Name WinRM).Status -ne "Running") {
      Start-Service -Name WinRM
    }

    Enable-PSRemoting -SkipNetworkProfileCheck -Force
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false

    $existingHttpsListener = Get-ChildItem -Path WSMan:\Localhost\Listener -ErrorAction SilentlyContinue | Where-Object {
      $_.Keys -match "Transport=HTTPS"
    }

    if (-not $existingHttpsListener) {
      $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
      New-Item -Path WSMan:\Localhost\Listener -Transport HTTPS -Address * -CertificateThumbprint $cert.Thumbprint -Force | Out-Null
    }

    if (-not (Get-NetFirewallRule -DisplayName "Allow WinRM HTTPS 5986" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName "Allow WinRM HTTPS 5986" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5986
    }

    Restart-Service -Name WinRM
    </powershell>
  POWERSHELL

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-windows"
    Role = "nomad-client-e2e-windows"
  })
}

