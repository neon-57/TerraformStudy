output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}