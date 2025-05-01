terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws   = { source = "hashicorp/aws",   version = "~> 5.40" }
    docker = { source = "kreuzwerker/docker", version = "~> 3.0" }
  }
}
