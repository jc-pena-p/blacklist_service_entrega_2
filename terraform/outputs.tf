output "rds_endpoint" {
  description = "RDS connection endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_db_name" {
  description = "RDS database name"
  value       = aws_db_instance.postgres.db_name
}

output "beanstalk_env_cname" {
  description = "Elastic Beanstalk Environment CNAME/URL"
  value       = aws_elastic_beanstalk_environment.env.cname
}
