terraform {
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1.1"
    }
    aap = {
      source  = "ansible/aap"
      version = "~> 1.4.0"
    }
  }
}
