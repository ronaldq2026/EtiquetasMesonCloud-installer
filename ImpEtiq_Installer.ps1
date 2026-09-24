# =========================

# ImpEtiq Installer

# Soporte:

# - Windows Server 2012 / 2012 R2

# - Windows Server 2022

# =========================

$ErrorActionPreference = "Stop"

# -------------------------

# BaseDir compatible PS1 / EXE (ps2exe)

# -------------------------

if ($MyInvocation.MyCommand.Path) {
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
$BaseDir = [System.IO.Path]::GetDirectoryName(
[System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
)
}

# -------------------------

# Variables base

# -------------------------

$LogFile  = "C:\impetiq_install.log"
$InstallerStart = Get-Date
$NodeDir  = "C:\Program Files\nodejs"
$NodeExe  = "$NodeDir\node.exe"
$NpmCmd   = "$NodeDir\npm.cmd"
$Backend  = "C:\backend-dbf"
$OracleIC = "C:\oracle\instantclient_19_30"
$NssmExe  = "C:\nssm\win64\nssm.exe"

$ServiceName = "MiBackendNode"
$FrontendRoot = "C:\frontend-etiquetas"
$LogDir = "$Backend\logs"
$FrontendOut = "$FrontendRoot\out"

$TargetNodeVersion = "14.21.3"
$TargetNpmVersion  = "6.14.18"
$BackendPort = 3000
$BackendHealthUrl = "http://127.0.0.1:$BackendPort/health"
$ServiceWaitTimeoutSeconds = 60

# -------------------------

# Logging

# -------------------------

function Write-Log {
param([string]$Message)

$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

try {
    Add-Content -Path $LogFile -Value "$ts - $Message"
}
catch {
    Write-Host "$ts - $Message"
}

}

function Stop-Installer {
param(
[int]$ExitCode,
[string]$Message
)

Write-Log "ERROR: $Message"
if ($InstallerStart) {
    $elapsed = (Get-Date) - $InstallerStart
    Write-Log "DURACION TOTAL: $($elapsed.ToString('hh\:mm\:ss'))"
}

if ($TranscriptEnabled) {
    try { Stop-Transcript | Out-Null } catch {}
}

exit $ExitCode

}

function Invoke-Npm {
param([string]$Arguments)

$previousErrorActionPreference = $ErrorActionPreference
try {
    # En PS 5.1, stderr de un ejecutable nativo puede convertirse en error
    # aunque el proceso termine correctamente. Se captura como salida normal.
    $ErrorActionPreference = "Continue"
    $command = "call `"$NpmCmd`" $Arguments 2>&1"
    $output = @(& cmd.exe /c $command)
    $exitCode = $LASTEXITCODE
    return New-Object PSObject -Property @{
        Output = $output
        ExitCode = $exitCode
    }
}

finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
}

function Get-ApplicationFiles {
param([string]$Path)

Get-ChildItem -LiteralPath $Path -Force | Where-Object {
    $_.Name -ne ".env" -and $_.Name -ne "data" -and $_.Name -ne "logs" -and $_.Name -ne "node_modules"
} | ForEach-Object {
    if ($_.PSIsContainer) {
        Get-ApplicationFiles -Path $_.FullName
    }
    else {
        $_
    }
}
}

function Get-ApplicationDirectories {
param([string]$Path)

    Get-ChildItem -LiteralPath $Path -Force -Directory | Where-Object {
        $_.Name -ne "data" -and $_.Name -ne "logs" -and $_.Name -ne "node_modules"
    } | ForEach-Object {
        $_
        Get-ApplicationDirectories -Path $_.FullName
    }
}

function Get-FileSha256 {
param([string]$Path)

$sha256 = [System.Security.Cryptography.SHA256]::Create()
$stream = [System.IO.File]::OpenRead($Path)
try {
    $hashBytes = $sha256.ComputeHash($stream)
    return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
}
finally {
    $stream.Dispose()
    $sha256.Dispose()
}
}

function Get-BackendSnapshot {
param([string]$Path)

$snapshot = @{}
foreach ($file in (Get-ApplicationFiles -Path $Path)) {
    $relativePath = $file.FullName.Substring($Path.Length).TrimStart('\')
    $snapshot[$relativePath] = Get-FileSha256 -Path $file.FullName
}
return $snapshot
}

function Wait-ServiceState {
param(
    [string]$Name,
    [string]$DesiredState,
    [int]$TimeoutSeconds = 60
)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $service) { return $null }
        $service.Refresh()
        Write-Log "Servicio ${Name}: estado actual $($service.Status); esperando $DesiredState"
        if ($service.Status.ToString() -eq $DesiredState) { return $service }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($service) { $service.Refresh() }
    return $service
}

function Stop-ServiceAndWait {
param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return $null }
    $service.Refresh()
    if ($service.Status -ne 'Stopped') {
        Write-Log "Deteniendo servicio $Name (estado actual: $($service.Status))"
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $service = Wait-ServiceState -Name $Name -DesiredState 'Stopped' -TimeoutSeconds $ServiceWaitTimeoutSeconds
        if (-not $service -or $service.Status -ne 'Stopped') {
            Stop-Installer 52 "El servicio $Name no quedo detenido dentro del timeout."
        }
    }
    return $service
}

function Get-NssmSetting {
param(
    [string]$Name,
    [string]$Setting
)

    $value = & $NssmExe get $Name $Setting 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { return $null }
    return ((@($value) | ForEach-Object { $_.ToString().Trim() }) -join "`n").Trim()
}

function Set-NssmSettingChecked {
param(
    [string]$Name,
    [string]$Setting,
    [string]$Value
)

    $nssmOutput = @(& $NssmExe set $Name $Setting $Value 2>&1)
    foreach ($line in $nssmOutput) { Write-Log "NSSM: $($line.ToString())" }
    $nssmExitCode = $LASTEXITCODE
    if ($nssmExitCode -ne 0) {
        Stop-Installer 83 "No fue posible configurar NSSM $Setting para $Name."
    }
}

function Test-BackendHealth {
    try {
        $response = Invoke-WebRequest -Uri $BackendHealthUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Log "Backend health: HTTP $($response.StatusCode) en $BackendHealthUrl"
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch {
        Write-Log "Backend health no respondio en ${BackendHealthUrl}: $($_.Exception.Message)"
        return $false
    }
}

function Test-FrontendHealth {
param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Log "Frontend HTTP: HTTP $($response.StatusCode) en $Url"
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
    }
    catch {
        Write-Log "Frontend no respondio en ${Url}: $($_.Exception.Message)"
        return $false
    }
}

$CurrentStage = "Inicio"
trap {
    $unexpectedMessage = $_.Exception.Message
    Write-Log "ERROR: Excepci�n inesperada en etapa [$CurrentStage]: $unexpectedMessage"
    if ($InstallerStart) {
        $unexpectedElapsed = (Get-Date) - $InstallerStart
        Write-Log "DURACION TOTAL: $($unexpectedElapsed.ToString('hh\:mm\:ss'))"
    }
    if ($TranscriptEnabled) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    exit 1
}

Write-Log "INICIO INSTALADOR"
Write-Log "=========================================="
Write-Log "ImpEtiq Installer iniciado"
Write-Log "BaseDir: $BaseDir"
Write-Log "=========================================="

# -------------------------

# Transcript

# -------------------------

$TranscriptEnabled = $false
Write-Log "Logging manual activo; transcript deshabilitado"

# -------------------------

# Administrador

# -------------------------

$principal = New-Object Security.Principal.WindowsPrincipal(
[Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $principal.IsInRole(
[Security.Principal.WindowsBuiltInRole]::Administrator
)) {
Stop-Installer 1 "El instalador debe ejecutarse como Administrador."
}

Write-Log "Permisos de administrador: OK"

# -------------------------

# Detectar SO

# -------------------------

try {
$os = Get-CimInstance Win32_OperatingSystem
}
catch {
Stop-Installer 10 "No fue posible detectar el sistema operativo."
}

$version = $os.Version
$caption = $os.Caption

Write-Log "SO detectado: $caption ($version)"

# -------------------------

# Validar SO soportado

# -------------------------

$isServer2012 = ($version -like "6.2*" -or $version -like "6.3*")
$isServer2022 = ($version -like "10.0*" -and $caption -like "*Windows Server 2022*")

if ($caption -like "*Windows 10*") {
Stop-Installer 1002 "Windows 10 no es soportado por ImpEtiq."
}

if (-not $isServer2012 -and -not $isServer2022) {
Stop-Installer 1003 "Sistema operativo no soportado: $caption ($version)"
}

if ($isServer2012) {
Write-Log "Plataforma seleccionada: Windows Server 2012 / 2012 R2"
$OracleDbVersion = "5.5.0"
}
else {
Write-Log "Plataforma seleccionada: Windows Server 2022"
$OracleDbVersion = "6.10.0"
}

Write-Log "oracledb requerido: $OracleDbVersion"

# =========================================================

# SERVER 2012 - PREREQUISITOS

# =========================================================

if ($isServer2012) {

Write-Log "Validando prerrequisitos de Windows Server 2012"

# -------------------------
# KB2999226
# -------------------------
$kb = Get-HotFix -Id KB2999226 -ErrorAction SilentlyContinue

if (-not $kb) {

    if ($version -like "6.2*") {
        $KbFile = "$BaseDir\Windows8-RT-KB2999226-x64.msu"
    }
    elseif ($version -like "6.3*") {
        $KbFile = "$BaseDir\Windows8.1-KB2999226-x64.msu"
    }
    else {
        Stop-Installer 20 "No existe un paquete KB2999226 definido para la versi�n de Windows: $version"
    }

    if (-not (Test-Path $KbFile)) {
        Stop-Installer 20 "No se encontr� $KbFile"
    }

    Write-Log "KB2999226 no encontrado. Instalando..."

    $kbProcess = Start-Process `
        -FilePath "wusa.exe" `
        -ArgumentList "`"$KbFile`" /quiet /norestart" `
        -Wait `
        -PassThru

    Write-Log "Resultado instalaci�n KB2999226: $($kbProcess.ExitCode)"

    if ($kbProcess.ExitCode -ne 0 -and $kbProcess.ExitCode -ne 3010) {
        Stop-Installer 21 "Fall� la instalaci�n de KB2999226. C�digo: $($kbProcess.ExitCode)"
    }

    $kbAfterInstall = Get-HotFix -Id KB2999226 -ErrorAction SilentlyContinue
    if ($kbProcess.ExitCode -eq 3010) {
        Write-Log "KB2999226 requiere reinicio; no se reiniciar� autom�ticamente."
        if ($kbAfterInstall) {
            Write-Log "KB2999226 confirmado despu�s de la instalaci�n."
        }
        else {
            Write-Log "KB2999226 pendiente de confirmaci�n hasta reiniciar el servidor."
        }
    }
    elseif (-not $kbAfterInstall) {
        Stop-Installer 22 "KB2999226 no qued� confirmado despu�s de la instalaci�n."
    }
    else {
        Write-Log "KB2999226 confirmado despu�s de la instalaci�n."
    }
}
else {
    Write-Log "KB2999226 ya est� instalado"
}

# -------------------------
# Visual C++ Redistributable
# -------------------------
$vcPresent = $false

$vcPaths = @(
    "HKLM:\SOFTWARE\Classes\Installer\Dependencies",
    "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
)

foreach ($vcPath in $vcPaths) {

    if (Test-Path $vcPath) {

        $items = Get-ChildItem $vcPath -ErrorAction SilentlyContinue

        foreach ($item in $items) {

            try {
                $props = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue

                if (
                    $props.DisplayName -like "*Visual C++*2015*" -or
                    $props.DisplayName -like "*Visual C++*2015-2022*" -or
                    $item.PSChildName -eq "x64"
                ) {
                    $vcPresent = $true
                }
            }
            catch {}
        }
    }
}

if (-not $vcPresent) {

    $VcFile = "$BaseDir\VC_redist.x64.exe"

    if (-not (Test-Path $VcFile)) {
        Stop-Installer 22 "No se encontr� $VcFile"
    }

    Write-Log "Visual C++ Redistributable no encontrado. Instalando..."

    $vcProcess = Start-Process `
        -FilePath $VcFile `
        -ArgumentList "/quiet /norestart" `
        -Wait `
        -PassThru

    Write-Log "Resultado instalaci�n Visual C++: $($vcProcess.ExitCode)"

    if ($vcProcess.ExitCode -ne 0 -and $vcProcess.ExitCode -ne 3010) {
        Stop-Installer 23 "Fall� la instalaci�n de Visual C++. C�digo: $($vcProcess.ExitCode)"
    }
}
else {
    Write-Log "Visual C++ Redistributable ya presente"
}

}

# =========================================================

# NODE.JS 14.21.3

# =========================================================

$NodeNeedsInstall = $false

if (-not (Test-Path $NodeExe)) {
Write-Log "Node.js no est� instalado"
$NodeNeedsInstall = $true
}
else {

try {
    $nodeVersion = (& $NodeExe --version 2>&1).ToString().Trim()
    Write-Log "Node.js detectado: $nodeVersion"

    if ($nodeVersion -ne "v$TargetNodeVersion") {
        Write-Log "Versi�n Node diferente de la requerida"
        $NodeNeedsInstall = $true
    }
}
catch {
    Write-Log "No fue posible ejecutar Node.js"
    $NodeNeedsInstall = $true
}

}

# -------------------------

# Instalar/reparar Node

# -------------------------

if ($NodeNeedsInstall) {

$NodeMsi = "$BaseDir\node-v14.21.3-x64.msi"

if (-not (Test-Path $NodeMsi)) {
    Stop-Installer 30 "No se encontr� $NodeMsi"
}

Write-Log "Instalando/actualizando Node.js $TargetNodeVersion"

$nodeProcess = Start-Process `
    -FilePath "msiexec.exe" `
    -ArgumentList "/i `"$NodeMsi`" /qn /norestart" `
    -Wait `
    -PassThru

Write-Log "Resultado instalaci�n Node.js: $($nodeProcess.ExitCode)"

if ($nodeProcess.ExitCode -ne 0 -and $nodeProcess.ExitCode -ne 3010) {
    Stop-Installer 31 "Fall� la instalaci�n de Node.js. C�digo: $($nodeProcess.ExitCode)"
}

}

# -------------------------

# Validar Node

# -------------------------

if (-not (Test-Path $NodeExe)) {
Stop-Installer 32 "Node.js no qued� instalado correctamente."
}

$nodeVersion = (& $NodeExe --version 2>&1).ToString().Trim()

if ($nodeVersion -ne "v$TargetNodeVersion") {
Stop-Installer 33 "Versi�n Node incorrecta. Esperada v$TargetNodeVersion, encontrada $nodeVersion"
}

Write-Log "Node.js ${nodeVersion}: OK"

# -------------------------

# Validar npm

# -------------------------

if (-not (Test-Path $NpmCmd)) {
Stop-Installer 34 "npm.cmd no existe."
}

$npmResult = Invoke-Npm "--version"
$npmOutput = @($npmResult.Output)
$npmExitCode = [int]$npmResult.ExitCode
$npmVersion = ($npmOutput | ForEach-Object { $_.ToString().Trim() } | Where-Object {
    $_ -match '^\d+\.\d+\.\d+$'
} | Select-Object -Last 1)

Write-Log "npm detectado: $npmVersion"
Write-Log "npm exit code: $npmExitCode"
if ($npmExitCode -ne 0 -or [string]::IsNullOrEmpty($npmVersion)) {
    foreach ($line in $npmOutput) { Write-Log "npm: $($line.ToString())" }
    Stop-Installer 35 "No fue posible ejecutar npm correctamente."
}
if ($npmVersion -ne $TargetNpmVersion) {
    Stop-Installer 36 "Versi�n npm incorrecta. Esperada $TargetNpmVersion, encontrada $npmVersion"
}

# =========================================================

# ORACLE INSTANT CLIENT

# =========================================================

if (Test-Path $OracleIC) {

Write-Log "Oracle Instant Client 19.30 ya existe: NO SE MODIFICA"

}
else {

$OracleSource = "$BaseDir\instantclient_19_30"

if (-not (Test-Path $OracleSource)) {
    Stop-Installer 40 "No se encontr� el Instant Client en $OracleSource"
}

Write-Log "Oracle Instant Client no encontrado. Copiando..."

New-Item -ItemType Directory -Path "C:\oracle" -Force | Out-Null

Copy-Item `
    $OracleSource `
    "C:\oracle" `
    -Recurse `
    -Force

if (-not (Test-Path $OracleIC)) {
    Stop-Installer 41 "El Oracle Instant Client no qued� instalado correctamente."
}

Write-Log "Oracle Instant Client 19.30 instalado"

}

# Validaci�n b�sica

if (-not (Test-Path "$OracleIC\oci.dll")) {
Stop-Installer 42 "No se encontr� oci.dll en el Instant Client."
}

if (-not (Test-Path "$OracleIC\oraociei19.dll")) {
Stop-Installer 43 "No se encontr� oraociei19.dll en el Instant Client."
}

Write-Log "Oracle Instant Client: OK"

# =========================================================

# BACKEND

# =========================================================

$BackendSource = "$BaseDir\backend-dbf"

if (-not (Test-Path $BackendSource)) {
Stop-Installer 50 "No se encontr� el backend en $BackendSource"
}

$BackendExists = Test-Path $Backend
$CurrentStage = "Detecci�n de cambios del backend"
$BackendChanged = $false
$InitialService = Get-Service $ServiceName -ErrorAction SilentlyContinue
$ServiceInitialStatus = $null
$ServiceShouldRun = $false
$ServiceNeedsStart = $false
if ($InitialService) {
    $InitialService.Refresh()
    $ServiceInitialStatus = $InitialService.Status.ToString()
    Write-Log "Servicio existente: estado inicial $ServiceInitialStatus"
    if ($ServiceInitialStatus -eq 'StartPending') {
        $InitialService = Wait-ServiceState -Name $ServiceName -DesiredState 'Running' -TimeoutSeconds $ServiceWaitTimeoutSeconds
        if (-not $InitialService -or $InitialService.Status -ne 'Running') {
            Stop-Installer 52 "El servicio $ServiceName no alcanzo Running durante el arranque."
        }
        $ServiceShouldRun = $true
    }
    elseif ($ServiceInitialStatus -eq 'StopPending') {
        $InitialService = Wait-ServiceState -Name $ServiceName -DesiredState 'Stopped' -TimeoutSeconds $ServiceWaitTimeoutSeconds
        if (-not $InitialService -or $InitialService.Status -ne 'Stopped') {
            Stop-Installer 52 "El servicio $ServiceName no alcanzo Stopped durante la detencion."
        }
    }
    elseif ($ServiceInitialStatus -eq 'Running') {
        $ServiceShouldRun = $true
    }
}

if (-not $BackendExists) {
    $BackendChanged = $true
    Write-Log "Backend: CAMBIOS DETECTADOS"
    Write-Log "Instalaci�n nueva: copiando backend de aplicaci�n"
    New-Item -ItemType Directory -Path $Backend -Force | Out-Null
    Get-ChildItem $BackendSource -Force | Where-Object {
        $_.Name -ne ".env" -and $_.Name -ne "data" -and $_.Name -ne "logs" -and $_.Name -ne "node_modules"
    } | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $Backend $_.Name) -Recurse -Force
    }
}
else {
    $sourceSnapshot = Get-BackendSnapshot -Path $BackendSource
    $installedSnapshot = Get-BackendSnapshot -Path $Backend
    if ($sourceSnapshot.Count -ne $installedSnapshot.Count) {
        $BackendChanged = $true
    }
    else {
        foreach ($relativePath in $sourceSnapshot.Keys) {
            if (-not $installedSnapshot.ContainsKey($relativePath) -or
                $installedSnapshot[$relativePath] -ne $sourceSnapshot[$relativePath]) {
                $BackendChanged = $true
                break
            }
        }
    }

    if ($BackendChanged) {
        Write-Log "Backend: CAMBIOS DETECTADOS"
        if ($InitialService -and $ServiceShouldRun) {
            Write-Log "Servicio detenido por actualizacion de backend"
            Stop-ServiceAndWait -Name $ServiceName | Out-Null
            $ServiceNeedsStart = $true
        }

        Write-Log "Actualizando archivos de aplicaci�n del backend"
        foreach ($relativePath in @($installedSnapshot.Keys)) {
            if (-not $sourceSnapshot.ContainsKey($relativePath)) {
                $deletedFile = Join-Path $Backend $relativePath
                Write-Log "Eliminando archivo de aplicaci�n obsoleto: $relativePath"
                Remove-Item -LiteralPath $deletedFile -Force -ErrorAction Stop
            }
        }

        foreach ($directory in @(Get-ApplicationDirectories -Path $Backend | Sort-Object { $_.FullName.Length } -Descending)) {
            $relativeDirectory = $directory.FullName.Substring($Backend.Length).TrimStart('\')
            $sourceDirectory = Join-Path $BackendSource $relativeDirectory
            if (-not (Test-Path -LiteralPath $sourceDirectory)) {
                Write-Log "Eliminando directorio de aplicacion obsoleto: $relativeDirectory"
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
            }
        }

        Get-ChildItem $BackendSource -Force | Where-Object {
            $_.Name -ne ".env" -and $_.Name -ne "data" -and $_.Name -ne "logs" -and $_.Name -ne "node_modules"
        } | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $Backend $_.Name) -Recurse -Force
        }
    }
    else {
        Write-Log "Backend: SIN CAMBIOS"
        Write-Log "Backend sin cambios: no se detiene el servicio"
    }
}

if (-not (Test-Path "$Backend\index.js")) {
Stop-Installer 51 "El backend no contiene index.js despu�s de la actualizaci�n."
}

Write-Log "Backend: OK"

# =========================================================

# LOGS

# =========================================================

if (-not (Test-Path $LogDir)) {
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# =========================================================

# NPM / DEPENDENCIAS

# =========================================================

if ($BackendChanged) {
Set-Location $Backend

$env:COMSPEC = "C:\Windows\System32\cmd.exe"
$env:PATH = "$OracleIC;$NodeDir;$NodeDir\node_modules\npm\bin;$env:PATH"

# Configuraci�n npm silenciosa

Write-Log "Configurando npm"

$npmResult = Invoke-Npm "config set audit false"
if ($npmResult.ExitCode -ne 0) {
foreach ($line in @($npmResult.Output)) { Write-Log "npm: $($line.ToString())" }
Stop-Installer 60 "No fue posible configurar npm audit."
}

$npmResult = Invoke-Npm "config set fund false"
if ($npmResult.ExitCode -ne 0) {
foreach ($line in @($npmResult.Output)) { Write-Log "npm: $($line.ToString())" }
Stop-Installer 61 "No fue posible configurar npm fund."
}

$npmResult = Invoke-Npm "config set update-notifier false"
if ($npmResult.ExitCode -ne 0) {
foreach ($line in @($npmResult.Output)) { Write-Log "npm: $($line.ToString())" }
Stop-Installer 62 "No fue posible configurar npm update-notifier."
}

# -------------------------

# Dependencias generales

# -------------------------

Write-Log "Instalando dependencias npm"

$npmResult = Invoke-Npm "install --silent"
$npmInstallExit = [int]$npmResult.ExitCode

Write-Log "npm install exit code: $npmInstallExit"

if ($npmInstallExit -ne 0) {
foreach ($line in @($npmResult.Output)) { Write-Log "npm: $($line.ToString())" }
Stop-Installer 63 "Fall� npm install."
}

# -------------------------

# oracledb seg�n SO

# -------------------------

Write-Log "Configurando oracledb $OracleDbVersion"

$npmResult = Invoke-Npm "install oracledb@$OracleDbVersion --silent"
$oracleInstallExit = [int]$npmResult.ExitCode

Write-Log "Instalaci�n oracledb exit code: $oracleInstallExit"

if ($oracleInstallExit -ne 0) {
foreach ($line in @($npmResult.Output)) { Write-Log "npm: $($line.ToString())" }
Stop-Installer 64 "Fall� la instalaci�n de oracledb@$OracleDbVersion."
}

# -------------------------

# Verificar oracledb

# -------------------------

$npmResult = Invoke-Npm "list oracledb --depth=0"
$oracleList = @($npmResult.Output)

Write-Log "Resultado npm list oracledb:"
foreach ($line in $oracleList) {
Write-Log $line.ToString()
}

if ($npmResult.ExitCode -ne 0 -or ($oracleList -join "`n") -notmatch "oracledb@$OracleDbVersion") {
foreach ($line in $oracleList) { Write-Log "npm: $($line.ToString())" }
Stop-Installer 65 "La versi�n de oracledb instalada no corresponde a la requerida: $OracleDbVersion"
}

Write-Log "oracledb ${OracleDbVersion}: OK"
Write-Log "npm ejecutado por cambio de backend"
Write-Log "oracledb configurado por cambio de backend"
}
else {
Write-Log "Backend sin cambios: no se ejecuta npm"
Write-Log "Backend sin cambios: no se modifica oracledb"
}

# =========================================================

# NSSM

# =========================================================

if (-not (Test-Path $NssmExe)) {

$NssmSource = "$BaseDir\nssm\win64\nssm.exe"

if (-not (Test-Path $NssmSource)) {
    Stop-Installer 70 "No se encontr� NSSM en $NssmSource"
}

Write-Log "NSSM no encontrado. Instalando..."

New-Item -ItemType Directory -Path "C:\nssm\win64" -Force | Out-Null

Copy-Item `
    $NssmSource `
    $NssmExe `
    -Force

Write-Log "NSSM instalado"

}
else {
Write-Log "NSSM ya existe: NO SE MODIFICA"
}

# =========================================================

# SERVICIO

# =========================================================

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
$ServiceWasCreated = $false

if (-not $svc) {

Write-Log "Servicio $ServiceName no existe. Creando..."

& $NssmExe install $ServiceName $NodeExe "$Backend\index.js"

if ($LASTEXITCODE -ne 0) {
    Stop-Installer 80 "No fue posible crear el servicio NSSM."
}

Set-NssmSettingChecked $ServiceName 'AppPath' $NodeExe
Set-NssmSettingChecked $ServiceName 'AppDirectory' $Backend
Set-NssmSettingChecked $ServiceName 'AppParameters' "$Backend\index.js"
Set-NssmSettingChecked $ServiceName 'AppStdout' "$LogDir\out.log"
Set-NssmSettingChecked $ServiceName 'AppStderr' "$LogDir\err.log"
Set-NssmSettingChecked $ServiceName 'AppRotateFiles' '1'
Set-NssmSettingChecked $ServiceName 'AppRotateOnline' '1'
Set-NssmSettingChecked $ServiceName 'AppRotateSeconds' '86400'
Set-NssmSettingChecked $ServiceName 'AppEnvironmentExtra' "PATH=$OracleIC;$NodeDir;%PATH%"
Set-NssmSettingChecked $ServiceName 'Start' 'SERVICE_AUTO_START'

Write-Log "Servicio NSSM creado"
$ServiceWasCreated = $true
$ServiceShouldRun = $true
$ServiceNeedsStart = $true

}
else {

Write-Log "Servicio $ServiceName ya existe"
Write-Log "Servicio existente conservado; no se elimina ni recrea"

    $expectedNssm = @{
        AppPath = $NodeExe
        AppDirectory = $Backend
        AppParameters = "$Backend\index.js"
        AppStdout = "$LogDir\out.log"
        AppStderr = "$LogDir\err.log"
    }
    $nssmChanged = $false
    foreach ($setting in $expectedNssm.Keys) {
        $actual = Get-NssmSetting -Name $ServiceName -Setting $setting
        $actualComparable = if ($null -eq $actual) { '' } else { $actual.Trim().Trim('"') }
        if ($actualComparable -ne $expectedNssm[$setting]) {
            Write-Log "NSSM $setting incorrecto o ausente. Esperado: $($expectedNssm[$setting]); actual: $actualComparable"
            $nssmChanged = $true
        }
    }
    if ($nssmChanged) {
        if ($ServiceShouldRun) { Stop-ServiceAndWait -Name $ServiceName | Out-Null }
        foreach ($setting in $expectedNssm.Keys) {
            Set-NssmSettingChecked $ServiceName $setting $expectedNssm[$setting]
        }
        if ($ServiceShouldRun) { $ServiceNeedsStart = $true }
        Write-Log "Configuracion NSSM corregida sin recrear el servicio"
    }
    else {
        Write-Log "Configuracion NSSM existente validada"
    }

}

# =========================================================

# INICIAR SERVICIO

# =========================================================

if ($ServiceShouldRun -and $ServiceNeedsStart) {
    Write-Log "Iniciando servicio $ServiceName"
    & $NssmExe start $ServiceName
    if ($LASTEXITCODE -ne 0) {
        Stop-Installer 80 "NSSM no pudo iniciar el servicio $ServiceName."
    }
    $svcCheck = Wait-ServiceState -Name $ServiceName -DesiredState 'Running' -TimeoutSeconds $ServiceWaitTimeoutSeconds
    if (-not $svcCheck -or $svcCheck.Status -ne 'Running') {
        if (Test-Path "$LogDir\out.log") { Get-Content -LiteralPath "$LogDir\out.log" -Tail 30 | ForEach-Object { Write-Log "out.log: $_" } }
        if (Test-Path "$LogDir\err.log") { Get-Content -LiteralPath "$LogDir\err.log" -Tail 30 | ForEach-Object { Write-Log "err.log: $_" } }
        Stop-Installer 82 "El servicio $ServiceName no alcanzo Running dentro del timeout."
    }
}
else {
    Write-Log "Servicio conserva su estado inicial: $ServiceInitialStatus"
}

$svcCheck = Get-Service $ServiceName -ErrorAction SilentlyContinue

if (-not $svcCheck) {
Stop-Installer 81 "El servicio $ServiceName no existe despu�s de la instalaci�n."
}

Write-Log "Estado servicio: $($svcCheck.Status)"

if ($ServiceShouldRun) {
    if ($svcCheck.Status -ne "Running") {
        Stop-Installer 82 "El servicio $ServiceName no quedo en estado Running."
    }
    if (-not (Test-BackendHealth)) {
        if (Test-Path "$LogDir\out.log") { Get-Content -LiteralPath "$LogDir\out.log" -Tail 30 | ForEach-Object { Write-Log "out.log: $_" } }
        if (Test-Path "$LogDir\err.log") { Get-Content -LiteralPath "$LogDir\err.log" -Tail 30 | ForEach-Object { Write-Log "err.log: $_" } }
        Stop-Installer 84 "El servicio esta Running pero el backend no responde en $BackendHealthUrl."
    }
}
elseif ($ServiceInitialStatus -eq "Stopped") {
    if ($svcCheck.Status -ne "Stopped") {
        Stop-Installer 82 "El servicio $ServiceName no conserv� el estado Stopped."
    }
    Write-Log "Servicio sin cambios: se conserva estado Stopped"
}

Write-Log "Servicio ${ServiceName}: OK"

# =========================================================

# FRONTEND IIS

# =========================================================

$FrontendSource = "$BaseDir\out"

if (-not (Test-Path $FrontendSource)) {
Stop-Installer 90 "No se encontr� el frontend en $FrontendSource"
}

if (-not (Test-Path $FrontendOut)) {
New-Item -ItemType Directory -Path $FrontendOut -Force | Out-Null
}

Write-Log "Actualizando frontend"

foreach ($existingItem in @(Get-ChildItem -LiteralPath $FrontendOut -Force)) {
    Write-Log "Eliminando contenido anterior del frontend: $($existingItem.Name)"
    Remove-Item -LiteralPath $existingItem.FullName -Recurse -Force -ErrorAction Stop
}
foreach ($sourceItem in @(Get-ChildItem -LiteralPath $FrontendSource -Force)) {
    Copy-Item -LiteralPath $sourceItem.FullName -Destination (Join-Path $FrontendOut $sourceItem.Name) -Recurse -Force -ErrorAction Stop
}

if (-not (Test-Path $FrontendOut)) {
Stop-Installer 91 "El frontend no qued� correctamente instalado."
}

# =========================================================

# PRERREQUISITOS IIS

# =========================================================

try {
Import-Module ServerManager -ErrorAction Stop
}
catch {
Stop-Installer 30 "No fue posible cargar el m�dulo ServerManager para validar IIS."
}

$IisFeatures = @(
    "Web-Static-Content",
    "Web-Default-Doc"
)

foreach ($FeatureName in $IisFeatures) {
    try {
        $Feature = Get-WindowsFeature -Name $FeatureName -ErrorAction Stop
    }
    catch {
        Stop-Installer 30 "No fue posible consultar la caracter�stica IIS: $FeatureName"
    }

    if ($Feature.InstallState -eq "Installed") {
        Write-Log "Caracter�stica IIS ya instalada: $FeatureName"
    }
    else {
        Write-Log "Caracter�stica IIS no instalada: $FeatureName. Instalando..."
        try {
            $Result = Install-WindowsFeature -Name $FeatureName -ErrorAction Stop
        }
        catch {
            Stop-Installer 30 "No fue posible instalar la caracter�stica IIS: $FeatureName"
        }

        if (-not $Result.Success) {
            Stop-Installer 30 "No fue posible instalar la caracter�stica IIS: $FeatureName"
        }

        $FeatureAfter = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
        if (-not $FeatureAfter -or $FeatureAfter.InstallState -ne "Installed") {
            Stop-Installer 31 "La caracter�stica IIS $FeatureName no qued� instalada correctamente"
        }

        Write-Log "Caracter�stica IIS instalada correctamente: $FeatureName"
    }
}

# =========================================================

# IIS

# =========================================================

$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"

if (-not (Test-Path $appcmd)) {
Stop-Installer 92 "No se encontr� appcmd.exe. IIS no est� disponible."
}

$site = & $appcmd list site "impresionEtiquetas" 2>$null

if (-not $site) {

Write-Log "Sitio IIS impresionEtiquetas no existe. Creando..."

& $appcmd add site `
    /name:"impresionEtiquetas" `
    /bindings:"http/*:81:" `
    /physicalPath:"$FrontendOut"

if ($LASTEXITCODE -ne 0) {
    Stop-Installer 93 "No fue posible crear el sitio IIS."
}

Write-Log "Sitio IIS creado"

}
else {

Write-Log "Sitio IIS impresionEtiquetas ya existe"

# Mantener el sitio y asegurar que apunte al frontend correcto
& $appcmd set vdir `
    "impresionEtiquetas/" `
    /physicalPath:"$FrontendOut"

if ($LASTEXITCODE -ne 0) {
    Stop-Installer 93 "No fue posible asegurar la ruta fisica del sitio IIS."
}

& $appcmd set site "impresionEtiquetas" /bindings:"http/*:81:"
if ($LASTEXITCODE -ne 0) {
    Stop-Installer 93 "No fue posible asegurar el binding HTTP *:81 del sitio IIS."
}

Write-Log "Ruta f�sica IIS verificada"

}

# =========================================================

# VALIDACI�N FINAL

# =========================================================

Write-Log "=========================================="
Write-Log "VALIDACION FINAL"
Write-Log "=========================================="

if (-not (Test-Path $NodeExe)) {
Stop-Installer 100 "Validaci�n final: falta node.exe."
}

if (-not (Test-Path $NpmCmd)) {
Stop-Installer 101 "Validaci�n final: falta npm.cmd."
}

if (-not (Test-Path "$Backend\index.js")) {
Stop-Installer 102 "Validaci�n final: falta backend index.js."
}

if (-not (Test-Path "$OracleIC\oci.dll")) {
Stop-Installer 103 "Validaci�n final: falta oci.dll."
}

if (-not (Test-Path $NssmExe)) {
Stop-Installer 104 "Validaci�n final: falta NSSM."
}

if (-not (Test-Path $FrontendOut)) {
Stop-Installer 105 "Validaci�n final: falta frontend."
}

$finalSvc = Get-Service $ServiceName -ErrorAction SilentlyContinue

if (-not $finalSvc) {
Stop-Installer 106 "Validaci�n final: servicio no existe."
}

if ($ServiceShouldRun) {
    if ($finalSvc.Status -ne "Running") {
        Stop-Installer 106 "Validaci�n final: servicio no quedo Running."
    }
}
elseif ($ServiceInitialStatus -eq "Stopped") {
    if ($finalSvc.Status -ne "Stopped") {
        Stop-Installer 106 "Validaci�n final: servicio no conserv� estado Stopped."
    }
}

Write-Log "Validaci�n final servicio: $($finalSvc.Status)"

$finalSite = & $appcmd list site "impresionEtiquetas" 2>$null

if (-not $finalSite) {
Stop-Installer 107 "Validaci�n final: sitio IIS no existe."
}

$finalBinding = (& $appcmd list site "impresionEtiquetas" /text:bindings 2>$null) -join "`n"
$finalPhysicalPath = (& $appcmd list vdir "impresionEtiquetas/" /text:physicalPath 2>$null) -join "`n"
if ($finalBinding -notmatch [regex]::Escape("*:81:") -or $finalBinding -notmatch 'http') {
    Stop-Installer 108 "Validaci�n final: IIS no tiene el binding HTTP *:81."
}
if ($finalPhysicalPath.Trim() -ne $FrontendOut) {
    Stop-Installer 109 "Validaci�n final: IIS apunta a '$($finalPhysicalPath.Trim())' en vez de '$FrontendOut'."
}
if (-not (Test-FrontendHealth -Url "http://localhost:81")) {
    Stop-Installer 110 "Validaci�n final: el frontend no responde en http://localhost:81."
}

Write-Log "Node.js: OK"
Write-Log "npm: OK"
Write-Log "Backend: OK"
Write-Log "Oracle Instant Client: OK"
Write-Log "NSSM: OK"
Write-Log "Servicio MiBackendNode: $($finalSvc.Status)"
Write-Log "Frontend: OK"
Write-Log "IIS impresionEtiquetas: OK"

Write-Log "=========================================="
Write-Log "INSTALACION FINALIZADA CORRECTAMENTE"
$elapsed = (Get-Date) - $InstallerStart
Write-Log "DURACION TOTAL: $($elapsed.ToString('hh\:mm\:ss'))"
Write-Log "=========================================="

if ($TranscriptEnabled) {
try { Stop-Transcript | Out-Null } catch {}
}

exit 0

