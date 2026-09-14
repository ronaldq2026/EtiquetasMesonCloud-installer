Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

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

$CurrentStage = "Inicio"
trap {
    $unexpectedMessage = $_.Exception.Message
    Write-Log "ERROR: Excepción inesperada en etapa [$CurrentStage]: $unexpectedMessage"
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
        Stop-Installer 20 "No existe un paquete KB2999226 definido para la versión de Windows: $version"
    }

    if (-not (Test-Path $KbFile)) {
        Stop-Installer 20 "No se encontró $KbFile"
    }

    Write-Log "KB2999226 no encontrado. Instalando..."

    $kbProcess = Start-Process `
        -FilePath "wusa.exe" `
        -ArgumentList "`"$KbFile`" /quiet /norestart" `
        -Wait `
        -PassThru

    Write-Log "Resultado instalación KB2999226: $($kbProcess.ExitCode)"

    if ($kbProcess.ExitCode -ne 0 -and $kbProcess.ExitCode -ne 3010) {
        Stop-Installer 21 "Falló la instalación de KB2999226. Código: $($kbProcess.ExitCode)"
    }

    $kbAfterInstall = Get-HotFix -Id KB2999226 -ErrorAction SilentlyContinue
    if ($kbProcess.ExitCode -eq 3010) {
        Write-Log "KB2999226 requiere reinicio; no se reiniciará automáticamente."
        if ($kbAfterInstall) {
            Write-Log "KB2999226 confirmado después de la instalación."
        }
        else {
            Write-Log "KB2999226 pendiente de confirmación hasta reiniciar el servidor."
        }
    }
    elseif (-not $kbAfterInstall) {
        Stop-Installer 22 "KB2999226 no quedó confirmado después de la instalación."
    }
    else {
        Write-Log "KB2999226 confirmado después de la instalación."
    }
}
else {
    Write-Log "KB2999226 ya está instalado"
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
        Stop-Installer 22 "No se encontró $VcFile"
    }

    Write-Log "Visual C++ Redistributable no encontrado. Instalando..."

    $vcProcess = Start-Process `
        -FilePath $VcFile `
        -ArgumentList "/quiet /norestart" `
        -Wait `
        -PassThru

    Write-Log "Resultado instalación Visual C++: $($vcProcess.ExitCode)"

    if ($vcProcess.ExitCode -ne 0 -and $vcProcess.ExitCode -ne 3010) {
        Stop-Installer 23 "Falló la instalación de Visual C++. Código: $($vcProcess.ExitCode)"
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
Write-Log "Node.js no está instalado"
$NodeNeedsInstall = $true
}
else {

try {
    $nodeVersion = (& $NodeExe --version 2>&1).ToString().Trim()
    Write-Log "Node.js detectado: $nodeVersion"

    if ($nodeVersion -ne "v$TargetNodeVersion") {
        Write-Log "Versión Node diferente de la requerida"
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
    Stop-Installer 30 "No se encontró $NodeMsi"
}

Write-Log "Instalando/actualizando Node.js $TargetNodeVersion"

$nodeProcess = Start-Process `
    -FilePath "msiexec.exe" `
    -ArgumentList "/i `"$NodeMsi`" /qn /norestart" `
    -Wait `
    -PassThru

Write-Log "Resultado instalación Node.js: $($nodeProcess.ExitCode)"

if ($nodeProcess.ExitCode -ne 0 -and $nodeProcess.ExitCode -ne 3010) {
    Stop-Installer 31 "Falló la instalación de Node.js. Código: $($nodeProcess.ExitCode)"
}

}

# -------------------------

# Validar Node

# -------------------------

if (-not (Test-Path $NodeExe)) {
Stop-Installer 32 "Node.js no quedó instalado correctamente."
}

$nodeVersion = (& $NodeExe --version 2>&1).ToString().Trim()

if ($nodeVersion -ne "v$TargetNodeVersion") {
Stop-Installer 33 "Versión Node incorrecta. Esperada v$TargetNodeVersion, encontrada $nodeVersion"
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
    Stop-Installer 36 "Versión npm incorrecta. Esperada $TargetNpmVersion, encontrada $npmVersion"
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
    Stop-Installer 40 "No se encontró el Instant Client en $OracleSource"
}

Write-Log "Oracle Instant Client no encontrado. Copiando..."

New-Item -ItemType Directory -Path "C:\oracle" -Force | Out-Null

Copy-Item `
    $OracleSource `
    "C:\oracle" `
    -Recurse `
    -Force

if (-not (Test-Path $OracleIC)) {
    Stop-Installer 41 "El Oracle Instant Client no quedó instalado correctamente."
}

Write-Log "Oracle Instant Client 19.30 instalado"

}

# Validación básica

if (-not (Test-Path "$OracleIC\oci.dll")) {
Stop-Installer 42 "No se encontró oci.dll en el Instant Client."
}

if (-not (Test-Path "$OracleIC\oraociei19.dll")) {
Stop-Installer 43 "No se encontró oraociei19.dll en el Instant Client."
}

Write-Log "Oracle Instant Client: OK"

# =========================================================

# BACKEND

# =========================================================

$BackendSource = "$BaseDir\backend-dbf"

if (-not (Test-Path $BackendSource)) {
Stop-Installer 50 "No se encontró el backend en $BackendSource"
}

$BackendExists = Test-Path $Backend
$CurrentStage = "Detección de cambios del backend"
$BackendChanged = $false
$InitialService = Get-Service $ServiceName -ErrorAction SilentlyContinue
$ServiceInitialStatus = $null
if ($InitialService) {
    $ServiceInitialStatus = $InitialService.Status.ToString()
    Write-Log "Servicio existente: estado inicial $ServiceInitialStatus"
}

if (-not $BackendExists) {
    $BackendChanged = $true
    Write-Log "Backend: CAMBIOS DETECTADOS"
    Write-Log "Instalación nueva: copiando backend de aplicación"
    New-Item -ItemType Directory -Path $Backend -Force | Out-Null
    Get-ChildItem $BackendSource -Force | Where-Object {
        $_.Name -ne "data" -and $_.Name -ne "logs" -and $_.Name -ne "node_modules"
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
        if ($InitialService -and $ServiceInitialStatus -eq "Running") {
            Write-Log "Servicio detenido por actualización de backend"
            Stop-Service $ServiceName -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
            $stoppedService = Get-Service $ServiceName -ErrorAction SilentlyContinue
            if ($stoppedService -and $stoppedService.Status -ne "Stopped") {
                Stop-Installer 52 "El servicio $ServiceName no quedó detenido antes de actualizar el backend."
            }
        }

        Write-Log "Actualizando archivos de aplicación del backend"
        foreach ($relativePath in $installedSnapshot.Keys) {
            if (-not $sourceSnapshot.ContainsKey($relativePath)) {
                $deletedFile = Join-Path $Backend $relativePath
                Write-Log "Eliminando archivo de aplicación obsoleto: $relativePath"
                Remove-Item -LiteralPath $deletedFile -Force -ErrorAction Stop
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
Stop-Installer 51 "El backend no contiene index.js después de la actualización."
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

# Configuración npm silenciosa

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
Stop-Installer 63 "Falló npm install."
}

# -------------------------

# oracledb según SO

# -------------------------

Write-Log "Configurando oracledb $OracleDbVersion"

$npmResult = Invoke-Npm "install oracledb@$OracleDbVersion --silent"
$oracleInstallExit = [int]$npmResult.ExitCode

Write-Log "Instalación oracledb exit code: $oracleInstallExit"

if ($oracleInstallExit -ne 0) {
foreach ($line in @($npmResult.Output)) { Write-Log "npm: $($line.ToString())" }
Stop-Installer 64 "Falló la instalación de oracledb@$OracleDbVersion."
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
Stop-Installer 65 "La versión de oracledb instalada no corresponde a la requerida: $OracleDbVersion"
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
    Stop-Installer 70 "No se encontró NSSM en $NssmSource"
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
$ServiceNeedsStart = $false
$ServiceWasCreated = $false

if (-not $svc) {

Write-Log "Servicio $ServiceName no existe. Creando..."

& $NssmExe install $ServiceName $NodeExe "$Backend\index.js"

if ($LASTEXITCODE -ne 0) {
    Stop-Installer 80 "No fue posible crear el servicio NSSM."
}

& $NssmExe set $ServiceName AppDirectory $Backend

& $NssmExe set $ServiceName AppStdout "$LogDir\out.log"
& $NssmExe set $ServiceName AppStderr "$LogDir\err.log"

& $NssmExe set $ServiceName AppRotateFiles 1
& $NssmExe set $ServiceName AppRotateOnline 1
& $NssmExe set $ServiceName AppRotateSeconds 86400

& $NssmExe set $ServiceName AppEnvironmentExtra "PATH=$OracleIC;$NodeDir;%PATH%"

& $NssmExe set $ServiceName Start SERVICE_AUTO_START

Write-Log "Servicio NSSM creado"
$ServiceNeedsStart = $true
$ServiceWasCreated = $true

}
else {

Write-Log "Servicio $ServiceName ya existe"
Write-Log "Servicio existente conservado; no se elimina ni recrea"

if (-not $BackendChanged) {
    Write-Log "Servicio no detenido"
}
else {
    Write-Log "Servicio existente: configuración NSSM conservada"
}

}

# =========================================================

# INICIAR SERVICIO

# =========================================================

if ($ServiceWasCreated -or ($BackendChanged -and $ServiceInitialStatus -eq "Running")) {
    $ServiceNeedsStart = $true
    Write-Log "Iniciando servicio $ServiceName"
    & $NssmExe start $ServiceName
    Start-Sleep -Seconds 5
}
else {
    Write-Log "Servicio conserva su estado inicial: $ServiceInitialStatus"
}

$svcCheck = Get-Service $ServiceName -ErrorAction SilentlyContinue

if (-not $svcCheck) {
Stop-Installer 81 "El servicio $ServiceName no existe después de la instalación."
}

Write-Log "Estado servicio: $($svcCheck.Status)"

if ($ServiceWasCreated -or $ServiceInitialStatus -eq "Running") {
    if ($svcCheck.Status -ne "Running") {
        Stop-Installer 82 "El servicio $ServiceName no quedó en estado Running."
    }
}
elseif ($ServiceInitialStatus -eq "Stopped") {
    if ($svcCheck.Status -ne "Stopped") {
        Stop-Installer 82 "El servicio $ServiceName no conservó el estado Stopped."
    }
    Write-Log "Servicio sin cambios: se conserva estado Stopped"
}

Write-Log "Servicio ${ServiceName}: OK"

# =========================================================

# FRONTEND IIS

# =========================================================

$FrontendSource = "$BaseDir\out"

if (-not (Test-Path $FrontendSource)) {
Stop-Installer 90 "No se encontró el frontend en $FrontendSource"
}

if (-not (Test-Path $FrontendOut)) {
New-Item -ItemType Directory -Path $FrontendOut -Force | Out-Null
}

Write-Log "Actualizando frontend"

Copy-Item "$FrontendSource\*" $FrontendOut -Recurse -Force

if (-not (Test-Path $FrontendOut)) {
Stop-Installer 91 "El frontend no quedó correctamente instalado."
}

# =========================================================

# PRERREQUISITOS IIS

# =========================================================

try {
Import-Module ServerManager -ErrorAction Stop
}
catch {
Stop-Installer 30 "No fue posible cargar el módulo ServerManager para validar IIS."
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
        Stop-Installer 30 "No fue posible consultar la característica IIS: $FeatureName"
    }

    if ($Feature.InstallState -eq "Installed") {
        Write-Log "Característica IIS ya instalada: $FeatureName"
    }
    else {
        Write-Log "Característica IIS no instalada: $FeatureName. Instalando..."
        try {
            $Result = Install-WindowsFeature -Name $FeatureName -ErrorAction Stop
        }
        catch {
            Stop-Installer 30 "No fue posible instalar la característica IIS: $FeatureName"
        }

        if (-not $Result.Success) {
            Stop-Installer 30 "No fue posible instalar la característica IIS: $FeatureName"
        }

        $FeatureAfter = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
        if (-not $FeatureAfter -or $FeatureAfter.InstallState -ne "Installed") {
            Stop-Installer 31 "La característica IIS $FeatureName no quedó instalada correctamente"
        }

        Write-Log "Característica IIS instalada correctamente: $FeatureName"
    }
}

# =========================================================

# IIS

# =========================================================

$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"

if (-not (Test-Path $appcmd)) {
Stop-Installer 92 "No se encontró appcmd.exe. IIS no está disponible."
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

Write-Log "Ruta física IIS verificada"

}

# =========================================================

# VALIDACIÓN FINAL

# =========================================================

Write-Log "=========================================="
Write-Log "VALIDACION FINAL"
Write-Log "=========================================="

if (-not (Test-Path $NodeExe)) {
Stop-Installer 100 "Validación final: falta node.exe."
}

if (-not (Test-Path $NpmCmd)) {
Stop-Installer 101 "Validación final: falta npm.cmd."
}

if (-not (Test-Path "$Backend\index.js")) {
Stop-Installer 102 "Validación final: falta backend index.js."
}

if (-not (Test-Path "$OracleIC\oci.dll")) {
Stop-Installer 103 "Validación final: falta oci.dll."
}

if (-not (Test-Path $NssmExe)) {
Stop-Installer 104 "Validación final: falta NSSM."
}

if (-not (Test-Path $FrontendOut)) {
Stop-Installer 105 "Validación final: falta frontend."
}

$finalSvc = Get-Service $ServiceName -ErrorAction SilentlyContinue

if (-not $finalSvc) {
Stop-Installer 106 "Validación final: servicio no existe."
}

if ($ServiceWasCreated -or $ServiceInitialStatus -eq "Running") {
    if ($finalSvc.Status -ne "Running") {
        Stop-Installer 106 "Validación final: servicio no quedó Running."
    }
}
elseif ($ServiceInitialStatus -eq "Stopped") {
    if ($finalSvc.Status -ne "Stopped") {
        Stop-Installer 106 "Validación final: servicio no conservó estado Stopped."
    }
}

Write-Log "Validación final servicio: $($finalSvc.Status)"

$finalSite = & $appcmd list site "impresionEtiquetas" 2>$null

if (-not $finalSite) {
Stop-Installer 107 "Validación final: sitio IIS no existe."
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
