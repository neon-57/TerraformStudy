variable "aws_region" {
  type        = string
  description = "デプロイ先リージョン"
  default     = "ap-northeast-1"
}

variable "repo_name" {
  type        = string
  description = "ECR リポジトリ名"
  default     = "express-serverless"
}

variable "image_tag" {
  type        = string
  description = "Docker イメージのタグ"
  default     = "latest"
}

variable "function_name" {
  type        = string
  default     = "express-serverless"
}

variable "memory_size" {
  type        = number
  description = "Lambda メモリ (MB)"
  default     = 512
}

variable "timeout" {
  type        = number
  description = "Lambda タイムアウト (秒)"
  default     = 29
}

variable "db_engine" {
  type        = string
  description = "RDS エンジン名 (例: postgres)"
  default     = "postgres"
}

variable "db_instance_class" {
  type        = string
  description = "RDS インスタンスクラス"
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type        = number
  default     = 20
}

variable "db_username" {
  type        = string
  default     = "rds_user"
}

variable "db_password" {
  type        = string
  description = "RDS マスターパスワード"
  default     = "password123" #不適切なのは理解しています。
}

variable "db_name" {
  type        = string
  description = "example_db"
  default     = "app"
}