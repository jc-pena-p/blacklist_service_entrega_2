# Microservicio de blacklist global

Microservicio REST en Flask para la gestion de lista negra global de emails.

## Endpoints

### POST /blacklists
Agrega un email a la blacklist.

Body JSON:
```json
{
  "email": "persona@example.com",
  "app_uuid": "550e8400-e29b-41d4-a716-446655440000",
  "blocked_reason": "fraude"
}
```

### GET /blacklists/<email>
Consulta si un email esta en la blacklist.

### GET /health
Endpoint adicional para health checks en AWS Elastic Beanstalk.

## Autenticacion
Todos los endpoints funcionales usan bearer token estatico:

```text
Authorization: Bearer devops-static-token
```

En produccion configure el token en la variable de entorno `AUTH_TOKEN`.

## Variables de entorno

- `DATABASE_URL`: conexion a PostgreSQL o RDS.
- `AUTH_TOKEN`: token bearer estatico.
- `JWT_SECRET_KEY`: secreto de Flask JWT Extended.

## Ejecucion local

```bash
poetry install
export AUTH_TOKEN=devops-static-token  # En Windows PowerShell use: $env:AUTH_TOKEN="devops-static-token"
poetry run python application.py
```

# 🚀 Pruebas con cURL - Blacklist Service

Base URL:
```

[http://127.0.0.1:5000](http://127.0.0.1:5000)

```

Token de autorización:
```

Bearer devops-static-token

```

---

## ✅ 1. Health Check

```bash
curl http://127.0.0.1:5000/health
```

---

## ✅ 2. Agregar email a blacklist (POST /blacklists)

```bash
curl -X POST http://127.0.0.1:5000/blacklists \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer devops-static-token" \
  -d '{
    "email": "test@example.com",
    "app_uuid": "123e4567-e89b-12d3-a456-426614174000",
    "blocked_reason": "spam"
  }'
```

---

## ✅ 3. Consultar email en blacklist (GET /blacklists/{email})

```bash
curl -X GET http://127.0.0.1:5000/blacklists/test@example.com \
  -H "Authorization: Bearer devops-static-token"
```

---

## ❌ 4. Prueba sin token (debe fallar)

```bash
curl -X GET http://127.0.0.1:5000/blacklists/test@example.com
```

---

## ❌ 5. UUID inválido (validación)

```bash
curl -X POST http://127.0.0.1:5000/blacklists \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer devops-static-token" \
  -d '{
    "email": "bad@example.com",
    "app_uuid": "uuid-invalido",
    "blocked_reason": "spam"
  }'
```

---

## 🧪 6. Email inválido

```bash
curl -X POST http://127.0.0.1:5000/blacklists \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer devops-static-token" \
  -d '{
    "email": "no-es-email",
    "app_uuid": "123e4567-e89b-12d3-a456-426614174000",
    "blocked_reason": "spam"
  }'
```

## Pruebas unitarias

```bash
pytest -q
```

## Despliegue Automatizado con Terraform (AWS)

La infraestructura y la aplicación pueden desplegarse con los scripts de Terraform que se encuentran en el directorio `terraform/`. 
Estos scripts aprovisionan un bucket en S3 para la carga del código (app.zip), una base de datos PostgreSQL en Amazon RDS, la VPC requerida y un entorno en AWS Elastic Beanstalk.

### Prerrequisitos
- Tener las credenciales de Amazon Web Services (AWS) configuradas localmente. (~/.aws/credentials)
- Instalar Terraform en el sistema.

### Pasos para Desplegar
1. Inicializar el entorno de Terraform:
```bash
cd terraform
terraform init
```
2. Ejecutar el plan y aplicar los recursos. Se solicitarán el nombre de usuario y contraseña para la base de datos de Postgres.
```bash
terraform apply
```

### Configuración de la Estrategia de Despliegue (Deployment Policies)

Para configurar Terraform para aprovisionar las siguientes arquitecturas se debe modificar el archivo `terraform/beanstalk.tf`. 
Se deben agregar los siguientes bloques dentro del recurso `aws_elastic_beanstalk_environment`:

#### 1. Estrategia Inmutable (Immutable)
Beanstalk lanza una nueva instancia en otro Auto Scaling Group. Si pasa los *health checks*, balancea el tráfico hacia ella y destruye las antiguas. Funciona con esquemas `SingleInstance` o `LoadBalanced`:
```hcl
  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "DeploymentPolicy"
    value     = "Immutable"
  }
```

#### 2. Estrategia Rolling (Por Lotes)
Actualiza iterativamente los servidores sin dejar al sistema por fuera de servicio. **Requiere contar mínimo con un entorno de LoadBalancer y más de 1 instancia.**
```hcl
  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "LoadBalanced"
  }
  
  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MinSize"
    value     = "2"
  }
  
  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MaxSize"
    value     = "4"
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "DeploymentPolicy"
    value     = "Rolling" # O puede ser "RollingWithAdditionalBatch"
  }
  
  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSizeType"
    value     = "Fixed"
  }
  
  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSize"
    value     = "1"
  }
```

#### 3. Estrategia Traffic Splitting (Canary / División de tráfico)
Despliega las nuevas versiones en un batch separado, pero redirige un % controlado del tráfico para detectar posibles anomalías antes del reemplazo general de versión. **Requiere ALB (Application Load Balancer) y LoadBalanced Environment**:
```hcl
  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "LoadBalanced"
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "DeploymentPolicy"
    value     = "TrafficSplitting"
  }

  setting {
    namespace = "aws:elasticbeanstalk:trafficsplitting"
    name      = "NewVersionPercent"
    value     = "15" # Redirige el 15% del tráfico a la nueva versión
  }

  setting {
    namespace = "aws:elasticbeanstalk:trafficsplitting"
    name      = "EvaluationTime"
    value     = "5" # Evalúa errores en minutos
  }
```

## Entrega 2 - Pipeline de Integración Continua (CI)

A partir de la Entrega 2 el repositorio cuenta con un pipeline de **Integración Continua** sobre AWS que se dispara automáticamente con cada push a la rama `master`. El pipeline ejecuta las pruebas unitarias y, si pasan en verde, genera un artefacto `.zip` que queda publicado en un bucket de S3. Si los tests fallan, el pipeline aborta antes del empaquetado y no se genera artefacto.

**Arquitectura:** GitHub → AWS CodeConnections (anteriormente CodeStar Connections) → AWS CodePipeline → AWS CodeBuild → S3.

**Esta entrega NO incluye despliegue automatizado (CD)** por requerimiento explícito del enunciado: el artefacto se genera pero no se despliega a Beanstalk desde el pipeline.

### Archivos clave de la Entrega 2

- `buildspec.yml` — fases (`install`, `pre_build`, `build`) que CodeBuild ejecuta en cada run.
- `terraform/codebuild.tf` — infraestructura del pipeline (proyecto CodeBuild, CodePipeline, bucket S3 de artefactos, roles IAM, conexión CodeConnections).
- `tests/test_blacklists.py` — 7 escenarios de prueba unitaria que cubren los 3 endpoints (`/health`, `POST /blacklists`, `GET /blacklists/<email>`) más casos de auth y validación.

### Cómo levantar el pipeline

Asumiendo que ya existe un usuario IAM con permisos suficientes y la GitHub App `AWS Connector for GitHub` está instalada sobre el repositorio:

```bash
cd terraform
terraform apply
```

La conexión CodeConnections nace en estado `Pending` y requiere aprobación humana una sola vez en la consola de AWS (Developer Tools → Settings → Connections). Una vez en `Available`, los pushes a master disparan el pipeline automáticamente.

### Documentación de la Entrega 2

- **Informe:** [docs/INFORME_ENTREGA2.md](docs/INFORME_ENTREGA2.md)
- **Video de sustentación:** [Video Entrega 2 DevOps Blacklist-service](https://drive.google.com/file/d/1k0S88Cq0Ksv4nhIDJcWdq5ee_GJHqlaW/view?usp=sharing)

## Despliegue manual en Elastic Beanstalk

1. Cree la base de datos PostgreSQL en RDS y permita el acceso desde el security group del ambiente Beanstalk.
2. En Elastic Beanstalk cree una aplicacion Python Web Server Environment.
3. Configure las variables de entorno:
   - `DATABASE_URL`
   - `AUTH_TOKEN`
   - `JWT_SECRET_KEY`
4. Suba un ZIP con el contenido raiz del proyecto, incluyendo `application.py`, `requirements.txt`, `Procfile`, `.ebextensions` y la carpeta `app`.
5. Configure el health check path como `/health`.
6. Valide los endpoints con Postman usando la URL publica del ambiente.

## Respuestas sugeridas

### POST exitoso
```json
{
  "message": "Email added to blacklist",
  "data": {
    "email": "persona@example.com",
    "app_uuid": "550e8400-e29b-41d4-a716-446655440000",
    "blocked_reason": "fraude",
    "request_ip": "127.0.0.1",
    "created_at": "2026-04-07T00:00:00Z"
  }
}
```

### GET si existe
```json
{
  "email": "persona@example.com",
  "is_blacklisted": true,
  "blocked_reason": "fraude"
}
```

### GET si no existe
```json
{
  "email": "persona@example.com",
  "is_blacklisted": false,
  "blocked_reason": null
}
```
