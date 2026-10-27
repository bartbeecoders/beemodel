# BeeModel - keeps the VM's job runner going: runs the runner the host
# published (bee-run\runner-<hash>.ps1, one at a time) from a local copy;
# the runner ends itself when the host publishes another. Registered by
# setup.ps1 to start, hidden, at every log-on.
$share = '\\host.lan\Data\bee-run'
$local = 'C:\bee-run'
while ($true) {
    try {
        $r = Get-ChildItem -Path $share -Filter 'runner-*.ps1' | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($r) {
            Copy-Item $r.FullName "$local\$($r.Name)" -Force
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$local\$($r.Name)"
            Remove-Item "$local\$($r.Name)" -ErrorAction SilentlyContinue
        }
    } catch { }
    Start-Sleep -Seconds 2
}
