# =============================================================================
# Lambda IAM Role
# =============================================================================

resource "aws_iam_role" "lambda" {
  name = "ecs-caller-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# =============================================================================
# Lambda Function
# =============================================================================

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/ecs_caller.py"
  output_path = "${path.module}/lambda/ecs_caller.zip"
}

resource "aws_lambda_function" "ecs_caller" {
  function_name    = "ecs-caller"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "python3.11"
  handler          = "ecs_caller.lambda_handler"
  role             = aws_iam_role.lambda.arn
  timeout          = 30

  vpc_config {
    subnet_ids         = [aws_subnet.private_1.id, aws_subnet.private_2.id]
    security_group_ids = [aws_security_group.shared.id]
  }

  environment {
    variables = {
      ALB_DNS  = aws_lb.main.dns_name
      APP_NAME = var.app_name
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_vpc]
}
