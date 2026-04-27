# Proyecto Blacklist-service

## Entrega 2 - Informe

## 1. Integrantes : _Grupo 12_

- Oscar Saraza
- Keneth Bravo
- Juan Camilo Peña
- David Gutierrez

**Link Video Presentación Entrega 2:** [Video Entrega 2 DevOps Blacklist-service](https://drive.google.com/file/d/1k0S88Cq0Ksv4nhIDJcWdq5ee_GJHqlaW/view?usp=sharing)

## 2. Descripcion de la solucion

Sobre la base del microservicio desplegado en la Entrega 1, el equipo construyó un pipeline de **Integración Continua (CI)** que se dispara automáticamente cada vez que se empuja un commit a la rama `master` del repositorio. El pipeline descarga el código fuente desde GitHub, instala las dependencias del proyecto, ejecuta las pruebas unitarias y, si todo pasa en verde, genera el artefacto `.zip` y lo publica en un bucket de S3. Si alguna prueba falla, el pipeline se detiene en la fase de Build y el artefacto no se genera, evitando que código roto avance a un eventual proceso de despliegue.

La orquestación se implementó con **AWS CodePipeline** usando dos etapas: una etapa `Source` que se conecta al repositorio de GitHub mediante una conexión de **AWS CodeConnections** (servicio renombrado desde *CodeStar Connections* en julio de 2024; el recurso de Terraform conserva el nombre `aws_codestarconnections_connection` por compatibilidad hacia atrás) usando la **GitHub App "AWS Connector for GitHub"**, y una etapa `Build` que invoca un proyecto de **AWS CodeBuild** parametrizado con el archivo `buildspec.yml` del repositorio. Toda la infraestructura del pipeline — bucket S3 de artefactos, roles IAM, proyecto CodeBuild, conexión CodeConnections y el propio CodePipeline — está declarada en Terraform (`terraform/codebuild.tf`) para que cualquier integrante del equipo pueda reproducirla ejecutando `terraform apply`.

Para las pruebas unitarias dentro del CI se optó por usar **SQLite en memoria** (modo `mocks`, sin necesidad de levantar un motor de base de datos dentro de CodeBuild). Esta decisión se tomó porque el microservicio usa SQLAlchemy como capa de abstracción sobre la base de datos: las pruebas validan correctamente la lógica de los endpoints y del ORM sin necesidad de aprovisionar un Postgres adicional dentro del proceso de CI, lo que reduce el tiempo de ejecución del pipeline y simplifica su configuración. La instancia de **RDS Postgres** que aprovisiona Terraform sigue existiendo y es la que utiliza la aplicación cuando está desplegada en Elastic Beanstalk (producción), pero queda completamente fuera del alcance del pipeline de CI.

Esta entrega está enfocada exclusivamente en **CI** y, por requerimiento explícito del enunciado, NO incluye etapa de despliegue automatizado (CD).

## 3. Pruebas unitarias sobre los endpoints

Los escenarios de prueba se encuentran en `tests/test_blacklists.py` y usan las fixtures definidas en `tests/conftest.py`. Cada una de las tres rutas HTTP expuestas por el microservicio tiene al menos un caso de prueba asociado, cumpliendo el requisito de "al menos un escenario de prueba unitaria para cada endpoint de la API".

### 3.1 Mapeo endpoint → escenario

| Endpoint              | Método | Escenario                                                  | Test                                                |
| --------------------- | ------ | ---------------------------------------------------------- | --------------------------------------------------- |
| `/health`             | GET    | Healthcheck responde `200 OK` con `{"status":"ok"}`        | `test_health_endpoint`                              |
| `/blacklists`         | POST   | Creación exitosa devuelve `201`                            | `test_create_blacklist_entry`                       |
| `/blacklists`         | POST   | Email duplicado devuelve `409`                             | `test_create_duplicate_blacklist_entry_returns_409` |
| `/blacklists`         | POST   | Payload inválido devuelve `400` con detalle de errores     | `test_validates_payload`                            |
| `/blacklists/<email>` | GET    | Email registrado devuelve `is_blacklisted=true` con motivo | `test_lookup_blacklisted_email`                     |
| `/blacklists/<email>` | GET    | Email no registrado devuelve `is_blacklisted=false`        | `test_lookup_non_blacklisted_email`                 |
| `/blacklists/<email>` | GET    | Sin token Bearer devuelve `401 Unauthorized`               | `test_requires_bearer_token`                        |

En total son **siete escenarios** que se ejecutan en pocos segundos, tanto localmente (`poetry run pytest -v tests/`) como dentro de la fase `pre_build` del pipeline.

### 3.2 Estrategia de pruebas

Las pruebas usan SQLite en memoria a través de la configuración `testing` de la aplicación (`app/config.py`). El fixture `client` recrea el esquema desde cero antes de cada test (`db.drop_all()` + `db.create_all()`), garantizando aislamiento entre escenarios. El fixture `auth_headers` provee el token Bearer de pruebas (`AUTH_TOKEN=test-token`) que esperan los endpoints protegidos.

![Pruebas unitarias ejecutándose localmente](images/entrega2/tests-local.png)

## 4. Configuración del pipeline de Integración Continua

### 4.1 Archivo buildspec.yml

El comportamiento del build está declarado en el archivo `buildspec.yml` ubicado en la raíz del repositorio. CodeBuild lo lee automáticamente cuando arranca el job:

```yaml
version: 0.2

phases:
  install:
    runtime-versions:
      python: 3.11
    commands:
      - python -m pip install --upgrade pip
      - pip install poetry
      - poetry config virtualenvs.create false
      - poetry install --no-interaction --no-ansi
  pre_build:
    commands:
      - poetry run pytest -v tests/
  build:
    commands:
      - zip -r blacklist-service.zip . -x "tests/*" "terraform/*" "docs/*" ".git/*" ".github/*" "__pycache__/*" "*/__pycache__/*" "*.pyc" ".venv/*" "venv/*" ".pytest_cache/*" "*.db" "*.sqlite3"

artifacts:
  files:
    - blacklist-service.zip
  discard-paths: yes
  name: blacklist-service-$(date +%Y%m%d-%H%M%S)
```

El manejo de dependencias dentro del CI se realiza con **Poetry**, la misma herramienta que usa el equipo en local (`pyproject.toml` + `poetry.lock`). Esto garantiza que las versiones instaladas en CodeBuild sean exactamente las mismas que las de los desarrolladores. La fase `pre_build` corre `pytest`; si algún test falla, CodeBuild aborta antes de la fase `build`, por lo que no se genera artefacto. La fase `build` empaqueta el código de la aplicación dejando por fuera tests, terraform, documentación y archivos efímeros.

### 4.2 Infraestructura del pipeline (Terraform)

Toda la infraestructura del CI se definió en `terraform/codebuild.tf`. Los recursos aprovisionados son:

- **Bucket S3 `blacklist-service-dev-ci-artifacts-*`**: aterrizan tanto el código fuente descargado de GitHub como el `.zip` generado por el build.
- **Proyecto CodeBuild `blacklist-service-dev-ci`**: configurado con `BUILD_GENERAL1_SMALL` sobre la imagen `aws/codebuild/standard:7.0` (Ubuntu, Python 3.11). Como se invoca desde CodePipeline, su fuente y artefactos son de tipo `CODEPIPELINE`.
- **Conexión CodeConnections con GitHub** (vía la GitHub App `AWS Connector for GitHub`): canal por el que CodePipeline detecta cambios en el repositorio.
- **CodePipeline `blacklist-service-dev-pipeline`** con dos etapas:
  - `Source`: CodeConnections/GitHub, rama `master`, `DetectChanges=true`.
  - `Build`: invoca al proyecto CodeBuild.
- **Roles IAM** con políticas mínimas: el rol de CodeBuild tiene permisos de CloudWatch Logs y acceso al bucket de artefactos; el rol de CodePipeline tiene permisos para usar la conexión CodeConnections, disparar builds y leer/escribir en el bucket.

### 4.3 Proyecto CodeBuild

El proyecto CodeBuild lee el `buildspec.yml` del repositorio en cada ejecución, instala Python 3.11 + Poetry, corre los tests y produce el zip como artefacto de salida. El compute type elegido (`SMALL`) es suficiente porque las pruebas son rápidas y la imagen de Python ya está cacheada.

![Proyecto CodeBuild asociado](images/entrega2/codebuild-project.png)

### 4.4 Disparo automático sobre master

La etapa `Source` del pipeline incluye `BranchName = "master"` y `DetectChanges = true`. Con esos dos parámetros, CodePipeline registra internamente un webhook contra la conexión CodeConnections y recibe notificaciones de GitHub cada vez que se empuja un commit a esa rama. Cuando llega la notificación, el pipeline arranca automáticamente desde la etapa `Source`, sin necesidad de activarlo manualmente desde la consola.

El único paso de la infraestructura que no se pudo automatizar completamente con Terraform fue la **autorización inicial de la conexión CodeConnections**: AWS la crea en estado `Pending` y un humano debe aprobarla una sola vez desde la consola, seleccionando la GitHub App ya instalada sobre el repositorio.

![Pipeline creado en CodePipeline](images/entrega2/codepipeline-overview.png)

![Etapa Source configurada](images/entrega2/codepipeline-source-stage.png)

![Etapa Build configurada](images/entrega2/codepipeline-build-stage.png)

![Conexión CodeConnections con GitHub en estado Available](images/entrega2/codestar-connection.png)

![Bucket S3 de artefactos](images/entrega2/s3-artifacts-bucket.png)

## 5. Ejecuciones del pipeline

### 5.1 Ejecución exitosa

#### Disparo del pipeline

Se realizó un push a `master` con un commit ordinario que no altera la lógica de los endpoints. El push se hizo desde la terminal local con `git commit --allow-empty -m "Disparar pipeline EXITOSO" && git push origin master`. CodePipeline detectó el cambio en menos de un minuto y disparó la ejecución con `Trigger: Webhook`.

#### Cómo se validó la ejecución

- En la consola de **CodePipeline**, ambas etapas (`Source` y `Build`) terminaron en estado **Succeeded** (verde).
- Se inspeccionaron los logs de CodeBuild en CloudWatch para verificar que las 7 pruebas pasaron (`7 passed in X.XXs`).
- Se navegó al bucket S3 de artefactos y se confirmó que `blacklist-service.zip` quedó publicado con timestamp posterior al commit.

#### Tiempo total

- Source: 5 s
- Build (install + pre_build + build + upload):1 min 4 s
- **Total pipeline:** ~1 min 9 s

#### Hallazgos

- El pipeline se autodispara correctamente desde el commit a master, validando que el webhook de la conexión CodeConnections quedó bien registrado.
- La fase `install` (descarga de Poetry + dependencias) es la más larga del build.
- El artefacto se genera **únicamente** después de que las pruebas pasan: la fase `build` (empaquetado) corre después de `pre_build` (pytest), garantizando que ningún zip llegue a S3 con código que no compile o que rompa los tests.

#### Capturas

![Pipeline exitoso - vista general](images/entrega2/build-success-overview.png)
![Pipeline exitoso - vista general](images/entrega2/build-success-overview_2.png)
![Logs de pytest en el build exitoso](images/entrega2/build-success-pytest-logs.png)
![Artefacto publicado en S3](images/entrega2/build-success-artifact.png)

---

### 5.2 Ejecución fallida

#### Cambio que rompió las pruebas

Para evidenciar el comportamiento del pipeline ante un cambio inválido se agregó temporalmente al final de `tests/test_blacklists.py` la siguiente prueba forzada a fallar:

```python
def test_forzar_fallo_pipeline():
    assert False
```

Se hizo commit y push a `master` (`git commit -m "Forzar fallo del pipeline (escenario negativo)" && git push origin master`).

#### Cómo se validó la ejecución

- En **CodePipeline** la etapa `Source` terminó en **Succeeded** (verde) porque la descarga del repositorio funcionó.
- La etapa `Build` terminó en **Failed** (rojo).
- Los logs de CodeBuild muestran la línea `FAILED tests/test_blacklists.py::test_forzar_fallo_pipeline` y el resumen final `1 failed, 7 passed`.
- En el bucket S3 se verificó que **no hay un .zip nuevo** posterior al commit fallido — el último artefacto sigue siendo el del run exitoso anterior.

#### Tiempo total

- Source: 2 s
- Build (install + pre_build hasta la falla): 1 min 2 s
- **Total pipeline:** ~1 min 4 s

#### Hallazgos

- Al fallar la fase `pre_build` (pytest), CodeBuild marca el build como `FAILED` y CodePipeline detiene la ejecución sin entrar a `build` (empaquetado) ni a `UPLOAD_ARTIFACTS` (publicación a S3).
- En consecuencia **no se generó artefacto nuevo** en el bucket de CI.
- Inmediatamente después de documentar el fallo se revirtió el commit con `git revert HEAD --no-edit && git push origin master`, lo que disparó una nueva ejecución que terminó en verde y dejó la rama master limpia.

#### Capturas

![Pipeline fallido - vista general](images/entrega2/build-failed-overview.png)
![Logs de pytest en el build fallido](images/entrega2/build-failed-pytest-logs.png)
![Ausencia de nuevo artefacto en S3 tras el fallo](images/entrega2/build-failed-no-artifact.png)

## 6. Aplicación en ejecución sobre AWS Beanstalk

La aplicación desplegada en la Entrega 1 sobre AWS Elastic Beanstalk sigue operativa y accesible vía Postman, en cumplimiento del requisito "Aplicación en ejecución sobre AWS Beanstalk accesible vía Postman" del Lugar y Formato de Entrega.

La documentación de Postman publicada con la colección de pruebas para los endpoints es: [https://documenter.getpostman.com/view/5048503/2sBXitDT2f](https://documenter.getpostman.com/view/5048503/2sBXitDT2f)

## 7. Repositorio GitHub

- URL del repositorio: [https://github.com/jc-pena-p/blacklist_service_entrega_2](https://github.com/jc-pena-p/blacklist_service_entrega_2)
- Rama configurada en el pipeline: `master`
- Conexión a AWS: GitHub App **AWS Connector for GitHub** instalada sobre el repositorio + conexión **AWS CodeConnections** en estado `Available`.

> El repositorio es un **fork** del original `KenethBravoP/blacklist_service`. La razón del fork fue poder instalar la GitHub App sobre el repositorio (solo el owner puede hacerlo), requisito indispensable para que la conexión CodeConnections pase a estado `Available` y CodePipeline pueda registrar el webhook de disparo automático.

## 8. Conclusiones

La arquitectura basada en CodePipeline y CodeBuild se ajustó naturalmente al alcance de la entrega: una etapa detecta los cambios en el repositorio y otra ejecuta la construcción del artefacto, separando responsabilidades sin agregar complejidad. Tener toda la infraestructura declarada en Terraform fue determinante para la velocidad del trabajo, ya que permitió iterar y recuperar el estado de los recursos de forma reproducible ante cualquier inconveniente.

El punto más delicado del proceso fue la integración entre AWS y GitHub a través de la conexión CodeConnections (servicio anteriormente conocido como CodeStar Connections), donde es necesario distinguir entre autorizar la aplicación y posteriormente instalarla sobre un repositorio en el que el integrante tenga permisos de owner. Esta es la única parte del flujo que no se logró automatizar completamente con Terraform, y queda documentada para futuras entregas.
