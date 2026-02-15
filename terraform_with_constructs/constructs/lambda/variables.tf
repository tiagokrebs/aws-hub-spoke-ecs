variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "role_name" {
  description = "Name of the Lambda IAM role"
  type        = string
}

variable "source_file" {
  description = "Path to the Lambda source file"
  type        = string
}

variable "handler" {
  description = "Lambda function handler"
  type        = string
}

variable "runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "python3.11"
}

variable "timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

variable "subnet_ids" {
  description = "IDs of the subnets for the Lambda VPC config"
  type        = list(string)
}

variable "security_group_id" {
  description = "ID of the security group for the Lambda VPC config"
  type        = string
}

variable "environment_variables" {
  description = "Environment variables for the Lambda function"
  type        = map(string)
  default     = {}
}
