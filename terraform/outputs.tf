output "alb_dns_name" {
  description = "Internal ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.ecs_caller.function_name
}

output "lambda_invoke_command" {
  description = "Command to invoke the Lambda function"
  value       = "aws lambda invoke --function-name ${aws_lambda_function.ecs_caller.function_name} --cli-binary-format raw-in-base64-out --payload '{}' /tmp/lambda-output.json && cat /tmp/lambda-output.json"
}
