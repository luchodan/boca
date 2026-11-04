# ================================================================
#  BOCA SOCIOS - Maximo de sesiones con perfil y login propio (Edge)
#
#  Cada sesion es un perfil de Edge PERMANENTE y separado:
#  te logueas una vez en cada ventana y la proxima vez ya abre logueada.
#
#  Abre sesiones de a una, esperando que la PC se acomode entre cada
#  una, y sigue hasta que la RAM llega al limite (deja una reserva
#  para que Windows no se trabe). Asi abre el MAXIMO que aguanta tu PC.
#
#  USO (desde tu PowerShell, en la carpeta del script):
#
#    Abrir el maximo posible (por defecto):
#      powershell -ExecutionPolicy Bypass -File .\abrir_sesiones_boca.ps1
#
#    Loguear perfiles de a uno, con calma (opcional, antes del dia):
#      powershell -ExecutionPolicy Bypass -File .\abrir_sesiones_boca.ps1 -Modo Login
#
#    Cerrar todas las sesiones (no borra los logins):
#      powershell -ExecutionPolicy Bypass -File .\abrir_sesiones_boca.ps1 -Modo Cerrar
#
#  OPCIONES:
#    -Cantidad 40     Tope de sesiones (0 = sin tope, hasta donde aguante la PC)
#    -Desde 21        Empezar desde la sesion 21
#    -ReservaMB 1200  RAM libre que se deja para Windows (menos = mas sesiones,
#                     pero mas riesgo de que se trabe; no bajar de ~1000)
#    -CpuMax 85       No abre la siguiente hasta que la CPU baje de este %
#    -Liviano         Deja que Edge "duerma" las ventanas tapadas: mucha menos
#                     CPU, pero la pagina de la cola se actualiza mas lento
#    -ConGPU          Usa la placa de video (por defecto apagada para ahorrar RAM)
#
#  LISTA DE SOCIOS (opcional): crea "socios.txt" al lado del script, un
#  nombre por linea. Cada nombre tiene su propio perfil y su ventana se
#  titula con ese nombre. Sin lista, los perfiles se llaman Sesion_01, 02...
# ================================================================

param(
    [ValidateSet('Abrir', 'Login', 'Cerrar')]
    [string]$Modo = 'Abrir',
    [int]$Cantidad = 0,
    [int]$Desde = 1,
    [int]$ReservaMB = 1500,
    [int]$CpuMax = 80,
    [switch]$Liviano,
    [switch]$ConGPU
)

# ---- CONFIGURACION ----
$url               = "https://bocasocios.bocajuniors.com.ar/"
$carpetaPerfiles   = Join-Path $env:LOCALAPPDATA "BocaPerfiles"
$archivoSocios     = Join-Path $PSScriptRoot "socios.txt"
$topeSinLista      = 300     # techo de seguridad cuando no hay socios.txt
$pausaMinSeg       = 2       # espera minima entre una sesion y la siguiente
$pausaMaxSeg       = 30      # espera maxima si la CPU sigue alta
$esperaRamMaxSeg   = 45      # cuanto esperar a que se libere RAM antes de frenar
$anchoVentana      = 800
$altoVentana       = 600
# ---- FIN CONFIGURACION ----

$ErrorActionPreference = 'Continue'

# PowerShell con prioridad baja: las ventanas de Edge que abre la heredan,
# asi el mouse, el teclado y Windows siguen respondiendo.
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}

# ---------------- Buscar Edge ----------------
$edgePath = $null
$candidatos = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
    "${env:LOCALAPPDATA}\Microsoft\Edge\Application\msedge.exe"
)
try {
    $reg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)'
    if ($reg) { $candidatos += $reg }
} catch {}
foreach ($p in $candidatos) {
    if ($p -and (Test-Path $p)) { $edgePath = $p; break }
}
if (-not $edgePath) {
    Write-Host "ERROR: No se encontro Microsoft Edge." -ForegroundColor Red
    Read-Host "Presiona Enter para cerrar"
    exit 1
}

# Extension de monitoreo (opcional, carpeta boca_monitor al lado del script)
$extensionPath = Join-Path $PSScriptRoot "boca_monitor"
$hasExtension  = Test-Path (Join-Path $extensionPath "manifest.json")

New-Item -ItemType Directory -Path $carpetaPerfiles -Force | Out-Null

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

function Get-DirDePerfil([string]$cmd) {
    if ($cmd -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
        $d = if ($matches[1]) { $matches[1] } else { $matches[2] }
        return $d.TrimEnd('\').ToLower()
    }
    return $null
}

# Procesos de Edge que pertenecen a NUESTROS perfiles (no toca tu Edge normal)
function Get-ProcesosNuestros {
    $base = $carpetaPerfiles.ToLower()
    @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains($base) })
}

function Get-PerfilesAbiertos($procs) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $procs) {
        $d = Get-DirDePerfil $p.CommandLine
        if ($d) { [void]$set.Add($d) }
    }
    return , $set
}

function Set-PrioridadBaja($procs) {
    foreach ($p in $procs) {
        try {
            $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop
            if ($gp.PriorityClass -eq 'Normal') { $gp.PriorityClass = 'BelowNormal' }
        } catch {}
    }
}

function Cerrar-Instancias([string]$dirFiltro) {
    $procs = Get-ProcesosNuestros
    if ($dirFiltro) {
        $f = $dirFiltro.TrimEnd('\').ToLower()
        $procs = @($procs | Where-Object { (Get-DirDePerfil $_.CommandLine) -eq $f })
    }
    if ($procs.Count -eq 0) { return 0 }

    # Cierre prolijo de la ventana principal (asi Edge guarda cookies/login)
    $principales = @($procs | Where-Object { $_.CommandLine -notmatch '--type=' })
    foreach ($p in $principales) {
        $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($gp) { try { [void]$gp.CloseMainWindow() } catch {} }
    }
    $ids = @($procs | ForEach-Object { $_.ProcessId })
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Seconds 1
        $vivos = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($vivos.Count -eq 0) { break }
    }
    # Lo que no cerro solo, se fuerza
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    return $principales.Count
}

# Posiciones en cascada dentro de la pantalla
$areaW = 1366; $areaH = 728
try {
    Add-Type -AssemblyName System.Windows.Forms
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $areaW = $wa.Width; $areaH = $wa.Height
} catch {}

function Abrir-Perfil($perfil, [int]$idx) {
    New-Item -ItemType Directory -Path $perfil.Dir -Force | Out-Null

    $rangoX = [math]::Max(1, $areaW - $anchoVentana - 20)
    $rangoY = [math]::Max(1, $areaH - $altoVentana - 20)
    $x = ($idx * 37) % $rangoX
    $y = ($idx * 29) % $rangoY

    $a = @(
        "--user-data-dir=`"$($perfil.Dir)`"",
        "--window-name=`"$($perfil.Nombre)`"",
        "--window-size=$anchoVentana,$altoVentana",
        "--window-position=$x,$y",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-default-apps",
        "--disable-sync",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-component-extensions-with-background-pages",
        "--disable-features=Translate,MediaRouter,OptimizationHints",
        "--disable-site-isolation-trials",
        "--renderer-process-limit=1",
        "--disk-cache-size=33554432",
        "--no-pings",
        "--mute-audio"
    )
    if (-not $ConGPU) { $a += "--disable-gpu" }
    if (-not $Liviano) {
        # Mantiene vivas las ventanas tapadas/minimizadas para que la cola siga avanzando
        $a += "--disable-backgrounding-occluded-windows"
        $a += "--disable-renderer-backgrounding"
        $a += "--disable-background-timer-throttling"
    }
    if ($hasExtension) {
        $a += "--disable-extensions-except=`"$extensionPath`""
        $a += "--load-extension=`"$extensionPath`""
    } else {
        $a += "--disable-extensions"
    }
    $a += $url

    Start-Process -FilePath $edgePath -ArgumentList $a
}

# Espera a que la PC termine de cargar la ventana anterior antes de seguir
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

# ---------------- Lista de perfiles ----------------
function Limpiar-Nombre([string]$n) { ($n.Trim() -replace '[^\w\-]', '_') }

$hayLista = Test-Path $archivoSocios
$perfiles = New-Object System.Collections.ArrayList
if ($hayLista) {
    $usados = @{}
    $n = 0
    $nombres = Get-Content $archivoSocios -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
    foreach ($nom in $nombres) {
        $n++
        $base = Limpiar-Nombre $nom
        $carp = $base; $k = 2
        while ($usados.ContainsKey($carp.ToLower())) { $carp = "${base}_$k"; $k++ }
        $usados[$carp.ToLower()] = $true
        [void]$perfiles.Add([pscustomobject]@{ Num = $n; Nombre = $nom; Dir = (Join-Path $carpetaPerfiles $carp) })
    }
} else {
    for ($n = 1; $n -le $topeSinLista; $n++) {
        [void]$perfiles.Add([pscustomobject]@{
            Num    = $n
            Nombre = ("Sesion {0:D2}" -f $n)
            Dir    = (Join-Path $carpetaPerfiles ("Sesion_{0:D2}" -f $n))
        })
    }
}
$perfiles = @($perfiles | Where-Object { $_.Num -ge $Desde })
if ($Cantidad -gt 0) { $perfiles = @($perfiles | Select-Object -First $Cantidad) }

# ================================================================
#  MODO CERRAR
# ================================================================
if ($Modo -eq 'Cerrar') {
    Write-Host ""
    Write-Host "  Cerrando sesiones de Boca (tus logins quedan guardados)..." -ForegroundColor Cyan
    $c = Cerrar-Instancias $null
    Write-Host "  Listo: $c ventanas cerradas. RAM libre: $(Get-RamLibreMB) MB" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ================================================================
#  MODO LOGIN: de a un perfil, te logueas y se cierra
# ================================================================
if ($Modo -eq 'Login') {
    $tot = if ($hayLista -or $Cantidad -gt 0) { $perfiles.Count } else { "?" }
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "    BOCA SOCIOS - Loguear perfiles de a uno" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "    En cada ventana: inicia sesion y acepta guardar la contrasena"
    Write-Host "    si Edge lo ofrece. Despues volve aca:"
    Write-Host "      Enter = listo, siguiente | S = saltear | Q = terminar"
    Write-Host ""
    $i = 0
    foreach ($perfil in $perfiles) {
        $i++
        Write-Host "  [$i/$tot] $($perfil.Nombre)" -ForegroundColor Yellow
        Abrir-Perfil $perfil 0
        $r = Read-Host "      Enter / S / Q"
        Cerrar-Instancias $perfil.Dir | Out-Null
        if ($r -match '^[qQ]') { break }
    }
    Write-Host ""
    Write-Host "  Listo. Ahora corre el script sin -Modo para abrir todas." -ForegroundColor Green
    Read-Host "  Enter para cerrar"
    exit 0
}

# ================================================================
#  MODO ABRIR: el maximo posible
# ================================================================
$ramLibre = Get-RamLibreMB
$topeTxt  = if ($Cantidad -gt 0) { "$Cantidad" } elseif ($hayLista) { "$($perfiles.Count) (socios.txt)" } else { "sin tope (hasta llenar RAM)" }

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    BOCA SOCIOS - Maximo de sesiones (Edge, login propio)" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Tope:       $topeTxt" -ForegroundColor Cyan
Write-Host "    Perfiles:   $carpetaPerfiles" -ForegroundColor Cyan
Write-Host "    RAM libre:  $ramLibre MB (reserva para Windows: $ReservaMB MB)" -ForegroundColor Cyan
Write-Host "    Modo:       $(if ($Liviano) { 'liviano (ventanas tapadas duermen)' } else { 'todas activas' }) | GPU: $(if ($ConGPU) { 'si' } else { 'no' })" -ForegroundColor Cyan
Write-Host "    Monitor:    $hasExtension" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Ctrl+C para frenar. Las ya abiertas quedan abiertas." -ForegroundColor DarkYellow
Write-Host ""

$procs        = Get-ProcesosNuestros
$abiertos     = Get-PerfilesAbiertos $procs
$porSesionMB  = 300          # estimacion inicial, se ajusta con lo medido
$nuevas       = 0
$salteadas    = 0
$motivoFin    = "se abrieron todas las sesiones pedidas"
$tiempoInicio = Get-Date
$idx          = $abiertos.Count

foreach ($perfil in $perfiles) {

    if ($abiertos.Contains($perfil.Dir.TrimEnd('\').ToLower())) {
        $salteadas++
        continue
    }

    # ---- Hay lugar para una mas? ----
    $ramLibre = Get-RamLibreMB
    $necesita = $ReservaMB + $porSesionMB
    if ($ramLibre -lt $necesita) {
        Write-Host "      RAM libre $ramLibre MB, necesito $necesita MB. Esperando hasta $esperaRamMaxSeg seg..." -ForegroundColor DarkYellow
        $t = 0
        while ($t -lt $esperaRamMaxSeg -and $ramLibre -lt $necesita) {
            Start-Sleep -Seconds 5; $t += 5
            $ramLibre = Get-RamLibreMB
        }
        if ($ramLibre -lt $necesita) {
            $motivoFin = "LIMITE DE LA PC: no queda RAM para otra sesion sin trabar Windows"
            break
        }
    }

    # ---- Abrir ----
    try {
        Abrir-Perfil $perfil $idx
        $idx++
        $nuevas++
    } catch {
        Write-Host "  ERROR abriendo $($perfil.Nombre): $_" -ForegroundColor Red
        continue
    }

    $cpu = Esperar-Calma

    # ---- Medir y ajustar ----
    $procs = Get-ProcesosNuestros
    Set-PrioridadBaja $procs
    $abiertos = Get-PerfilesAbiertos $procs
    $memMB = [int](($procs | Measure-Object -Property PrivatePageCount -Sum).Sum / 1MB)
    if ($abiertos.Count -gt 0) {
        $porSesionMB = [math]::Max(120, [int]($memMB / $abiertos.Count))
    }
    $ramLibre = Get-RamLibreMB
    $caben = [math]::Max(0, [int][math]::Floor(($ramLibre - $ReservaMB) / $porSesionMB))
    $elapsed = [int]((Get-Date) - $tiempoInicio).TotalSeconds

    if ($caben -le 2) { $c = "Red" } elseif ($caben -le 8) { $c = "Yellow" } else { $c = "Green" }
    Write-Host ("  [{0,3} abiertas] {1,-20} | RAM libre {2,6} MB | CPU {3,3}% | ~{4} MB c/u | caben ~{5} mas | {6}s" -f `
        $abiertos.Count, $perfil.Nombre, $ramLibre, $cpu, $porSesionMB, $caben, $elapsed) -ForegroundColor $c
}

if (-not $hayLista -and $Cantidad -eq 0 -and $motivoFin -like "se abrieron*") {
    $motivoFin = "se llego al techo de seguridad ($topeSinLista)"
}

# ---------------- Resumen ----------------
$procs    = Get-ProcesosNuestros
$total    = (Get-PerfilesAbiertos $procs).Count
$minutos  = [math]::Round(((Get-Date) - $tiempoInicio).TotalMinutes, 1)
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host "    SESIONES ABIERTAS: $total  (nuevas: $nuevas, ya estaban: $salteadas)" -ForegroundColor Green
Write-Host "    Motivo de fin: $motivoFin" -ForegroundColor Green
Write-Host "    Tiempo: $minutos min | RAM libre: $(Get-RamLibreMB) MB" -ForegroundColor Green
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Las ventanas sin login: logueate ahi mismo, queda guardado para la proxima." -ForegroundColor DarkGray
Write-Host "  Si cerras alguna, volve a correr el script: reabre solo las que faltan." -ForegroundColor DarkGray
Write-Host "  Para cerrar todas:  .\abrir_sesiones_boca.ps1 -Modo Cerrar" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Presiona Enter para cerrar esta ventana (las sesiones siguen abiertas)"
