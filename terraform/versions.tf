terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 버킷명은 AWS 계정 ID를 포함해 계정마다 다르므로 코드에 두지 않는다(부분 백엔드 구성).
  # 실제 값은 gitignore 대상인 backend.hcl에 두고 아래처럼 초기화한다.
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key = "eks-gitops-portfolio/terraform.tfstate"
    region = "ap-northeast-2"
    encrypt = true
  }
}
