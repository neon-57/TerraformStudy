provider "aws" {
  region = "ap-northeast-1"
}

resource "aws_s3_bucket" "example" {
  bucket = "neon-terraform-example"
}

output "name" {
  value = aws_s3_bucket.example.bucket
}