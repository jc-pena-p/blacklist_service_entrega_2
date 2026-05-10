resource "aws_s3_bucket" "ci_artifacts" {
  bucket_prefix = "${var.app_name}-${var.environment}-ci-artifacts-"
  force_destroy = true

  tags = {
    Name        = "${var.app_name}-${var.environment}-ci-artifacts"
    Environment = var.environment
  }
}

resource "aws_iam_role" "codebuild_role" {
  name = "${var.app_name}-${var.environment}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = "${var.app_name}-${var.environment}-codebuild-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.ci_artifacts.arn,
          "${aws_s3_bucket.ci_artifacts.arn}/*"
        ]
      },
      # Permisos para autenticarse y hacer push de la imagen Docker a ECR.
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.app.arn
      }
    ]
  })
}

resource "aws_codebuild_project" "ci" {
  name          = "${var.app_name}-${var.environment}-ci"
  description   = "Build stage of the CI pipeline for ${var.app_name}"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 10

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    # Privileged mode habilita el daemon de Docker dentro del contenedor de CodeBuild,
    # que es necesario para correr `docker build` y `docker push` desde el buildspec.
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.app.name
    }
    environment_variable {
      name  = "CONTAINER_NAME"
      value = local.ecs_container_name
    }
    environment_variable {
      name  = "EXECUTION_ROLE_ARN"
      value = aws_iam_role.ecs_task_execution.arn
    }
    environment_variable {
      name  = "TASK_ROLE_ARN"
      value = aws_iam_role.ecs_task.arn
    }
    environment_variable {
      name  = "DATABASE_URL"
      value = local.database_url
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.app_name}-${var.environment}"
      stream_name = "ci"
    }
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-ci"
    Environment = var.environment
  }
}

resource "aws_codecommit_repository" "app" {
  repository_name = "${var.app_name}-${var.environment}-repo"
  description     = "Source repository for the blacklist-service pipeline"
  default_branch  = var.ci_branch
}

# -----------------------------------------------------------------------------
# EventBridge rule para auto-trigger del pipeline ante commits a la rama
# configurada (var.ci_branch) en CodeCommit.
#
# Cuando se cambia el source provider de un pipeline de CodeStarSourceConnection
# (que usa webhooks gestionados por AWS) a CodeCommit, AWS deja de inyectar el
# webhook automático. Hay que crear un EventBridge rule explícito que escuche
# el evento `referenceUpdated` en la rama y dispare `StartPipelineExecution`.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eventbridge_codepipeline" {
  name = "${var.app_name}-${var.environment}-eb-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_codepipeline" {
  name = "${var.app_name}-${var.environment}-eb-codepipeline-policy"
  role = aws_iam_role.eventbridge_codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["codepipeline:StartPipelineExecution"]
        Resource = aws_codepipeline.ci.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "codecommit_master" {
  name        = "${var.app_name}-${var.environment}-codecommit-${var.ci_branch}"
  description = "Trigger CodePipeline when commits land on ${var.ci_branch} of the CodeCommit repo"

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = [aws_codecommit_repository.app.arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = [var.ci_branch]
    }
  })
}

resource "aws_cloudwatch_event_target" "codepipeline" {
  rule     = aws_cloudwatch_event_rule.codecommit_master.name
  arn      = aws_codepipeline.ci.arn
  role_arn = aws_iam_role.eventbridge_codepipeline.arn
}

resource "aws_iam_role" "codepipeline_role" {
  name = "${var.app_name}-${var.environment}-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "${var.app_name}-${var.environment}-codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketVersioning",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.ci_artifacts.arn,
          "${aws_s3_bucket.ci_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = aws_codebuild_project.ci.arn
      },
      # Permisos para que CodePipeline pueda leer del repositorio CodeCommit.
      {
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:GetRepository",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:UploadArchive",
          "codecommit:CancelUploadArchive"
        ]
        Resource = aws_codecommit_repository.app.arn
      },
      # Permisos para invocar CodeDeploy desde la etapa Deploy del pipeline.
      {
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          "codedeploy:GetDeploymentGroup",
          "codedeploy:RegisterApplicationRevision",
          "codedeploy:ListApplications",
          "codedeploy:ListDeploymentGroups"
        ]
        Resource = "*"
      },
      # Permisos para que CodePipeline pueda registrar nuevas revisiones del
      # task definition y leer el estado del cluster/servicio ECS.
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = "*"
      },
      # PassRole es indispensable: el pipeline necesita pasar los roles a ECS
      # cuando registra una nueva task definition.
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn
        ]
        Condition = {
          StringEqualsIfExists = {
            "iam:PassedToService" = ["ecs-tasks.amazonaws.com"]
          }
        }
      }
    ]
  })
}

resource "aws_codepipeline" "ci" {
  name     = "${var.app_name}-${var.environment}-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.ci_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName       = aws_codecommit_repository.app.repository_name
        BranchName           = var.ci_branch
        # Polling deshabilitado — usamos EventBridge para los triggers, es
        # el patrón recomendado por AWS para CodeCommit + CodePipeline.
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.ci.name
      }
    }
  }

  # Etapa Deploy — Entrega 3.
  # Provider CodeDeployToECS hace Blue/Green sobre el servicio ECS:
  #   1. Sustituye <IMAGE1_NAME> en taskdef.json con la URI de imageDetail.json.
  #   2. Registra una nueva revisión del task definition.
  #   3. Sustituye <TASK_DEFINITION> en appspec.yaml con el ARN nuevo.
  #   4. Llama a CodeDeploy para hacer el switch Blue→Green con tráfico controlado.
  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.app.name
        DeploymentGroupName            = aws_codedeploy_deployment_group.app.deployment_group_name
        TaskDefinitionTemplateArtifact = "build_output"
        TaskDefinitionTemplatePath     = "taskdef.json"
        AppSpecTemplateArtifact        = "build_output"
        AppSpecTemplatePath            = "appspec.yaml"
        Image1ArtifactName             = "build_output"
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }
}
