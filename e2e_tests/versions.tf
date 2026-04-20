terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.38.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2.1"
    }
  }
}
