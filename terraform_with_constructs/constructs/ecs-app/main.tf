# =============================================================================
# Docker Build & Push
# =============================================================================

resource "null_resource" "docker_build_push" {
  triggers = {
    app_version = var.app_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      # Login to ECR using spoke-me profile
      aws ecr get-login-password --region ${var.region} --profile spoke-me | \
        docker login --username AWS --password-stdin ${var.ecr_repo_url}

      # Build image
      docker build \
        --platform linux/amd64 \
        --provenance=false \
        -t ${var.app_name}:${var.app_version} \
        -f ${var.app_path}/Dockerfile \
        ${var.app_path}

      # Tag for ECR
      docker tag \
        ${var.app_name}:${var.app_version} \
        ${var.ecr_repo_url}:${var.app_name}-${var.app_version}

      # Push to ECR
      docker push \
        ${var.ecr_repo_url}:${var.app_name}-${var.app_version}
    EOT
  }
}

# =============================================================================
# CloudWatch Log Group
# =============================================================================

resource "aws_cloudwatch_log_group" "this" {
  name = "/ecs/${var.app_name}"
}

# =============================================================================
# Task Definition
# =============================================================================

resource "aws_ecs_task_definition" "this" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name  = var.app_name
      image = "${var.ecr_repo_url}:${var.app_name}-${var.app_version}"
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "APP_PREFIX"
          value = "/${var.app_name}"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  depends_on = [null_resource.docker_build_push]
}

# =============================================================================
# Target Group
# =============================================================================

resource "aws_lb_target_group" "this" {
  name        = "tg-${var.app_name}"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/${var.app_name}/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# =============================================================================
# Listener Rule
# =============================================================================

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      values = ["/${var.app_name}/*"]
    }
  }
}

# =============================================================================
# ECS Service
# =============================================================================

resource "aws_ecs_service" "this" {
  name            = var.app_name
  cluster         = var.cluster_name
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.app_name
    container_port   = 80
  }

  depends_on = [aws_lb_listener_rule.this]
}
