resource "aws_db_parameter_group" "postgres_params" {
  name        = "${var.app_name}-${var.environment}-pg-params"
  family      = "postgres15"
  description = "RDS parameter group for ${var.app_name}"
}

resource "aws_db_subnet_group" "default" {
  name       = "${var.app_name}-${var.environment}-sbg"
  subnet_ids = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = {
    Name        = "${var.app_name}-${var.environment}-subnet-group"
    Environment = var.environment
  }
}

resource "aws_db_instance" "postgres" {
  identifier             = "${var.app_name}-${var.environment}-db"
  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  engine                 = "postgres"
  engine_version         = "15" # Utilizing major version 15 defaults
  username               = var.db_username
  password               = var.db_password
  db_name                = var.db_name
  db_subnet_group_name   = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  parameter_group_name   = aws_db_parameter_group.postgres_params.name
  publicly_accessible    = false
  skip_final_snapshot    = true # Should be false in production

  tags = {
    Name        = "${var.app_name}-${var.environment}-db"
    Environment = var.environment
  }
}
