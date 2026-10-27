# The Windows smoke test (Vibecoding/BeeModel-Win11-Port-Plan.html, W7), run
# on GitHub's windows-latest by .github/workflows/windows.yml against the
# release zip that scripts/package.sh made on Linux:
#   the zip holds beemodel.exe and beemodel-gpu.exe, which import only
#   Windows system DLLs; --version says the version; --selftest passes; the
#   platform layer's own tests (build/test-*.exe, from tests/win/) pass; a
#   headless render (tests/win/smoke.bees) is the Linux build's image byte
#   for byte, and the scene it saved opens and renders the same again
#   (tests/win/reload.bees).
#   pwsh ci/check-windows.ps1 -Zip dist\beemodel-1.2.0-windows-x86_64.zip `
#        -Tests build -Ref build\smoke-linux.png -Version 1.2.0
param(
    [Parameter(Mandatory)] [string] $Zip,
    [Parameter(Mandatory)] [string] $Tests,
    [Parameter(Mandatory)] [string] $Ref,
    [Parameter(Mandatory)] [string] $Version
)
$ErrorActionPreference = 'Stop'
function Fail($msg) { Write-Host "FAIL: $msg"; exit 1 }
$Repo = Split-Path -Parent $PSScriptRoot

$work = Join-Path ([IO.Path]::GetTempPath()) ("bee-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
Expand-Archive -Path $Zip -DestinationPath $work
$dir = Get-ChildItem -Path $work -Directory | Select-Object -First 1
if (-not $dir) { Fail "$Zip holds no folder" }
$exe = Join-Path $dir.FullName 'beemodel.exe'
foreach ($f in 'beemodel.exe', 'beemodel-gpu.exe', 'README.md', 'LICENSE', 'WINDOWS.md') {
    if (-not (Test-Path (Join-Path $dir.FullName $f))) { Fail "$Zip has no $f" }
}
Write-Host "unpacked $($dir.Name): $((Get-ChildItem $dir.FullName).Name -join ' ')"

# a home of its own, no GPU: the runner has none, and the image must be the CPU's
$home_ = Join-Path $work 'home'
New-Item -ItemType Directory -Path $home_ | Out-Null
$env:BEEMODEL_HOME = $home_
$env:BEEMODEL_GPU = 'off'

$got = (& $exe --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Fail "--version exited with $LASTEXITCODE" }
if ($got -ne "beemodel $Version") { Fail "--version: '$got', not 'beemodel $Version'" }
Write-Host "--version: $got"

$out = & $exe --selftest | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host $out; Fail "--selftest exited with $LASTEXITCODE" }
Write-Host "--selftest: $(($out.Trim() -split "`n")[-1].Trim())"

$n = 0
foreach ($t in Get-ChildItem -Path $Tests -Filter 'test-*.exe') {
    $out = & $t.FullName | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host (($out -split "`n") | Where-Object { $_ -notmatch '^  ok ' }) -Separator "`n"
        Fail "$($t.Name): $LASTEXITCODE checks failed"
    }
    Write-Host "$($t.Name) passed"
    $n++
}
if ($n -eq 0) { Fail "no test-*.exe in $Tests" }

$scene = Join-Path $work 'scene'
New-Item -ItemType Directory -Path $scene | Out-Null
Copy-Item (Join-Path $Repo 'tests\win\smoke.bees'), (Join-Path $Repo 'tests\win\reload.bees') $scene
Push-Location $scene
try {
    foreach ($s in 'smoke.bees', 'reload.bees') {
        $out = (& $exe --run $s | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { Write-Host $out; Fail "--run $s exited with $LASTEXITCODE" }
        Write-Host "--run ${s}: $out"
    }
} finally { Pop-Location }
$want = (Get-FileHash $Ref).Hash
foreach ($png in 'smoke.png', 'reload.png') {
    $p = Join-Path $scene $png
    if (-not (Test-Path $p)) { Fail "no $png" }
    if ((Get-FileHash $p).Hash -ne $want) { Fail "$png is not the Linux build's image" }
    Write-Host "$png is the Linux build's image byte for byte"
}

Remove-Item -Recurse -Force $work
Write-Host "Windows smoke test passed"
