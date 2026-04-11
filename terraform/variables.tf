variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Application Name"
  type        = string
  default     = "blacklist-service"
}

variable "environment" {
  description = "Environment Name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "db_username" {
  description = "PostgreSQL DB username"
  type        = string
  default = "db_username"
}

variable "db_password" {
  description = "PostgreSQL DB password"
  type        = string
  default = "sappy-refinance-slit-elevator-skimmer-prowling"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "blacklist_db"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "beanstalk_solution_stack" {
  description = "Elastic Beanstalk Solution Stack"
  type        = string
  default     = "64bit Amazon Linux 2023 v4.12.1 running Python 3.11"
}

variable "beanstalk_instance_type" {
  description = "EC2 instance type for Elastic Beanstalk"
  type        = string
  default     = "t3.micro"
}
