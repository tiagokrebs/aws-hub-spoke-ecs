output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "route_table_id" {
  description = "ID of the private route table"
  value       = aws_route_table.private.id
}
