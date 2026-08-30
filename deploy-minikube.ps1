[CmdletBinding()]
param(
    [ValidateRange(2200, 3800)]
    [int]$MemoryMb = 3000,

    [ValidateRange(2, 8)]
    [int]$Cpus = 2,

    [string]$KubernetesVersion = 'v1.32.0',

    [ValidateSet('containerd', 'docker')]
    [string]$ContainerRuntime = 'containerd',

    [string]$PrometheusChartVersion = '29.27.0',

    [switch]$RecreateCluster,

    [switch]$SkipToolInstallation
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$chartPath = Join-Path $projectRoot 'helm\kubescope'
$prometheusValuesPath = Join-Path $projectRoot 'monitoring\prometheus-values.yaml'

function Initialize-ToolPath {
    $toolDirectories = @(
        'C:\Program Files\Docker\Docker\resources\bin',
        'C:\Program Files\Kubernetes\Minikube',
        'C:\Program Files\ArgoCD',
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        (Join-Path $env:USERPROFILE 'scoop\shims'),
        'C:\ProgramData\chocolatey\bin'
    )

    foreach ($directory in $toolDirectories) {
        if ((Test-Path -LiteralPath $directory) -and
            (($env:Path -split ';') -notcontains $directory)) {
            $env:Path += ";$directory"
        }
    }
}

function Update-ProcessPath {
    $pathEntries = @(
        ($env:Path -split ';')
        ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
        ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $env:Path = ($pathEntries | Select-Object -Unique) -join ';'
    Initialize-ToolPath
}

function Ensure-Command {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WinGetId
    )

    if (Get-Command $Name -ErrorAction SilentlyContinue) {
        Write-Host "[OK] $Name disponible." -ForegroundColor Green
        return
    }

    if ($SkipToolInstallation) {
        throw "No se encontro '$Name' en PATH y se omitio la instalacion automatica."
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "No se encontro '$Name' ni WinGet. Instala App Installer desde Microsoft Store y vuelve a ejecutar el script."
    }

    Write-Host "Instalando herramienta requerida: $Name ($WinGetId)..." -ForegroundColor Yellow
    & winget install --id $WinGetId --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet no pudo instalar '$Name' ($WinGetId)."
    }

    Update-ProcessPath

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' fue instalado, pero la terminal aun no puede encontrarlo. Cierra VS Code, abrelo nuevamente y vuelve a ejecutar el script."
    }

    Write-Host "[OK] $Name instalado y disponible." -ForegroundColor Green
}

function Wait-KubernetesApi {
    param([int]$TimeoutSeconds = 360)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Host 'Esperando que Kubernetes API responda...'

    while ((Get-Date) -lt $deadline) {
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $readyOutput = (& kubectl --context minikube get --raw=/readyz 2>&1 | Out-String)
        $readyExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorAction

        if ($readyExitCode -eq 0 -and $readyOutput -match 'ok') {
            Write-Host '[OK] Kubernetes API esta disponible.' -ForegroundColor Green
            return
        }

        Start-Sleep -Seconds 10
    }

    throw 'Kubernetes API no estuvo disponible dentro de 6 minutos. Ejecuta minikube logs --problems.'
}

Initialize-ToolPath

$requiredTools = @(
    @{ Name = 'docker';   WinGetId = 'Docker.DockerDesktop' },
    @{ Name = 'minikube'; WinGetId = 'Kubernetes.minikube' },
    @{ Name = 'kubectl';  WinGetId = 'Kubernetes.kubectl' },
    @{ Name = 'helm';     WinGetId = 'Helm.Helm' }
    @{ Name = 'argocd';   WinGetId = 'argoproj.argocd' }
)

foreach ($tool in $requiredTools) {
    Ensure-Command -Name $tool.Name -WinGetId $tool.WinGetId
}

Push-Location $projectRoot
try {
    Write-Host '1/10 Verificando Docker y Minikube...'

    # Los comandos nativos escriben diagnosticos esperados en stderr cuando el
    # cluster aun no existe. PowerShell no debe convertirlos en una excepcion.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $dockerStatus = (& docker info 2>&1 | Out-String)
    $dockerExitCode = $LASTEXITCODE
    $status = (& minikube status 2>&1 | Out-String)
    $statusExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction

    if ($dockerExitCode -ne 0) {
        throw "Docker Desktop no esta disponible. Inicialo y vuelve a ejecutar la tarea.`n$dockerStatus"
    }

    if ($RecreateCluster) {
        Write-Warning 'Se eliminara solamente el perfil local roto llamado minikube y se recreara desde cero.'
        & minikube delete --profile minikube
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo eliminar el perfil minikube.' }
        $statusExitCode = 1
        $status = ''
    }

    if ($statusExitCode -ne 0 -or $status -notmatch 'apiserver:\s+Running') {
        Write-Host 'Minikube no esta listo; iniciandolo...'

        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & minikube start --profile minikube --driver=docker --container-runtime=$ContainerRuntime --kubernetes-version=$KubernetesVersion --cpus=$Cpus --memory=$MemoryMb --wait=apiserver,system_pods --wait-timeout=6m0s
        $startExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorAction

        if ($startExitCode -ne 0) {
            Write-Warning 'Minikube informo errores durante el arranque; se verificara directamente el API server.'
        }
    }

    Wait-KubernetesApi

    # Estos addons pueden fallar de forma transitoria durante la creacion del
    # control plane. Se reintentan cuando el API ya responde.
    & minikube addons enable storage-provisioner
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo habilitar storage-provisioner.' }
    & minikube addons enable default-storageclass
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo habilitar default-storageclass.' }

    Write-Host '2/10 Construyendo kubescope:local...'
    & docker build -t kubescope:local .
    if ($LASTEXITCODE -ne 0) { throw 'La imagen Docker no pudo construirse.' }

    Write-Host '3/10 Cargando imagen dentro de Minikube...'
    & minikube image load kubescope:local
    if ($LASTEXITCODE -ne 0) { throw 'La imagen no pudo cargarse en Minikube.' }

    Write-Host '4/10 Habilitando NGINX Ingress y Metrics Server...'
    & minikube addons enable ingress
    if ($LASTEXITCODE -ne 0) { throw 'NGINX Ingress no pudo habilitarse.' }
    & minikube addons enable metrics-server
    if ($LASTEXITCODE -ne 0) { throw 'Metrics Server no pudo habilitarse.' }
    & kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

    Write-Host '5/10 Validando el chart Helm...'
    & helm lint $chartPath
    if ($LASTEXITCODE -ne 0) { throw 'El chart Helm no paso la validacion.' }

    $environments = @(
        @{ Release = 'kubescope-dev';  Namespace = 'kubescope-dev';  Values = 'values-dev.yaml' },
        @{ Release = 'kubescope-stg';  Namespace = 'kubescope-stg';  Values = 'values-stg.yaml' },
        @{ Release = 'kubescope-prod'; Namespace = 'kubescope-prod'; Values = 'values-prod.yaml' }
    )

    Write-Host '6/10 Desplegando DEV, STG y PROD...'
    foreach ($environment in $environments) {
        $valuesPath = Join-Path $chartPath $environment.Values
        & helm upgrade --install $environment.Release $chartPath `
            -f $valuesPath `
            --namespace $environment.Namespace `
            --create-namespace `
            --set image.repository=kubescope `
            --set image.tag=local `
            --set image.pullPolicy=Never `
            --set app.version=local

        if ($LASTEXITCODE -ne 0) {
            throw "Fallo el despliegue de $($environment.Release)."
        }
    }

    Write-Host '7/10 Esperando los Deployments...'
    foreach ($environment in $environments) {
        & kubectl rollout status "deployment/$($environment.Release)" -n $environment.Namespace --timeout=180s
        if ($LASTEXITCODE -ne 0) {
            throw "$($environment.Release) no quedo disponible."
        }
    }

    Write-Host '8/10 Instalando Prometheus...'
    & helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo configurar el repositorio de Prometheus.' }
    & helm repo update
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron actualizar los repositorios Helm.' }
    & helm upgrade --install prometheus prometheus-community/prometheus `
        --version $PrometheusChartVersion `
        --reset-values `
        --namespace monitoring `
        --create-namespace `
        -f $prometheusValuesPath
    if ($LASTEXITCODE -ne 0) { throw 'Prometheus no pudo instalarse.' }

    # La primera revision pudo conservar un ConfigMap invalido. Un reinicio
    # garantiza que el servidor monte la configuracion renderizada actual.
    & kubectl rollout restart deployment/prometheus-server -n monitoring
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo reiniciar Prometheus.' }

    Write-Host '9/10 Esperando Prometheus y Metrics Server...'
    & kubectl get pods -n monitoring -o wide
    & kubectl rollout status deployment/prometheus-server -n monitoring --timeout=600s
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Prometheus no quedo disponible. Diagnostico automatico:'
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & kubectl get pods -n monitoring -o wide
        & kubectl describe pods -n monitoring
        & kubectl logs -n monitoring deployment/prometheus-server --all-containers=true --tail=200
        & kubectl get events -n monitoring --sort-by=.lastTimestamp
        $ErrorActionPreference = $previousErrorAction
        throw 'Prometheus no quedo disponible; revisa el diagnostico anterior.'
    }
    & kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw 'Metrics Server no quedo disponible.' }

    Write-Host '10/10 Estado final:'
    & kubectl get pods -A -l app.kubernetes.io/name=kubescope
    & kubectl get ingress -A
    & kubectl get hpa -n kubescope-prod
    & kubectl get pods -n monitoring

    Write-Host ''
    Write-Host 'Despliegue completado.' -ForegroundColor Green
    Write-Host 'Ejecuta en otra terminal:'
    Write-Host 'kubectl port-forward service/ingress-nginx-controller 8888:80 -n ingress-nginx'
    Write-Host 'kubectl port-forward service/prometheus-server 9090:80 -n monitoring'
    Write-Host 'Luego prueba usando los hosts dev.kubescope.local, stg.kubescope.local y kubescope.local.'
}
finally {
    Pop-Location
}
