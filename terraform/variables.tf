variable "hub_account_id" {
  description = "AWS account ID for the hub account"
  type        = string
}

variable "spoke_account_id" {
  description = "AWS account ID for the spoke account"
  type        = string
}

variable "hub_profile" {
  description = "AWS CLI profile for the hub account"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "app_name" {
  description = "Application name"
  type        = string
}

variable "app_version" {
  description = "Application version tag"
  type        = string
}
