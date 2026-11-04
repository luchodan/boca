# ================================================================
#  BOCA SOCIOS - Sesiones aisladas (perfil nuevo tipo invitado)
#
#  Cada sesion es un perfil NUEVO y vacio (InPrivate/Incognito, en su
#  propia carpeta temporal): no comparte cookies ni login con las demas.
#
#  Para que la PC no se trabe:
#   - abre de a una y espera a que la CPU baje antes de la siguiente
#   - vigila la RAM libre y frena antes de que Windows se cuelgue
#   - cada ventana usa la menor memoria posible (sin GPU, 1 proceso, etc.)
#   - el navegador corre con prioridad baja (mouse y teclado responden)
#
#  USO (desde tu PowerShell, en la carpeta del script):
#
#    Abrir 60 sesiones en Edge (por defecto):
#      powershell -ExecutionPolicy Bypass -File .\abrir_sesiones_boca.ps1
#
#    Abrir en Chrome:
#      powershell -ExecutionPolicy Bypass -File .\abrir_sesiones_boca.ps1 -Navegador Chrome
#
#    Cerrar todas y borrar los perfiles temporales:
#      powershell -ExecutionPolicy Bypass -File .\abrir_sesiones_boca.ps1 -Modo Cerrar
#
#  OPCIONES:
#    -Cantidad 80     Cuantas sesiones abrir (por defecto 60)
#    -ReservaMB 1200  RAM libre que se deja para Windows. Menos = entran mas,
#                     pero mas riesgo de que se trabe (no bajar de ~1000)
#    -CpuMax 85       No abre la siguiente hasta que la CPU baje de este %
#    -Liviano         Deja que el navegador "duerma" las ventanas tapadas:
#                     mucha menos CPU, pero la cola se actualiza mas lento
#    -ConGPU          Usa la placa de video (por defecto apagada: ahorra RAM)
# ================================================================

param(
    [ValidateSet('Abrir', 'Cerrar')]
    [string]$Modo = 'Abrir',
    [ValidateSet('Edge', 'Chrome')]
    [string]$Navegador = 'Edge',
    [int]$Cantidad = 60,
    [int]$ReservaMB = 1500,
    [int]$CpuMax = 80,
    [switch]$Liviano,
    [switch]$ConGPU
)

# ---- CONFIGURACION ----
$url              = "https://bocasocios.bocajuniors.com.ar/"
$prefijoCarpeta   = "boca_sesiones_"     # carpetas temporales en %TEMP%
$pausaMinSeg      = 2                    # espera minima entre sesiones
$pausaMaxSeg      = 30                   # espera maxima si la CPU sigue alta
$esperaRamMaxSeg  = 60                   # cuanto esperar a que se libere RAM
$anchoVentana     = 800
$altoVentana      = 600
# ---- FIN CONFIGURACION ----

# PowerShell con prioridad baja: el navegador que abre la hereda.
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}

# ---------------- Buscar navegador ----------------
if ($Navegador -eq 'Chrome') {
    $exeName    = 'chrome.exe'
    $flagPrivado = '--incognito'
    $candidatos = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
    )
} else {
    $exeName    = 'msedge.exe'
    $flagPrivado = '--inprivate'
    $candidatos = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
        "${env:LOCALAPPDATA}\Microsoft\Edge\Application\msedge.exe"
    )
}
try {
    $reg = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exeName" -ErrorAction Stop).'(default)'
    if ($reg) { $candidatos += $reg }
} catch {}

$exePath = $null
foreach ($p in $candidatos) {
    if ($p -and (Test-Path $p)) { $exePath = $p; break }
}

# ---------------- Funciones ----------------
function Get-RamLibreMB {
    try { return [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory).AvailableMBytes }
    catch {
        $os = Get-CimInstance Win32_OperatingSystem
        return [int]($os.FreePhysicalMemory / 1KB)
    }
}

function Get-CpuPct {
    try { return [int]((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average) }
    catch { return 0 }
}

# Procesos del navegador que son de NUESTRAS sesiones (no toca tu navegador normal)
function Get-ProcesosNuestros {
    @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains($prefijoCarpeta) })
}

function Get-CantidadAbiertas($procs) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $procs) {
        if ($p.CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
            $d = if ($matches[1]) { $matches[1] } else { $matches[2] }
            [void]$set.Add($d.TrimEnd('\').ToLower())
        }
    }
    return $set.Count
}

function Set-PrioridadBaja($procs) {
    foreach ($p in $procs) {
        try {
            $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop
            if ($gp.PriorityClass -eq 'Normal') { $gp.PriorityClass = 'BelowNormal' }
        } catch {}
    }
}

# Ruta para la linea de comandos: sin comillas (igual que el script original),
# salvo que tenga espacios
function Ruta([string]$p) {
    if ($p -match '\s') { return "`"$p`"" }
    return $p
}

# Espera a que la PC termine de cargar la ventana anterior
function Esperar-Calma {
    Start-Sleep -Seconds $pausaMinSeg
    $t = $pausaMinSeg
    while ($t -lt $pausaMaxSeg) {
        $cpu = Get-CpuPct
        if ($cpu -lt $CpuMax) { return $cpu }
        Write-Host "      CPU al $cpu%, esperando que baje..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
        $t += 3
    }
    return (Get-CpuPct)
}

# ================================================================
#  MODO CERRAR: cierra las sesiones y borra los perfiles temporales
# ================================================================
if ($Modo -eq 'Cerrar') {
    Write-Host ""
    Write-Host "  Cerrando sesiones de Boca..." -ForegroundColor Cyan
    $procs = Get-ProcesosNuestros
    $ids = @($procs | ForEach-Object { $_.ProcessId })
    foreach ($p in ($procs | Where-Object { $_.CommandLine -notmatch '--type=' })) {
        $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($gp) { try { [void]$gp.CloseMainWindow() } catch {} }
    }
    for ($t = 0; $t -lt 10; $t++) {
        Start-Sleep -Seconds 1
        if (@($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -eq 0) { break }
    }
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2

    $carpetas = @(Get-ChildItem -Path $env:TEMP -Directory -Filter "$prefijoCarpeta*" -ErrorAction SilentlyContinue)
    foreach ($c in $carpetas) { Remove-Item -LiteralPath $c.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "  Listo: sesiones cerradas y $($carpetas.Count) carpeta(s) temporal(es) borradas." -ForegroundColor Green
    Write-Host "  RAM libre: $(Get-RamLibreMB) MB" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ================================================================
#  MODO ABRIR
# ================================================================
if (-not $exePath) {
    Write-Host "ERROR: No se encontro $Navegador." -ForegroundColor Red
    Read-Host "Presiona Enter para cerrar"
    exit 1
}

# Extension de monitoreo (opcional, carpeta boca_monitor al lado del script)
$extensionPath = Join-Path $PSScriptRoot "boca_monitor"
$hasExtension  = Test-Path (Join-Path $extensionPath "manifest.json")

# Carpeta temporal de esta tanda
$tempBase = Join-Path $env:TEMP ($prefijoCarpeta + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

# Pantalla para acomodar las ventanas en cascada
$areaW = 1366; $areaH = 728
try {
    Add-Type -AssemblyName System.Windows.Forms
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $areaW = $wa.Width; $areaH = $wa.Height
} catch {}
$rangoX = [math]::Max(1, $areaW - $anchoVentana - 20)
$rangoY = [math]::Max(1, $areaH - $altoVentana - 20)

# Argumentos comunes (pensados para gastar lo minimo por ventana)
$argsBase = @(
    $flagPrivado,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-default-apps",
    "--disable-sync",
    "--disable-translate",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-component-extensions-with-background-pages",
    "--disable-features=Translate,MediaRouter,OptimizationHints",
    "--disable-site-isolation-trials",
    "--renderer-process-limit=1",
    "--disk-cache-size=16777216",
    "--safebrowsing-disable-auto-update",
    "--no-pings",
    "--mute-audio",
    "--window-size=$anchoVentana,$altoVentana"
)
if (-not $ConGPU) { $argsBase += "--disable-gpu" }
if (-not $Liviano) {
    # Mantiene activas las ventanas tapadas/minimizadas para que la cola siga avanzando
    $argsBase += "--disable-backgrounding-occluded-windows"
    $argsBase += "--disable-renderer-backgrounding"
    $argsBase += "--disable-background-timer-throttling"
}
if ($hasExtension) {
    $argsBase += "--disable-extensions-except=$(Ruta $extensionPath)"
    $argsBase += "--load-extension=$(Ruta $extensionPath)"
} else {
    $argsBase += "--disable-extensions"
}

# Header
$ramLibre = Get-RamLibreMB
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    BOCA SOCIOS - Sesiones aisladas ($Navegador)" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Sesiones:   $Cantidad (cada una con perfil nuevo)" -ForegroundColor Cyan
Write-Host "    RAM libre:  $ramLibre MB (reserva para Windows: $ReservaMB MB)" -ForegroundColor Cyan
Write-Host "    Modo:       $(if ($Liviano) { 'liviano (ventanas tapadas duermen)' } else { 'todas activas' }) | GPU: $(if ($ConGPU) { 'si' } else { 'no' })" -ForegroundColor Cyan
Write-Host "    Monitor:    $hasExtension" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Ctrl+C para frenar. Las ya abiertas quedan abiertas." -ForegroundColor DarkYellow
Write-Host ""

$porSesionMB  = 300      # estimacion inicial, se ajusta con lo medido
$abiertas     = 0
$avisoHecho   = $false
$tiempoInicio = Get-Date

for ($i = 1; $i -le $Cantidad; $i++) {

    # ---- Hay RAM para una mas sin trabar Windows? ----
    $ramLibre = Get-RamLibreMB
    $necesita = $ReservaMB + $porSesionMB
    if ($ramLibre -lt $necesita) {
        Write-Host "      RAM libre $ramLibre MB (necesito $necesita). Esperando hasta $esperaRamMaxSeg seg..." -ForegroundColor DarkYellow
        $t = 0
        while ($t -lt $esperaRamMaxSeg -and $ramLibre -lt $necesita) {
            Start-Sleep -Seconds 5; $t += 5
            $ramLibre = Get-RamLibreMB
        }
        if ($ramLibre -lt $necesita) {
            Write-Host ""
            Write-Host "  !! LIMITE DE RAM: $abiertas sesiones abiertas, $ramLibre MB libres." -ForegroundColor Red
            Write-Host "     Si seguis abriendo, la PC se va a poner muy lenta." -ForegroundColor Red
            Write-Host "     Cerra otros programas y elegi:" -ForegroundColor Red
            $r = Read-Host "     Enter = frenar aca | S = seguir igual | R = reintentar"
            if ($r -match '^[sS]') { $ReservaMB = 0 }
            elseif ($r -match '^[rR]') { $i--; continue }
            else { break }
        }
    }

    # ---- Abrir perfil nuevo ----
    $profileDir = Join-Path $tempBase ("s{0:D2}" -f $i)
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    $x = ($i * 37) % $rangoX
    $y = ($i * 29) % $rangoY

    # --user-data-dir propio = navegador separado = VENTANA nueva con sesion aislada
    # --new-window = aunque algo falle, nunca la agrega como pestana
    $argsList = @("--user-data-dir=$(Ruta $profileDir)", "--new-window", "--window-position=$x,$y") + $argsBase + $url
    $antes = $abiertas
    try {
        Start-Process -FilePath $exePath -ArgumentList $argsList
    } catch {
        Write-Host "  ERROR sesion $i : $_" -ForegroundColor Red
        continue
    }

    $cpu = Esperar-Calma

    # ---- Medir y ajustar ----
    $procs = Get-ProcesosNuestros
    Set-PrioridadBaja $procs
    $abiertas = Get-CantidadAbiertas $procs
    if ($abiertas -le $antes) {
        Write-Host "      !! La sesion $i no aparecio como ventana aislada propia (revisar)" -ForegroundColor Red
    }
    $memMB = [int](($procs | Measure-Object -Property PrivatePageCount -Sum).Sum / 1MB)
    if ($abiertas -gt 0) { $porSesionMB = [math]::Max(120, [int]($memMB / $abiertas)) }
    $ramLibre = Get-RamLibreMB
    $caben = [math]::Max(0, [int][math]::Floor(($ramLibre - $ReservaMB) / $porSesionMB))
    $faltan = $Cantidad - $i
    $elapsed = [int]((Get-Date) - $tiempoInicio).TotalSeconds

    if ($caben -lt $faltan) { $c = "Yellow" } else { $c = "Green" }
    if ($caben -le 2 -and $faltan -gt 0) { $c = "Red" }
    Write-Host ("  [{0,2}/{1}] abiertas {2,2} | RAM libre {3,6} MB | CPU {4,3}% | ~{5} MB c/u | entran ~{6} mas | {7}s" -f `
        $i, $Cantidad, $abiertas, $ramLibre, $cpu, $porSesionMB, $caben, $elapsed) -ForegroundColor $c

    # Aviso temprano si no van a entrar todas
    if (-not $avisoHecho -and $i -eq 3 -and $caben -lt $faltan) {
        $avisoHecho = $true
        Write-Host ""
        Write-Host "  >> Aviso: con tu RAM entran aprox $($i + $caben) de $Cantidad." -ForegroundColor Yellow
        Write-Host "     Para meter mas: cerra otros programas o usa -Liviano." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ---------------- Resumen ----------------
$procs   = Get-ProcesosNuestros
$total   = Get-CantidadAbiertas $procs
$minutos = [math]::Round(((Get-Date) - $tiempoInicio).TotalMinutes, 1)
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host "    SESIONES ABIERTAS: $total de $Cantidad" -ForegroundColor Green
Write-Host "    Tiempo: $minutos min | RAM libre: $(Get-RamLibreMB) MB" -ForegroundColor Green
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Para cerrar todas y borrar los perfiles temporales:" -ForegroundColor DarkGray
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Modo Cerrar" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Presiona Enter para cerrar esta ventana (las sesiones siguen abiertas)"
