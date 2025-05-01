variable "aws_region" {
    type = string
    default = "ap-northeast-1"
}

variable "repo_name" {
    type = string
    default = "lambda-demo"
}

variable "image_tag" {
    type = string
    default = "latest"
}

variable "function_name" {
    type = string
    default = "lambda-demo-fn"
}

variable "memory_size" {
    type = number
    default = 128
}

variable "timeout"   {
    type = number
    default = 10
}
