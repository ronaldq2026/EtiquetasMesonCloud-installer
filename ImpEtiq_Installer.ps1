Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# =========================================================
# ImpEtiq - COMPLETAR INSTALACION / RECUPERACION
# Server 284 - Windows Server 2012 / PowerShell 5.1
#
# Este script NO reinstala prerrequisitos.
# Completa la instalacion que quedo interrumpida despues de
# crear/iniciar el servicio MiBackendNode.
# =========================================================

$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = 'C:\impetiq_complete_284.log'
$StartTime = Get-Date

$NodeExe = 'C:\Program Files\nodejs\node.exe'
$Backend = 'C:\backend-dbf'
$LogDir = 'C:\backend-dbf\logs'
$NssmExe = 'C:\nssm\win64\nssm.exe'
$ServiceName = 'MiBackendNode'

$FrontendRoot = 'C:\frontend-etiquetas'
$FrontendOut = 'C:\frontend-etiquetas\out'
$FrontendSource = Join-Path $BaseDir 'out'

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try {
        Add-Content -LiteralPath $LogFile -Value ("{0} - {1}" -f $ts, $Message)
    }
    catch {
        Write-Host ("{0} - {1}" -f $ts, $Message)
    }
    Write-Host ("{0} - {1}" -f $ts, $Message)
}

function Fail-Install {
    param(
        [int]$Code,
        [string]$Message
    )
    Write-Log ("ERROR [{0}]: {1}" -f $Code, $Message)
    $elapsed = (Get-Date) - $StartTime
    Write-Log ("DURACION TOTAL: {0}" -f $elapsed.ToString('hh\:mm\:ss'))
    exit $Code
}

function Require-Path {
    param(
        [string]$Path,
        [string]$Description,
        [int]$Code
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail-Install $Code ("No se encontro {0}: {1}" -f $Description, $Path)
    }
}

# =========================================================
# INICIO
# =========================================================

Write-Log '=========================================='
Write-Log 'ImpEtiq - COMPLETAR INSTALACION SERVER 284'
Write-Log ("BaseDir: {0}" -f $BaseDir)
Write-Log '=========================================='

# =========================================================
# ADMINISTRADOR
# =========================================================

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail-Install 1 'El script debe ejecutarse como Administrador.'
}

Write-Log 'Permisos de administrador: OK'

# =========================================================
# VALIDACIONES DE LO YA INSTALADO
# =========================================================

Require-Path $NodeExe 'Node.js' 10
Require-Path (Join-Path $Backend 'index.js') 'backend index.js' 11
Require-Path $NssmExe 'NSSM' 12
Require-Path $FrontendSource 'frontend OUT de instalacion' 13

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Write-Log 'Node.js: OK'
Write-Log 'Backend: OK'
Write-Log 'NSSM: OK'
Write-Log 'Frontend OUT origen: OK'

# =========================================================
# SERVICIO NSSM
# =========================================================

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if (-not $svc) {
    Write-Log ("Servicio {0} no existe. Creando..." -f $ServiceName)

    & $NssmExe install $ServiceName $NodeExe (Join-Path $Backend 'index.js')
    if ($LASTEXITCODE -ne 0) {
        Fail-Install 20 'No fue posible crear el servicio NSSM.'
    }

    & $NssmExe set $ServiceName AppDirectory $Backend
    if ($LASTEXITCODE -ne 0) {
        Fail-Install 21 'No fue posible configurar AppDirectory de NSSM.'
    }

    & $NssmExe set $ServiceName AppStdout (Join-Path $LogDir 'out.log')
    if ($LASTEXITCODE -ne 0) {
        Fail-Install 22 'No fue posible configurar AppStdout de NSSM.'
    }

    & $NssmExe set $ServiceName AppStderr (Join-Path $LogDir 'err.log')
    if ($LASTEXITCODE -ne 0) {
        Fail-Install 23 'No fue posible configurar AppStderr de NSSM.'
    }

    & $NssmExe set $ServiceName AppRotateFiles 1
    & $NssmExe set $ServiceName AppRotateOnline 1
    & $NssmExe set $ServiceName AppRotateSeconds 86400

    $OracleIC = 'C:\oracle\instantclient_19_30'
    if (Test-Path -LiteralPath $OracleIC) {
        & $NssmExe set $ServiceName AppEnvironmentExtra ("PATH={0};C:\Program Files\nodejs;%PATH%" -f $OracleIC)
    }

    & $NssmExe set $ServiceName Start SERVICE_AUTO_START
    if ($LASTEXITCODE -ne 0) {
        Fail-Install 24 'No fue posible configurar inicio automatico de NSSM.'
    }

    Write-Log 'Servicio NSSM creado y configurado.'
}
else {
    Write-Log ("Servicio {0} ya existe. No se elimina ni recrea." -f $ServiceName)
}

# =========================================================
# INICIAR / ESPERAR SERVICIO
# =========================================================

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Fail-Install 25 'El servicio no existe despues de la validacion.'
}

Write-Log ("Estado inicial servicio: {0}" -f $svc.Status)

if ($svc.Status -ne 'Running') {
    Write-Log ("Solicitando inicio de {0}..." -f $ServiceName)
    & $NssmExe start $ServiceName
    $nssmStartExit = $LASTEXITCODE
    Write-Log ("NSSM start exit code: {0}" -f $nssmStartExit)
}
else {
    Write-Log 'Servicio ya esta Running.'
}

$running = $false
for ($i = 1; $i -le 24; $i++) {
    Start-Sleep -Seconds 5
    $svcCheck = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if (-not $svcCheck) {
        Fail-Install 26 'El servicio desaparecio durante el arranque.'
    }

    Write-Log ("Espera {0}s - Estado servicio: {1}" -f ($i * 5), $svcCheck.Status)

    if ($svcCheck.Status -eq 'Running') {
        $running = $true
        break
    }

    if ($svcCheck.Status -eq 'Stopped') {
        break
    }
}

if (-not $running) {
    Write-Log 'El servicio no llego a Running dentro de 120 segundos.'

    if (Test-Path -LiteralPath (Join-Path $LogDir 'out.log')) {
        Write-Log '--- out.log ultimas 50 lineas ---'
        Get-Content -LiteralPath (Join-Path $LogDir 'out.log') -Tail 50 | ForEach-Object {
            Write-Log $_.ToString()
        }
    }

    if (Test-Path -LiteralPath (Join-Path $LogDir 'err.log')) {
        Write-Log '--- err.log ultimas 50 lineas ---'
        Get-Content -LiteralPath (Join-Path $LogDir 'err.log') -Tail 50 | ForEach-Object {
            Write-Log $_.ToString()
        }
    }

    Fail-Install 27 'MiBackendNode no quedo Running.'
}

Write-Log 'MiBackendNode: RUNNING'

# =========================================================
# FRONTEND OUT
# =========================================================

Write-Log '=========================================='
Write-Log 'INSTALANDO FRONTEND OUT'
Write-Log '=========================================='

if (-not (Test-Path -LiteralPath $FrontendOut)) {
    New-Item -ItemType Directory -Path $FrontendOut -Force | Out-Null
}

Write-Log ("Copiando desde: {0}" -f $FrontendSource)
Write-Log ("Copiando hacia: {0}" -f $FrontendOut)

Copy-Item -Path (Join-Path $FrontendSource '*') -Destination $FrontendOut -Recurse -Force

if (-not (Test-Path -LiteralPath $FrontendOut)) {
    Fail-Install 30 'El frontend OUT no quedo instalado.'
}

Write-Log 'Frontend OUT: OK'

# =========================================================
# IIS FEATURES
# =========================================================

Write-Log '=========================================='
Write-Log 'VALIDANDO IIS'
Write-Log '=========================================='

try {
    Import-Module ServerManager -ErrorAction Stop
}
catch {
    Fail-Install 31 'No fue posible cargar el modulo ServerManager.'
}

$IisFeatures = @('Web-Static-Content', 'Web-Default-Doc')

foreach ($FeatureName in $IisFeatures) {
    try {
        $Feature = Get-WindowsFeature -Name $FeatureName -ErrorAction Stop
    }
    catch {
        Fail-Install 32 ("No fue posible consultar la caracteristica IIS {0}." -f $FeatureName)
    }

    if ($Feature.InstallState -eq 'Installed') {
        Write-Log ("IIS {0}: ya instalado." -f $FeatureName)
    }
    else {
        Write-Log ("IIS {0}: instalando..." -f $FeatureName)

        try {
            $Result = Install-WindowsFeature -Name $FeatureName -ErrorAction Stop
        }
        catch {
            Fail-Install 33 ("No fue posible instalar la caracteristica IIS {0}." -f $FeatureName)
        }

        if (-not $Result.Success) {
            Fail-Install 34 ("Fallo la instalacion IIS {0}." -f $FeatureName)
        }

        $FeatureAfter = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
        if (-not $FeatureAfter -or $FeatureAfter.InstallState -ne 'Installed') {
            Fail-Install 35 ("La caracteristica IIS {0} no quedo instalada." -f $FeatureName)
        }

        Write-Log ("IIS {0}: instalado." -f $FeatureName)
    }
}

# =========================================================
# IIS SITE
# =========================================================

$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
Require-Path $appcmd 'appcmd.exe / IIS' 40

$site = & $appcmd list site 'impresionEtiquetas' 2>$null

if (-not $site) {
    Write-Log 'Sitio impresionEtiquetas no existe. Creando...'

    & $appcmd add site /name:'impresionEtiquetas' /bindings:'http/*:81:' /physicalPath:$FrontendOut

    if ($LASTEXITCODE -ne 0) {
        Fail-Install 41 'No fue posible crear el sitio IIS impresionEtiquetas.'
    }

    Write-Log 'Sitio IIS creado.'
}
else {
    Write-Log 'Sitio impresionEtiquetas ya existe.'

    & $appcmd set vdir 'impresionEtiquetas/' ("/physicalPath:{0}" -f $FrontendOut)

    if ($LASTEXITCODE -ne 0) {
        Fail-Install 42 'No fue posible actualizar la ruta fisica del sitio IIS.'
    }

    Write-Log 'Ruta fisica IIS verificada.'
}

# Asegurar que el sitio este iniciado.
& $appcmd start site 'impresionEtiquetas' 2>$null

$finalSite = & $appcmd list site 'impresionEtiquetas' 2>$null
if (-not $finalSite) {
    Fail-Install 43 'El sitio IIS no existe despues de la configuracion.'
}

Write-Log 'Sitio IIS: OK'
Write-Log ($finalSite -join ' ')

# =========================================================
# VALIDACION FINAL
# =========================================================

$finalSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $finalSvc) {
    Fail-Install 50 'Validacion final: servicio no existe.'
}

if ($finalSvc.Status -ne 'Running') {
    Fail-Install 51 ("Validacion final: servicio esta {0}, no Running." -f $finalSvc.Status)
}

Write-Log 'Validacion final: MiBackendNode RUNNING'

# Puerto backend: solo informa; no bloquea una instalacion ya funcional por NSSM.
try {
    $tcp = Test-NetConnection -ComputerName '127.0.0.1' -Port 3001 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Write-Log 'Backend TCP 3001: OK'
    }
    else {
        Write-Log 'ADVERTENCIA: TCP 3001 no responde todavia.'
    }
}
catch {
    Write-Log 'ADVERTENCIA: no fue posible comprobar TCP 3001.'
}

# HTTP frontend: solo informa; no bloquea si IIS ya existe y esta configurado.
try {
    $response = Invoke-WebRequest -Uri 'http://localhost:81' -UseBasicParsing -TimeoutSec 20
    Write-Log ("Frontend HTTP localhost:81: OK - HTTP {0}" -f $response.StatusCode)
}
catch {
    Write-Log 'ADVERTENCIA: localhost:81 no respondio correctamente.'
    Write-Log $_.Exception.Message
}

# =========================================================
# FINAL
# =========================================================

Write-Log '=========================================='
Write-Log 'COMPLETACION FINALIZADA'
Write-Log '=========================================='
Write-Log 'Node.js: OK'
Write-Log 'Backend: OK'
Write-Log 'NSSM: OK'
Write-Log 'MiBackendNode: Running'
Write-Log 'Frontend OUT: OK'
Write-Log 'IIS impresionEtiquetas: OK'

$elapsed = (Get-Date) - $StartTime
Write-Log ("DURACION TOTAL: {0}" -f $elapsed.ToString('hh\:mm\:ss'))
Write-Log '=========================================='

exit 0
