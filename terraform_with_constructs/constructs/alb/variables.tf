variable "name" {
  description = "Name of the ALB"
  type        = string
}

variable "security_group_id" {
  description = "ID of the security group"
  type        = string
}

variable "subnet_ids" {
  description = "IDs of the subnets"
  type        = list(string)
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
