[CmdletBinding()]
param(
    [switch]$SkipToolInstallation
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

function Initialize-ToolPath {
    $toolDirectories = @(
        'C:\Program Files\nodejs',
        'C:\Program Files\Git\cmd',
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

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
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
        $command = Get-Command $Name -ErrorAction SilentlyContinue
        if (-not $command) {
            throw "'$Name' fue instalado, pero aun no esta disponible. Reinicia VS Code y ejecuta nuevamente este script."
        }
    }

    Write-Host ("[OK] {0}: {1}" -f $Name, $command.Source) -ForegroundColor Green
}

Set-Location $projectRoot

Initialize-ToolPath

$requiredTools = @(
    @{ Name = 'node';     WinGetId = 'OpenJS.NodeJS.LTS' },
    @{ Name = 'npm';      WinGetId = 'OpenJS.NodeJS.LTS' },
    @{ Name = 'docker';   WinGetId = 'Docker.DockerDesktop' },
    @{ Name = 'minikube'; WinGetId = 'Kubernetes.minikube' },
    @{ Name = 'kubectl';  WinGetId = 'Kubernetes.kubectl' },
    @{ Name = 'helm';     WinGetId = 'Helm.Helm' },
    @{ Name = 'argocd';   WinGetId = 'argoproj.argocd' },
    @{ Name = 'git';      WinGetId = 'Git.Git' }
)

foreach ($tool in $requiredTools) {
    Ensure-Command -Name $tool.Name -WinGetId $tool.WinGetId
}

$nodeMajor = [int]((& node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 20) {
    throw "KubeScope requiere Node.js 20 o superior; se detectó $(& node --version)."
}

if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host 'pnpm no está disponible; instalando pnpm 10.17.1...'
    & npm install --global pnpm@10.17.1
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo instalar pnpm.' }
}

$pnpmCommand = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpmCommand) { throw 'pnpm no quedo disponible despues de la instalacion.' }
Write-Host ("[OK] pnpm: {0}" -f $pnpmCommand.Source) -ForegroundColor Green

Write-Host 'Instalando dependencias del proyecto...'
& pnpm install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw 'Falló la instalación de dependencias.' }

Write-Host 'Ejecutando pruebas...'
& pnpm exec jest --runInBand
if ($LASTEXITCODE -ne 0) { throw 'Las pruebas fallaron.' }

Write-Host 'Compilando NestJS...'
& pnpm run build
if ($LASTEXITCODE -ne 0) { throw 'La compilación falló.' }

Write-Host ''
Write-Host 'Terminal de VS Code preparada correctamente.' -ForegroundColor Green
Write-Host 'Puedes usar pnpm, Docker, Minikube, kubectl, Helm y los scripts del proyecto.'
