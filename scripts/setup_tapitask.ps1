# Tapitask - Build assisté des clients sur Windows (PowerShell).
# Usage : powershell -ExecutionPolicy Bypass -File scripts\setup_tapitask.ps1
# Produit dans dist\ : Tapitask-windows.zip (exe) et Tapitask.apk.

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Dist = Join-Path $Root "dist"
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

Write-Host "==========================================" 
Write-Host "   Tapitask - build des clients (Windows)"
Write-Host "=========================================="

function Ask($prompt) {
    $v = Read-Host "$prompt"
    return $v
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host "[X] Flutter introuvable dans le PATH. Installe-le : https://docs.flutter.dev/get-started/install/windows" -ForegroundColor Red
    exit 1
}

# --- Initialisation des plateformes ----------------------------------------
if (-not (Test-Path "$Root\app\windows") -or -not (Test-Path "$Root\app\android")) {
    Write-Host "==> Initialisation des plateformes..."
    bash "$PSScriptRoot\init_flutter.sh"
    if ($LASTEXITCODE -ne 0) {
        # init_flutter.sh requiert bash (Git Bash). Fallback manuel :
        Write-Host "[!] bash introuvable (installe Git for Windows) - fallback manuel" -ForegroundColor Yellow
        Push-Location "$Root\app"
        flutter create . --project-name tapitask --org com.tapitask --platforms=windows,android,web
        flutter pub get
        dart run build_runner build --delete-conflicting-outputs
        Pop-Location
    }
} else {
    Write-Host "[OK] Plateformes deja initialisees"
    Push-Location "$Root\app"
    flutter pub get
    dart run build_runner build --delete-conflicting-outputs
    Pop-Location
}

$buildWin = (Ask "Builder l'executable Windows ? [O/n]") ; if (-not $buildWin) { $buildWin = "O" }
$buildApk = (Ask "Builder l'APK Android ? [O/n]") ; if (-not $buildApk) { $buildApk = "O" }

# --- Version (C2.12) : param APP_VERSION > tag git le plus proche > "dev" ---
# --dart-define fixe la version affichee (sinon "dev", figee au build).
$appVersion = if ($env:APP_VERSION) {
    $env:APP_VERSION
} else {
    try { (git describe --tags 2>$null) } catch { "dev" }
}
if (-not $appVersion) { $appVersion = "dev" }
Write-Host "Version : $appVersion"

Push-Location "$Root\app"

if ($buildApk -eq "O" -or $buildApk -eq "o") {
    # Keystore de signature (une seule fois) — C2.12 : le gradle lit
    # android/app/key.properties (rootProject.file("app/key.properties"))
    $keyProps = "android\app\key.properties"
    if (-not (Test-Path $keyProps)) {
        $makeKs = (Ask "Creer un keystore de signature pour l'APK ? (recommande) [O/n]")
        if (-not $makeKs) { $makeKs = "O" }
        if ($makeKs -eq "O" -or $makeKs -eq "o") {
            if (Get-Command keytool -ErrorAction SilentlyContinue) {
                $ksPass = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
                & keytool -genkeypair -v -keystore "$Root\tapitask.keystore" -alias tapitask `
                    -keyalg RSA -keysize 2048 -validity 10000 -storepass $ksPass -keypass $ksPass `
                    -dname "CN=Tapitask, O=Tapitask" | Out-Null
                # M7 (prod4) : chemins forward-slash dans key.properties —
                # java.util.Properties.load interprète les backslash comme
                # échappements (\U, \t, …) : "C:\Tapitask" deviendrait un
                # tab. (Test : pwsh indispo sur cette machine — diff lu.)
                "storeFile=($Root -replace '\\', '/')/tapitask.keystore`nstorePassword=$ksPass`nkeyPassword=$ksPass`nkeyAlias=tapitask" | Out-File $keyProps -Encoding ascii
                Write-Host "[OK] Keystore cree (mot de passe dans android\app\key.properties - NE PAS COMMITER)" -ForegroundColor Green
            } else {
                Write-Host "[!] keytool introuvable (installe un JDK) - APK signe en debug" -ForegroundColor Yellow
            }
        }
    }
    Write-Host "==> flutter build apk --release..."
    flutter build apk --release "--dart-define=APP_VERSION=$appVersion"
    Copy-Item "build\app\outputs\flutter-apk\app-release.apk" "$Dist\Tapitask.apk" -Force
    Write-Host "[OK] APK : dist\Tapitask.apk" -ForegroundColor Green
}

if ($buildWin -eq "O" -or $buildWin -eq "o") {
    Write-Host "==> flutter build windows --release..."
    flutter build windows --release "--dart-define=APP_VERSION=$appVersion"
    $releaseDir = "build\windows\x64\runner\Release"
    Compress-Archive -Path "$releaseDir\*" -DestinationPath "$Dist\Tapitask-windows.zip" -Force
    Write-Host "[OK] Windows : dist\Tapitask-windows.zip (contient tapitask.exe + DLLs)" -ForegroundColor Green
}

Pop-Location

Write-Host ""
Write-Host "=========================================="
Write-Host "[OK] Builds termines - artefacts dans dist\" -ForegroundColor Green
Write-Host "=========================================="
Get-ChildItem $Dist
Write-Host ""
Write-Host "Installation :"
Write-Host "  Windows : dezippe Tapitask-windows.zip -> tapitask.exe (icone T dans le systray)"
Write-Host "  Android : installe Tapitask.apk puis ajoute le widget Tapitask"
