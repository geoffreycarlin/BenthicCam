# GoPro GPS Cam - project setup / repair for Windows (PowerShell 5.1 or 7+).
#
# The project already ships a complete Android folder, so you normally don't
# need this. Use it if the Android build fails with Gradle / AGP / Kotlin
# version errors (e.g. you have an older Flutter):
#
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Regenerate
#
# -Regenerate deletes the android folder and recreates it for YOUR Flutter
# version, then re-adds the app's permissions. Without it, only missing
# files are added. Safe to run more than once.

param([switch]$Regenerate)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)   # UTF-8 without BOM

function Read-Text($path)        { [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $path).Path) }
function Write-Text($path, $txt) { [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot $path), $txt, $utf8) }

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter is not on your PATH. Install Flutter and reopen the terminal."
}

if ($Regenerate -and (Test-Path android)) {
    Write-Host "Regenerating android folder for your Flutter version..."
    Remove-Item android -Recurse -Force
}

# 1. Remove incomplete platform folders (an android folder without Gradle files
#    is what causes "Build failed due to use of deleted Android v1 embedding").
if ((Test-Path android) -and -not ((Test-Path android\build.gradle) -or (Test-Path android\build.gradle.kts))) {
    Write-Host "Removing incomplete android folder..."
    Remove-Item android -Recurse -Force
}
if ((Test-Path ios) -and -not (Test-Path ios\Runner.xcodeproj)) {
    Write-Host "Removing incomplete ios folder..."
    Remove-Item ios -Recurse -Force
}

# 2. Generate the platform projects (existing lib/, pubspec.yaml etc. are kept).
Write-Host "Generating Android and iOS project files..."
& flutter create --org com.goprogps --project-name gopro_gps_cam --platforms android,ios .
if ($LASTEXITCODE -ne 0) { throw "flutter create failed" }

# flutter create adds a sample test that refers to a class this app doesn't have.
if (Test-Path test\widget_test.dart) { Remove-Item test\widget_test.dart -Force }

# 3. Android permissions.
$manifestPath = 'android\app\src\main\AndroidManifest.xml'
$m = Read-Text $manifestPath
if ($m -notmatch 'BLUETOOTH_SCAN') {
    $perms = @'

    <!-- Bluetooth LE (GoPro control) -->
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
    <uses-feature android:name="android.hardware.bluetooth" android:required="false" />
    <!-- GPS (incl. background track recording) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <!-- GoPro Wi-Fi + HTTP download -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />
    <!-- Gallery save on Android 9 and older -->
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />
'@
    $reManifest = New-Object System.Text.RegularExpressions.Regex('(<manifest[^>]*>)')
    $m = $reManifest.Replace($m, '$1' + $perms.Replace('$', '$$'), 1)
    $reApp = New-Object System.Text.RegularExpressions.Regex('<application(?![^>]*usesCleartextTraffic)')
    $m = $reApp.Replace($m, '<application android:usesCleartextTraffic="true"', 1)
    $m = $m -replace 'android:label="gopro_gps_cam"', 'android:label="GoPro GPS Cam"'
    Write-Text $manifestPath $m
    Write-Host "Android permissions added."
}

# 4. iOS permissions (only matters when you build on a Mac).
$plistPath = 'ios\Runner\Info.plist'
$p = Read-Text $plistPath
if ($p -notmatch 'NSBluetoothAlwaysUsageDescription') {
    $keys = @'
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Bluetooth is used to control your GoPro and trigger the shutter.</string>
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>Your location is embedded into each GoPro photo you take.</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>The app downloads photos from your GoPro over its Wi-Fi network.</string>
	<key>NSPhotoLibraryAddUsageDescription</key>
	<string>Tagged photos can be saved to your photo library.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>

'@
    $i = $p.LastIndexOf('</dict>')
    $p = $p.Substring(0, $i) + $keys + $p.Substring($i)
    Write-Text $plistPath $p
    Write-Host "iOS permissions added."
}
if (-not (Test-Path ios\Runner\Runner.entitlements)) {
    Write-Text 'ios\Runner\Runner.entitlements' @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.networking.HotspotConfiguration</key>
	<true/>
	<key>com.apple.developer.networking.wifi-info</key>
	<true/>
</dict>
</plist>
'@
}

# 5. Fetch packages.
& flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

Write-Host ""
Write-Host "Setup complete. Plug in your Android phone (USB debugging on) and run:" -ForegroundColor Green
Write-Host "    flutter devices"
Write-Host "    flutter run -d <your-phone-id>"
Write-Host "or build an install file with:  flutter build apk --release"
