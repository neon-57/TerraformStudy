provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

#
# ECR へのログイン情報を Docker Provider に渡す
#
data "aws_ecr_authorization_token" "token" {}

provider "docker" {
  registry_auth {
    address  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    username = data.aws_ecr_authorization_token.token.user_name
    password = data.aws_ecr_authorization_token.token.password
  }
}
