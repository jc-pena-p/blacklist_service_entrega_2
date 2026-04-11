resource "aws_iam_role" "beanstalk_service_role" {
  name = "${var.app_name}-${var.environment}-eb-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "elasticbeanstalk.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "beanstalk_service_health" {
  role       = aws_iam_role.beanstalk_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth"
}

resource "aws_iam_role_policy_attachment" "beanstalk_service_service" {
  role       = aws_iam_role.beanstalk_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkService"
}

resource "aws_iam_role" "beanstalk_ec2_role" {
  name = "${var.app_name}-${var.environment}-eb-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "beanstalk_ec2_web" {
  role       = aws_iam_role.beanstalk_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"
}

resource "aws_iam_instance_profile" "beanstalk_ec2_profile" {
  name = "${var.app_name}-${var.environment}-eb-ec2-profile"
  role = aws_iam_role.beanstalk_ec2_role.name
}

resource "aws_elastic_beanstalk_application" "app" {
  name        = "${var.app_name}-${var.environment}"
  description = "Elastic Beanstalk Application for ${var.app_name}"
}

data "archive_file" "app_zip" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/app.zip"
  excludes    = ["terraform", ".venv", ".git", "__pycache__", "tests"]
}

resource "aws_s3_bucket" "eb_app_bucket" {
  bucket        = "${var.app_name}-${var.environment}-eb-deploy"
  force_destroy = true
}

resource "aws_s3_object" "app_zip" {
  bucket = aws_s3_bucket.eb_app_bucket.id
  key    = "app-${data.archive_file.app_zip.output_md5}.zip"
  source = data.archive_file.app_zip.output_path
}

resource "aws_elastic_beanstalk_application_version" "app_version" {
  name        = "${var.app_name}-${var.environment}-${data.archive_file.app_zip.output_md5}"
  application = aws_elastic_beanstalk_application.app.name
  description = "Application version updated by Terraform"
  bucket      = aws_s3_bucket.eb_app_bucket.id
  key         = aws_s3_object.app_zip.id
}

resource "aws_elastic_beanstalk_environment" "env" {
  name                = "${var.app_name}-${var.environment}-env"
  application         = aws_elastic_beanstalk_application.app.name
  solution_stack_name = var.beanstalk_solution_stack
  tier                = "WebServer"
  version_label       = aws_elastic_beanstalk_application_version.app_version.name

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.beanstalk_ec2_profile.name
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "SecurityGroups"
    value     = aws_security_group.beanstalk_sg.id
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = var.beanstalk_instance_type
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "VPCId"
    value     = aws_vpc.main.id
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "Subnets"
    value     = join(",", [aws_subnet.public_1.id, aws_subnet.public_2.id])
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "AssociatePublicIpAddress"
    value     = "true"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "SingleInstance"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "ServiceRole"
    value     = aws_iam_role.beanstalk_service_role.arn
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "DATABASE_URL"
    # Constructing the postgres connection url based on the RDS resource
    value     = "postgresql://${var.db_username}:${var.db_password}@${aws_db_instance.postgres.endpoint}/${var.db_name}"
  }
}
