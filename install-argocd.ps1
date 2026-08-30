[CmdletBinding()]
param(
    [ValidatePattern('^https://github\.com/.+/.+(\.git)?$')]
    [string]$RepoUrl = 'https://github.com/javiergm-usabana/trabajo-k8s-grupo-3.git',

    [string]$Revision = 'main',

    [string]$ChartVersion = '10.4.0',

    [string]$GitHubUsername = 'javiergm-usabana',

    [SecureString]$GitHubToken,

    [switch]$SkipToolInstallation
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$valuesPath = Join-Path $projectRoot 'argocd\argocd-values.yaml'
$applicationSetPath = Join-Path $projectRoot 'argocd\applicationset.yaml'
$renderedApplicationSet = Join-Path ([System.IO.Path]::GetTempPath()) 'kubescope-applicationset.yaml'

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
        throw "No se encontro '$Name' y se omitio la instalacion automatica."
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "No se encontro '$Name' ni WinGet. Instala App Installer desde Microsoft Store."
    }

    Write-Host "Instalando herramienta requerida: $Name ($WinGetId)..." -ForegroundColor Yellow
    & winget install --id $WinGetId --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "WinGet no pudo instalar '$Name' ($WinGetId)." }

    Update-ProcessPath
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' fue instalado, pero aun no esta disponible. Reinicia VS Code y ejecuta nuevamente este script."
    }
}

Initialize-ToolPath

$requiredTools = @(
    @{ Name = 'helm';    WinGetId = 'Helm.Helm' },
    @{ Name = 'kubectl'; WinGetId = 'Kubernetes.kubectl' },
    @{ Name = 'argocd';  WinGetId = 'argoproj.argocd' }
)

foreach ($tool in $requiredTools) {
    Ensure-Command -Name $tool.Name -WinGetId $tool.WinGetId
}

function ConvertTo-Base64 {
    param([Parameter(Mandatory)][string]$Value)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Apply-JsonManifest {
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $json = $Manifest | ConvertTo-Json -Depth 12 -Compress
    $json | & kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo aplicar un recurso de acceso privado.' }
}

try {
    Write-Host '1/6 Configurando repositorio Helm de ArgoCD...'
    & helm repo add argo https://argoproj.github.io/argo-helm --force-update
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo agregar el repositorio de ArgoCD.' }
    & helm repo update
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron actualizar los repositorios Helm.' }

    Write-Host '2/6 Instalando ArgoCD...'
    & helm upgrade --install argocd argo/argo-cd `
        --version $ChartVersion `
        --reset-values `
        --namespace argocd `
        --create-namespace `
        -f $valuesPath
    if ($LASTEXITCODE -ne 0) { throw 'ArgoCD no pudo instalarse.' }

    Write-Host '3/6 Esperando componentes de ArgoCD...'
    foreach ($deployment in @('argocd-server', 'argocd-repo-server', 'argocd-applicationset-controller')) {
        & kubectl rollout status "deployment/$deployment" -n argocd --timeout=600s
        if ($LASTEXITCODE -ne 0) { throw "$deployment no quedo disponible." }
    }

    Write-Host '4/7 Configurando acceso privado a GitHub y GHCR...'
    if (-not $GitHubToken) {
        $GitHubToken = Read-Host 'Token GitHub classic (repo + read:packages)' -AsSecureString
    }

    $credential = [PSCredential]::new($GitHubUsername, $GitHubToken)
    $plainToken = $credential.GetNetworkCredential().Password
    if ([string]::IsNullOrWhiteSpace($plainToken)) { throw 'El token GitHub esta vacio.' }

    $repoSecret = @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{
            name = 'kubescope-private-repo'
            namespace = 'argocd'
            labels = @{ 'argocd.argoproj.io/secret-type' = 'repository' }
        }
        type = 'Opaque'
        data = @{
            type = ConvertTo-Base64 'git'
            url = ConvertTo-Base64 $RepoUrl
            username = ConvertTo-Base64 $GitHubUsername
            password = ConvertTo-Base64 $plainToken
        }
    }
    Apply-JsonManifest $repoSecret

    $auth = ConvertTo-Base64 "$GitHubUsername`:$plainToken"
    $dockerConfig = @{
        auths = @{
            'ghcr.io' = @{
                username = $GitHubUsername
                password = $plainToken
                auth = $auth
            }
        }
    } | ConvertTo-Json -Depth 6 -Compress

    foreach ($namespace in @('kubescope-dev', 'kubescope-stg', 'kubescope-prod')) {
        Apply-JsonManifest @{
            apiVersion = 'v1'
            kind = 'Namespace'
            metadata = @{ name = $namespace }
        }
        Apply-JsonManifest @{
            apiVersion = 'v1'
            kind = 'Secret'
            metadata = @{
                name = 'ghcr-credentials'
                namespace = $namespace
            }
            type = 'kubernetes.io/dockerconfigjson'
            data = @{ '.dockerconfigjson' = ConvertTo-Base64 $dockerConfig }
        }
    }

    $plainToken = $null
    $credential = $null

    Write-Host '5/7 Generando ApplicationSet...'
    $template = Get-Content -Raw -LiteralPath $applicationSetPath
    $rendered = $template.Replace('__REPO_URL__', $RepoUrl).Replace('__REVISION__', $Revision)
    [System.IO.File]::WriteAllText($renderedApplicationSet, $rendered, [System.Text.UTF8Encoding]::new($false))

    Write-Host '6/7 Aplicando ApplicationSet...'
    & kubectl apply -f $renderedApplicationSet
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo aplicar el ApplicationSet.' }

    Write-Host '7/7 Estado de aplicaciones:'
    & kubectl get applications -n argocd

    Write-Host ''
    Write-Host 'ArgoCD instalado. Para abrir la interfaz:' -ForegroundColor Green
    Write-Host 'kubectl port-forward service/argocd-server 8082:80 -n argocd'
    Write-Host 'Usuario: admin'
    Write-Host 'Obtiene la contrasena inicial con:'
    Write-Host 'kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"'
}
finally {
    if (Test-Path -LiteralPath $renderedApplicationSet) {
        Remove-Item -LiteralPath $renderedApplicationSet -Force
    }
}
