# Windows Portable Zip Packaging Script for OpenScreen
param(
    [string]$DistDir = "dist",
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Resolve-Path "$scriptDir\..\.."
Set-Location $rootDir

Write-Host "=== Building OpenScreen ReleaseFast for Windows ===" -ForegroundColor Cyan
zig build -Doptimize=ReleaseFast

$stageDir = "$DistDir\OpenScreen-v$Version-win64"
if (Test-Path $stageDir) {
    Remove-Item -Path $stageDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
New-Item -ItemType Directory -Force -Path "$stageDir\assets" | Out-Null

Write-Host "=== Staging Binaries and Dependencies ===" -ForegroundColor Cyan
Copy-Item "zig-out\bin\openscreen.exe" -Destination "$stageDir\openscreen.exe" -Force

# Stage DLLs (wgpu_native, ffmpeg, onnxruntime, etc.)
Get-ChildItem -Path . -Filter "*.dll" -Recurse | ForEach-Object {
    Copy-Item $_.FullName -Destination $stageDir -Force
}

# Stage Assets and Notices
Copy-Item "assets\*" -Destination "$stageDir\assets\" -Recurse -Force
Copy-Item "LICENSE" -Destination "$stageDir\LICENSE.txt" -Force
Copy-Item "THIRD-PARTY-NOTICES.md" -Destination "$stageDir\THIRD-PARTY-NOTICES.txt" -Force

$zipOutput = "$DistDir\OpenScreen-v$Version-windows-x64-portable.zip"
if (Test-Path $zipOutput) {
    Remove-Item -Path $zipOutput -Force
}

Write-Host "=== Creating Portable Zip: $zipOutput ===" -ForegroundColor Green
Compress-Archive -Path "$stageDir\*" -DestinationPath $zipOutput -CompressionLevel Optimal

Write-Host "Portable package created successfully." -ForegroundColor Green
