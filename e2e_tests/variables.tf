variable "aws_region" {
  type        = string
  description = "AWS region for E2E test infrastructure."
  default     = "us-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix used when naming E2E resources."
  default     = "nomad-ansible-e2e"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach Linux SSH (22) and Windows WinRM (5986)."
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_cidr_blocks) > 0
    error_message = "allowed_cidr_blocks must contain at least one CIDR block."
  }
}

variable "linux_ami_ssm_parameter" {
  type        = string
  description = "SSM parameter name for Linux AMI selection."
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

variable "windows_ami_ssm_parameter" {
  type        = string
  description = "SSM parameter name for Windows AMI selection."
  default     = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

variable "linux_instance_type" {
  type        = string
  description = "EC2 instance type for the Linux Nomad client test host."
  default     = "t3a.small"
}

variable "deploy_redhat_client" {
  type        = bool
  description = "Provision an additional Red Hat Enterprise Linux client host for E2E coverage."
  default     = false
}

variable "redhat_ami_id" {
  type        = string
  description = "AMI ID for the optional Red Hat Enterprise Linux E2E client host. Required when deploy_redhat_client is true."
  default     = ""

  validation {
    condition     = !var.deploy_redhat_client || length(trimspace(var.redhat_ami_id)) > 0
    error_message = "redhat_ami_id must be set when deploy_redhat_client is true."
  }
}

variable "redhat_instance_type" {
  type        = string
  description = "EC2 instance type for the optional Red Hat Enterprise Linux Nomad client test host."
  default     = "t3a.small"
}

variable "windows_instance_type" {
  type        = string
  description = "EC2 instance type for the Windows Nomad client test host."
  default     = "t3a.large"
}

variable "linux_ssh_user" {
  type        = string
  description = "SSH user for the Linux test host."
  default     = "ec2-user"
}

variable "redhat_ssh_user" {
  type        = string
  description = "SSH user for the optional Red Hat test host."
  default     = "ec2-user"
}

variable "windows_admin_username" {
  type        = string
  description = "Administrator username for the Windows test host."
  default     = "Administrator"
}

variable "deploy_nomad_server" {
  type        = bool
  description = "Deploy a single-node Nomad server for E2E client lifecycle tests."
  default     = true
}

variable "nomad_server_instance_type" {
  type        = string
  description = "EC2 instance type for the single-node Nomad server when deploy_nomad_server is true."
  default     = "t3a.small"
}

variable "nomad_server_address" {
  type        = string
  description = "Reachable external Nomad server address (without :4647) used when deploy_nomad_server is false."
  default     = ""

  validation {
    condition     = var.deploy_nomad_server || length(trimspace(var.nomad_server_address)) > 0
    error_message = "nomad_server_address is required when deploy_nomad_server is false."
  }
}

variable "nomad_datacenter" {
  type        = string
  description = "Nomad datacenter to configure in client nomad.hcl."
  default     = "dc1"
}

variable "nomad_region" {
  type        = string
  description = "Nomad region to configure in client nomad.hcl."
  default     = "global"
}

variable "nomad_edition" {
  type        = string
  description = "Nomad client edition for E2E install workflow (community or enterprise)."
  default     = "community"

  validation {
    condition     = contains(["community", "enterprise"], lower(trimspace(var.nomad_edition)))
    error_message = "nomad_edition must be either 'community' or 'enterprise'."
  }
}

variable "nomad_version" {
  type        = string
  description = "Optional override for Nomad version in E2E install workflow."
  default     = ""
}

variable "nomad_license" {
  type        = string
  description = "Optional single-line Nomad Enterprise license string for E2E install workflow."
  default     = ""
  sensitive   = true
}

variable "client_introduction_token" {
  type        = string
  description = "Optional pre-generated Nomad client introduction token for ACL-protected clusters."
  default     = ""
  sensitive   = true
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to AWS resources."
  default     = {}
}
