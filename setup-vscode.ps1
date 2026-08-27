[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

function Assert-Command {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$InstallHint
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "No se encontró '$Name'. $InstallHint"
    }

    Write-Host ("[OK] {0}: {1}" -f $Name, $command.Source) -ForegroundColor Green
}

Set-Location $projectRoot

Assert-Command node 'Instala Node.js 20 o superior.'
Assert-Command npm 'Node.js debe incluir npm.'
Assert-Command docker 'Instala o inicia Docker Desktop.'
Assert-Command minikube 'Instala Minikube y agrégalo a PATH.'
Assert-Command kubectl 'Instala kubectl y agrégalo a PATH.'
Assert-Command helm 'Instala Helm y agrégalo a PATH.'
Assert-Command git 'Instala Git para Windows.'

$nodeMajor = [int]((& node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 20) {
    throw "KubeScope requiere Node.js 20 o superior; se detectó $(& node --version)."
}

if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host 'pnpm no está disponible; instalando pnpm 10.17.1...'
    & npm install --global pnpm@10.17.1
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo instalar pnpm.' }
}

Assert-Command pnpm 'Ejecuta npm install --global pnpm@10.17.1.'

Write-Host 'Instalando dependencias del proyecto...'
& pnpm install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw 'Falló la instalación de dependencias.' }

Write-Host 'Ejecutando pruebas...'
& pnpm test -- --runInBand
if ($LASTEXITCODE -ne 0) { throw 'Las pruebas fallaron.' }

Write-Host 'Compilando NestJS...'
& pnpm run build
if ($LASTEXITCODE -ne 0) { throw 'La compilación falló.' }

Write-Host ''
Write-Host 'Terminal de VS Code preparada correctamente.' -ForegroundColor Green
Write-Host 'Puedes usar pnpm, Docker, Minikube, kubectl, Helm y los scripts del proyecto.'
