# =============================================================================
# ECR Repository
# =============================================================================

resource "aws_ecr_repository" "apps" {
  name         = local.ecr_repo_name
  force_delete = true
}

# =============================================================================
# Docker Build & Push
# =============================================================================

data "aws_ecr_authorization_token" "token" {}

resource "null_resource" "docker_build_push" {
  triggers = {
    app_version = var.app_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      # Login to ECR
      echo "${data.aws_ecr_authorization_token.token.password}" | \
        docker login --username AWS --password-stdin ${aws_ecr_repository.apps.repository_url}

      # Build image
      docker build \
        --platform linux/amd64 \
        -t ${local.ecr_repo_name}:${var.app_name}-${var.app_version} \
        -f ../app/Dockerfile \
        ..

      # Tag for ECR
      docker tag \
        ${local.ecr_repo_name}:${var.app_name}-${var.app_version} \
        ${aws_ecr_repository.apps.repository_url}:${var.app_name}-${var.app_version}

      # Push to ECR
      docker push \
        ${aws_ecr_repository.apps.repository_url}:${var.app_name}-${var.app_version}
    EOT
  }

  depends_on = [aws_ecr_repository.apps]
}
