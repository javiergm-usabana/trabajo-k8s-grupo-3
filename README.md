# KubeScope

Microservicio NestJS que expone información del runtime para demostrar despliegues multiambiente, GitOps y observabilidad sobre Kubernetes.

## Preparar VS Code

Abre como carpeta exactamente `Actividad_3`, crea una terminal nueva y ejecuta:

```powershell
.\setup-vscode.ps1
```

La configuración incluida en `.vscode` abre PowerShell dentro del proyecto con
permiso de ejecución limitado a esa terminal. También expone tareas desde
`Terminal > Run Task` para Docker Compose, Minikube, NGINX y Prometheus.

## Requisitos

- Node.js 20 o superior
- npm 10 o superior

## Ejecución local

```bash
npm install
npm run start:dev
```

La aplicación escucha en `http://localhost:3000`.

También puede iniciarse mediante Docker Compose:

```bash
docker compose up --build
```

## Endpoints

- `GET /health`: estado para readiness y liveness probes.
- `GET /info`: nombre, versión, ambiente, Pod, namespace y nodo.
- `GET /config`: configuración externa visible del ambiente.
- `GET /metrics`: métricas de Node.js y métricas propias en formato Prometheus.

## Configuración

La aplicación utiliza variables de entorno y conserva valores locales seguros cuando se ejecuta fuera de Kubernetes:

| Variable | Valor local |
| --- | --- |
| `APP_NAME` | `kubescope` |
| `APP_ENV` | `local` |
| `APP_VERSION` | `dev` |
| `APP_MESSAGE` | `KubeScope - Local Development` |
| `FEATURE_EXPERIMENTAL` | `false` |
| `POD_NAME` | `local` |
| `POD_NAMESPACE` | `local` |
| `NODE_NAME` | `local` |

En Kubernetes, `POD_NAME`, `POD_NAMESPACE` y `NODE_NAME` se inyectarán mediante Downward API; no formarán parte de la imagen.

## Validación

```bash
npm test
npm run build
```

## Docker

La imagen utiliza dos etapas: la primera instala dependencias y compila NestJS;
la segunda conserva únicamente el runtime, las dependencias de producción y
`dist`. El proceso dentro del contenedor se ejecuta como un usuario sin
privilegios.

```bash
docker build -t kubescope:local .
docker run --rm -p 3000:3000 kubescope:local
```

Validación rápida:

```bash
curl http://localhost:3000/health
curl http://localhost:3000/info
curl http://localhost:3000/metrics
```

## Helm y Kubernetes

El chart está en `helm/kubescope` y contiene configuración diferenciada para
DEV, STG y PROD. Para la primera prueba local, carga la imagen en Minikube y
despliega DEV:

```bash
minikube start
minikube image load kubescope:local
helm lint ./helm/kubescope
helm upgrade --install kubescope-dev ./helm/kubescope \
  -f ./helm/kubescope/values-dev.yaml \
  --namespace kubescope-dev \
  --create-namespace
kubectl get pods -n kubescope-dev
kubectl port-forward service/kubescope-dev 8080:80 -n kubescope-dev
```

Mientras el port-forward esté activo, valida en otra terminal:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/info
curl http://localhost:8080/config
```

`/info` debe mostrar el nombre real del Pod, el namespace `kubescope-dev` y el
nodo obtenidos mediante Kubernetes Downward API.

Para construir la imagen y desplegar automáticamente DEV, STG, PROD y NGINX en
Minikube desde PowerShell:

```powershell
.\deploy-minikube.ps1
```

Si el perfil local queda con `apiserver: Stopped`, puede recrearse usando
`containerd` y volver a desplegarse completamente:

```powershell
.\deploy-minikube.ps1 -RecreateCluster
```

Esta variante elimina solamente el perfil local `minikube`; no elimina el
código fuente ni las imágenes almacenadas en Docker Desktop.

El mismo script habilita Metrics Server e instala una instancia ligera de
Prometheus. Prometheus descubre automáticamente los Pods KubeScope mediante sus
anotaciones y añade las etiquetas `application`, `environment`, `namespace` y
`pod`.

Para abrir Prometheus:

```powershell
kubectl port-forward service/prometheus-server 9090:80 -n monitoring
```

Después abre `http://localhost:9090` y consulta:

```promql
kubescope_http_requests_total
```

```promql
sum by (environment) (rate(kubescope_http_requests_total[1m]))
```

## ArgoCD

La carpeta `argocd` contiene una instalación ligera y un `ApplicationSet` que
genera las aplicaciones `kubescope-dev`, `kubescope-stg` y `kubescope-prod`.

Después de publicar este proyecto en GitHub:

```powershell
.\install-argocd.ps1 -RepoUrl https://github.com/USUARIO/kubescope.git
```

Para este repositorio privado basta ejecutar `install-argocd.ps1` sin
argumentos. El script solicita de forma oculta un token GitHub classic con
permisos `repo` y `read:packages`. El token se guarda solamente como Secrets de
Kubernetes para que ArgoCD lea Git y los Pods descarguen imágenes privadas de
GHCR; no se escribe en el repositorio ni en archivos locales.

El ApplicationSet usa sincronización automática, `prune`, `selfHeal` y
`CreateNamespace=true`.
