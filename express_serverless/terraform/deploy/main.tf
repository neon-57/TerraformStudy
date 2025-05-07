###############################################################################
# Terraform & Provider
###############################################################################
terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  image_uri      = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.repo_name}:${var.image_tag}"
  repository_url = aws_ecr_repository.this.repository_url
}

###############################################################################
# 1. ECR リポジトリ（既存なら import で取り込む）
###############################################################################
import {
  to = aws_ecr_repository.this
  id = var.repo_name                     # 既存リポジトリ名
}

resource "aws_ecr_repository" "this" {
  name                 = var.repo_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
}

###############################################################################
# 2. Docker buildx → push
###############################################################################
resource "docker_image" "app" {
  name = local.image_uri

  build {
    context    = "${path.module}/../.."   # ルートに Dockerfile がある想定
    dockerfile = "Dockerfile"
    platform   = "linux/arm64"

    # BuildKit provenance を切る（--provenance=false）
    label = {
      "org.opencontainers.image.source" = "terraform"
    }
  }

  # 変更がなくとも毎回ビルドしたい場合
  triggers = { always = timestamp() }
}

resource "docker_registry_image" "app" {
  name          = docker_image.app.name
  keep_remotely = true

  lifecycle {
    replace_triggered_by = [docker_image.app]
  }
}

###############################################################################
# 3. イメージ digest を取得
###############################################################################
data "aws_ecr_image" "app" {
  repository_name = var.repo_name
  image_tag       = var.image_tag
  depends_on      = [docker_registry_image.app]
}

###############################################################################
# 4. IAM ロール
###############################################################################
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.function_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "basic_exec" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

###############################################################################
# 5. Lambda（コンテナイメージ）
###############################################################################
resource "aws_lambda_function" "this" {
  function_name = var.function_name
  package_type  = "Image"
  image_uri     = "${local.repository_url}@${data.aws_ecr_image.app.image_digest}"

  role          = aws_iam_role.lambda_exec.arn
  architectures = ["arm64"]
  memory_size   = var.memory_size
  timeout       = var.timeout

  # ── VPC 接続（RDS 用） ──
  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [aws_ecr_repository.this]
}

###############################################################################
# 6. Function URL
###############################################################################
import {
  to = aws_lambda_function_url.this
  id = var.function_name               # 既存 Function URL を取り込む場合
}

resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "AWS_IAM"       # 直接呼ばせず CloudFront からのみ
}

# CloudFront だけに URL Invoke を許可
resource "aws_lambda_permission" "allow_cf" {
  statement_id  = "AllowCloudFrontInvoke"
  action        = "lambda:InvokeFunctionUrl"
  function_name = aws_lambda_function.this.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.this.arn
}

###############################################################################
# 7. CloudFront（オリジン: Function URL）
###############################################################################
resource "aws_cloudfront_origin_access_control" "lambda_oac" {
  name                              = "${var.function_name}-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  wait_for_deployment = false
  enabled             = true
  comment             = "${var.function_name} via Function URL"

  origin {
    domain_name = trimsuffix(
      trimprefix(aws_lambda_function_url.this.function_url, "https://"),
      "/"
    )
    origin_id = "lambda-origin"

    origin_access_control_id = aws_cloudfront_origin_access_control.lambda_oac.id
    connection_attempts      = 3
    connection_timeout       = 10

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "lambda-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      cookies      { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate { cloudfront_default_certificate = true }
}

# イメージ更新時にキャッシュ無効化
resource "null_resource" "reset_cache" {
  triggers = { digest = data.aws_ecr_image.app.image_digest }

  provisioner "local-exec" {
    when    = destroy
    command = "echo Skip invalidation on destroy"
  }

  provisioner "local-exec" {
    when    = create
    command = <<EOT
aws cloudfront create-invalidation \
  --distribution-id ${aws_cloudfront_distribution.this.id} \
  --paths '/*'
EOT
  }

  depends_on = [aws_lambda_function.this]
}

###############################################################################
# 8. ネットワーク（Default VPC で簡易構成）
###############################################################################
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Lambda 用 SG
resource "aws_security_group" "lambda" {
  name        = "${var.function_name}-lambda-sg"
  description = "Outbound-only for Lambda"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS 用 SG
resource "aws_security_group" "db" {
  name        = "${var.function_name}-db-sg"
  description = "Allow Lambda access to RDS"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################################################
# 9. RDS
###############################################################################
resource "aws_db_subnet_group" "default" {
  name       = "${var.function_name}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "this" {
  identifier              = "${var.function_name}-db"
  engine                  = var.db_engine
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage

  username                = var.db_username
  password                = var.db_password

  db_subnet_group_name    = aws_db_subnet_group.default.name
  vpc_security_group_ids  = [aws_security_group.db.id]

  skip_final_snapshot     = true
}

###############################################################################
# 10. Secrets Manager（DB 接続情報を格納）
###############################################################################
resource "aws_secretsmanager_secret" "db" {
  name = "${var.function_name}-db-uri"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.db_name
  })
}

###############################################################################
# 11. Outputs
###############################################################################
output "function_url" {
  value = aws_lambda_function_url.this.function_url
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}
