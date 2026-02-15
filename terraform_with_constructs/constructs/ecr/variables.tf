variable "name" {
  description = "Name of the ECR repository"
  type        = string
}

variable "force_delete" {
  description = "Whether to force delete the repository"
  type        = bool
  default     = false
}
