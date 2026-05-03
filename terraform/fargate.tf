###############################################################################
# Entrega 3 — CD a AWS Fargate con CodeDeploy Blue/Green
#
# Este archivo aprovisiona toda la infraestructura nueva para el despliegue
# continuo. Se apoya en los recursos ya creados en Entrega 1 y 2:
#   - VPC, subnets, internet gateway (main.tf)
#   - RDS Postgres + rds_sg (rds.tf, main.tf)
#   - CodeBuild project, CodePipeline, CodeStar Connection (codebuild.tf)
###############################################################################

# -----------------------------------------------------------------------------
# Datos de la cuenta (necesarios para construir URIs de ECR, ARNs, etc.)
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

locals {
  ecs_container_name = "${var.app_name}-${var.environment}-container"
  ecs_task_family    = "${var.app_name}-${var.environment}-task"
  ecs_log_group_name = "/ecs/${var.app_name}-${var.environment}"
  database_url       = "postgresql://${var.db_username}:${var.db_password}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${var.db_name}"
}

# -----------------------------------------------------------------------------
# Repositorio ECR (Elastic Container Registry) para la imagen Docker
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name                 = "${var.app_name}-${var.environment}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-app"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# Security Groups
#   - alb_sg: ALB acepta tráfico HTTP del mundo en :80 (prod) y :8080 (test).
#   - ecs_service_sg: las tareas Fargate aceptan tráfico solo desde el ALB.
#   - rds_from_ecs: regla extra al RDS para aceptar conexiones desde ECS.
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb_sg" {
  name        = "${var.app_name}-${var.environment}-alb-sg"
  description = "Security group for the public Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Production traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Test traffic for Blue/Green deployments"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-alb-sg"
    Environment = var.environment
  }
}

resource "aws_security_group" "ecs_service_sg" {
  name        = "${var.app_name}-${var.environment}-ecs-service-sg"
  description = "Security group for the ECS Fargate tasks running the application"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Application traffic from the ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-ecs-service-sg"
    Environment = var.environment
  }
}

# Permite que las tareas ECS se conecten al RDS Postgres ya existente.
resource "aws_security_group_rule" "rds_from_ecs" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_sg.id
  source_security_group_id = aws_security_group.ecs_service_sg.id
  description              = "Allow ECS tasks to reach the RDS Postgres instance"
}

# -----------------------------------------------------------------------------
# Application Load Balancer + Target Groups (azul y verde) + Listeners
# -----------------------------------------------------------------------------
resource "aws_lb" "app" {
  name               = "${var.app_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = {
    Name        = "${var.app_name}-${var.environment}-alb"
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "blue" {
  name        = "${var.app_name}-${var.environment}-tg-blue"
  port        = 5000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name        = "${var.app_name}-${var.environment}-tg-blue"
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.app_name}-${var.environment}-tg-green"
  port        = 5000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name        = "${var.app_name}-${var.environment}-tg-green"
    Environment = var.environment
  }
}

# Listener de producción (puerto 80). CodeDeploy va a reescribir su default_action
# durante cada deployment Blue/Green para apuntar al target group activo.
resource "aws_lb_listener" "prod" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

# Listener de pruebas (puerto 8080). Lo usa CodeDeploy para validar la nueva
# versión antes de cambiar el tráfico de producción.
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.app.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group para ECS
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ecs" {
  name              = local.ecs_log_group_name
  retention_in_days = 7

  tags = {
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# IAM Role: ECS Task Execution Role
# Lo asume el agente de ECS para descargar la imagen de ECR y mandar logs
# a CloudWatch.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.app_name}-${var.environment}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# -----------------------------------------------------------------------------
# IAM Role: ECS Task Role
# Lo asume el contenedor mismo. Por ahora no hace nada (la app no llama a AWS),
# pero queda creado para que el taskdef.json pueda referenciarlo siempre.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task" {
  name = "${var.app_name}-${var.environment}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# ECS Cluster
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "app" {
  name = "${var.app_name}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# ECS Task Definition (revisión inicial)
#
# Esta es la primera revisión del task definition; CodeDeploy creará nuevas
# revisiones en cada deploy reemplazando la imagen. Por eso hacemos
# `ignore_changes` sobre container_definitions.
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = local.ecs_task_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = local.ecs_container_name
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 5000
          hostPort      = 5000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "DATABASE_URL", value = local.database_url },
        { name = "AUTH_TOKEN", value = "devops-static-token" },
        { name = "JWT_SECRET_KEY", value = "devops-jwt-secret" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  lifecycle {
    ignore_changes = [container_definitions]
  }

  tags = {
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# ECS Service (con deployment controller = CODE_DEPLOY)
#
# CodeDeploy va a manejar las transiciones Blue/Green entre target groups y
# task definitions. Por eso hacemos `ignore_changes` sobre task_definition y
# load_balancer.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${var.app_name}-${var.environment}-service"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = [aws_subnet.public_1.id, aws_subnet.public_2.id]
    security_groups  = [aws_security_group.ecs_service_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = local.ecs_container_name
    container_port   = 5000
  }

  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  depends_on = [
    aws_lb_listener.prod,
    aws_lb_listener.test,
  ]

  tags = {
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# IAM Role: CodeDeploy ECS
# Lo asume CodeDeploy para hacer Blue/Green deployments contra ECS.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "codedeploy_ecs" {
  name = "${var.app_name}-${var.environment}-codedeploy-ecs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy_ecs" {
  role       = aws_iam_role.codedeploy_ecs.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# -----------------------------------------------------------------------------
# CodeDeploy Application + Deployment Group (Blue/Green sobre ECS)
# -----------------------------------------------------------------------------
resource "aws_codedeploy_app" "app" {
  compute_platform = "ECS"
  name             = "${var.app_name}-${var.environment}-cd-app"
}

resource "aws_codedeploy_deployment_group" "app" {
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = "${var.app_name}-${var.environment}-cd-dg"
  service_role_arn       = aws_iam_role.codedeploy_ecs.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.app.name
    service_name = aws_ecs_service.app.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.prod.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }
      target_group {
        name = aws_lb_target_group.blue.name
      }
      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}
