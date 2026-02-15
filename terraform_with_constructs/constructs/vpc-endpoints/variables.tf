variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "subnet_ids" {
  description = "IDs of the subnets for interface endpoints"
  type        = list(string)
}

variable "security_group_id" {
  description = "ID of the security group for interface endpoints"
  type        = string
}

variable "route_table_id" {
  description = "ID of the route table for gateway endpoints"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
