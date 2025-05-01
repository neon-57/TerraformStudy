locals {
  account_id     = data.aws_caller_identity.current.account_id
  image_uri      = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.repo_name}:${var.image_tag}"
  repository_url = aws_ecr_repository.this.repository_url
}

#
# 1. ECR リポジトリ
#
resource "aws_ecr_repository" "this" {
  name                 = var.repo_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }

  #
  force_delete = true
}

#
# 2. Docker buildx → push
#
resource "docker_image" "app" {
  name = local.image_uri

  build {
    context    = "${path.module}/../.." # ルートに Dockerfile/lambda.js がある場合
    dockerfile = "Dockerfile"
    platform   = "linux/arm64"
    # BuildKit の provenance を切る
    label = {
      "org.opencontainers.image.source" = "terraform"
    }
  }

  triggers = {
    lambda_js_sha  = filesha256("${path.module}/../../lambda.js")
    dockerfile_sha = filesha256("${path.module}/../../Dockerfile")
  }
}

# push
resource "docker_registry_image" "app" {
  name          = docker_image.app.name
  keep_remotely = true
}

#
# 3. イメージの digest を確定させる
#
data "aws_ecr_image" "app" {
  repository_name = aws_ecr_repository.this.name
  image_tag       = var.image_tag
  depends_on      = [docker_registry_image.app]
}

#
# 4. IAM ロール
#
resource "aws_iam_role" "lambda_exec" {
  name               = "${var.function_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "basic_exec" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

#
# 5. Lambda (コンテナイメージ)
#
resource "aws_lambda_function" "this" {
  function_name = var.function_name
  package_type  = "Image"
  # タグを外して、ダイジェストのみで指定
  image_uri     = "${local.repository_url}@${data.aws_ecr_image.app.image_digest}"
  role          = aws_iam_role.lambda_exec.arn
  architectures = ["arm64"]
  memory_size   = var.memory_size
  timeout       = var.timeout

  lifecycle {
    ignore_changes = [image_uri]
  }
}

#
# 6. Function URL
#
resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"
}

#
# 7. CloudFront (オリジン: Lambda Function URL)
#
resource "aws_cloudfront_origin_access_control" "lambda_oac" {
  name                              = "${var.function_name}-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "never"
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
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
