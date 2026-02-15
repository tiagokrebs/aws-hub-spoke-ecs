output "function_name" {
  description = "Lambda function name"
  value       = module.lambda.function_name
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = module.lambda.function_arn
}

output "lambda_invoke_command" {
  description = "Command to invoke the Lambda function"
  value       = "aws lambda invoke --function-name ${module.lambda.function_name} --cli-binary-format raw-in-base64-out --payload '{}' /tmp/lambda-output.json && cat /tmp/lambda-output.json"
}
