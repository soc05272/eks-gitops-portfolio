terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "eks-gitops-tfstate-<AWS-ACCOUNT-ID>"
    key     = "eks-gitops-portfolio/terraform.tfstate"
    region  = "ap-northeast-2"
    encrypt = true
  }
}
