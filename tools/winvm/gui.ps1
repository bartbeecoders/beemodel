# BeeModel - drive beemodel.exe's window in the Windows 11 VM, for the
# window checks of the port (Vibecoding/BeeModel-Win11-Port-Plan.html, W4).
# Run as a job: tools/winvm-run.sh copies this next to beemodel.exe, e.g.
#   tools/winvm-run.sh 'powershell -ExecutionPolicy Bypass -File gui.ps1 start "click 925 580" state "shot w.png" quit'
# Input is posted to BeeModel's window as the messages Windows would send,
# so nothing takes the focus or reaches another program on the desktop;
# held modifiers go through the window thread's key state (attached input).
# Screenshots are of the window alone (PrintWindow). Steps, one argument each:
#   start [args]       start beemodel.exe and wait for its window
#   wait <ms>          let it work
#   move|click|dclick|rclick|mclick <x> <y>     client pixels
#   drag <x0> <y0> <x1> <y1>                    the left button, in 8 moves
#   wheel <x> <y> <notches>                     up > 0
#   key <name>[+name...]   a Keys name (Return, F3, A, ...) with Shift, Ctrl, Alt
#   text <string>      typed key by key (VkKeyScan: the layout in use)
#   shot <file.png>    the window, as Windows shows it (into the share's bee-run)
#   state              its rectangle, maximized, minimized
#   clipset <text>, clipget     the Windows clipboard
#   show <SW_ number>  ShowWindow from outside (9 restore)
#   quit               end beemodel.exe
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Name U -Namespace BeeGui -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, int[] r);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, int[] r);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern short VkKeyScan(char c);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool on);
[DllImport("user32.dll")] public static extern bool GetKeyboardState(byte[] s);
[DllImport("user32.dll")] public static extern bool SetKeyboardState(byte[] s);
'@
[BeeGui.U]::SetProcessDPIAware() | Out-Null
$h = [IntPtr]::Zero
$proc = $null
function Win { if ($script:h -eq [IntPtr]::Zero) { $script:h = [BeeGui.U]::FindWindow('BeeModel', [NullString]::Value) }; $script:h }
function Post($m, $w, $l) { [BeeGui.U]::PostMessage((Win), $m, [IntPtr]$w, [IntPtr]$l) | Out-Null }
function XY($x, $y) { ([int]$y -shl 16) -bor ([int]$x -band 0xffff) }
function Mouse($down, $up, $btn, $x, $y) {
    Post 0x200 0 (XY $x $y); Start-Sleep -Milliseconds 30
    Post $down $btn (XY $x $y); Start-Sleep -Milliseconds 60
    Post $up 0 (XY $x $y); Start-Sleep -Milliseconds 60
}
# keys: vk codes; mods: 1 Shift, 2 Ctrl, 4 Alt
function KeyLp($vk, $up) {
    $sc = [BeeGui.U]::MapVirtualKey($vk, 0)
    $ext = 0
    if (@(0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2D,0x2E) -contains $vk) { $ext = 1 }
    $l = 1 -bor ($sc -shl 16) -bor ($ext -shl 24)
    if ($up) { $l = $l -bor 0xC0000000 }
    [Int64][UInt32]$l
}
function Press($vk, $mods) {
    $me = [BeeGui.U]::GetCurrentThreadId()
    $them = [BeeGui.U]::GetWindowThreadProcessId((Win), [IntPtr]::Zero)
    [BeeGui.U]::AttachThreadInput($me, $them, $true) | Out-Null
    $ks = New-Object byte[] 256
    $held = @()
    if ($mods -band 1) { $held += 0x10 }
    if ($mods -band 2) { $held += 0x11 }
    if ($mods -band 4) { $held += 0x12 }
    $lr = @{0x10 = 0xA0; 0x11 = 0xA2; 0x12 = 0xA4}
    foreach ($m in $held) { $ks[$m] = 0x80; $ks[$lr[$m]] = 0x80 }
    [BeeGui.U]::SetKeyboardState($ks) | Out-Null
    $down = 0x100; $up = 0x101
    if ($mods -band 4) { $down = 0x104; $up = 0x105 }
    foreach ($m in $held) { Post $down $m (KeyLp $m $false) }
    Post $down $vk (KeyLp $vk $false)
    Start-Sleep -Milliseconds 80
    Post $up $vk (KeyLp $vk $true)
    foreach ($m in $held) { Post $up $m (KeyLp $m $true) }
    Start-Sleep -Milliseconds 80
    [BeeGui.U]::SetKeyboardState((New-Object byte[] 256)) | Out-Null
    [BeeGui.U]::AttachThreadInput($me, $them, $false) | Out-Null
}
$i = 0
while ($i -lt $args.Count) {
    $w = -split $args[$i]; $i++
    switch ($w[0]) {
        'start' {
            $a = @(); if ($w.Count -gt 1) { $a = $w[1..($w.Count - 1)] }
            if ($a.Count) { $script:proc = Start-Process -FilePath .\beemodel.exe -ArgumentList $a -PassThru }
            else { $script:proc = Start-Process -FilePath .\beemodel.exe -PassThru }
            for ($t = 0; $t -lt 100 -and (Win) -eq [IntPtr]::Zero; $t++) { Start-Sleep -Milliseconds 200 }
            if ((Win) -eq [IntPtr]::Zero) { 'no BeeModel window'; exit 1 }
            Start-Sleep -Milliseconds 1500
            'started'
        }
        'wait' { Start-Sleep -Milliseconds ([int]$w[1]) }
        'move' { Post 0x200 0 (XY $w[1] $w[2]); Start-Sleep -Milliseconds 50 }
        'click' { Mouse 0x201 0x202 1 $w[1] $w[2] }
        'rclick' { Mouse 0x204 0x205 2 $w[1] $w[2] }
        'mclick' { Mouse 0x207 0x208 16 $w[1] $w[2] }
        'dclick' { Mouse 0x201 0x202 1 $w[1] $w[2]; Mouse 0x201 0x202 1 $w[1] $w[2] }
        'drag' {
            $x0 = [int]$w[1]; $y0 = [int]$w[2]; $x1 = [int]$w[3]; $y1 = [int]$w[4]
            Post 0x200 0 (XY $x0 $y0); Post 0x201 1 (XY $x0 $y0)
            for ($s = 1; $s -le 8; $s++) {
                Start-Sleep -Milliseconds 40
                Post 0x200 1 (XY ($x0 + ($x1 - $x0) * $s / 8) ($y0 + ($y1 - $y0) * $s / 8))
            }
            Post 0x202 0 (XY $x1 $y1); Start-Sleep -Milliseconds 80
        }
        'wheel' { Post 0x200 0 (XY $w[1] $w[2]); Post 0x20A ((120 * [int]$w[3]) -shl 16) 0; Start-Sleep -Milliseconds 80 }
        'key' {
            $mods = 0; $vk = 0
            foreach ($p in $w[1].Split('+')) {
                switch ($p) { 'Shift' { $mods = $mods -bor 1 } 'Ctrl' { $mods = $mods -bor 2 } 'Alt' { $mods = $mods -bor 4 }
                    default { $vk = [int][System.Windows.Forms.Keys]$p } }
            }
            Press $vk $mods
        }
        'text' {
            $s = $args[$i - 1].Substring(5)
            foreach ($c in $s.ToCharArray()) {
                $v = [BeeGui.U]::VkKeyScan($c)
                Press ($v -band 0xff) (($v -shr 8) -band 7)
            }
        }
        'shot' {
            $r = New-Object int[] 4
            [BeeGui.U]::GetWindowRect((Win), $r) | Out-Null
            $bmp = New-Object System.Drawing.Bitmap ($r[2] - $r[0]), ($r[3] - $r[1])
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $dc = $g.GetHdc()
            [BeeGui.U]::PrintWindow((Win), $dc, 2) | Out-Null
            $g.ReleaseHdc($dc)
            $bmp.Save("\\host.lan\Data\bee-run\$($w[1])", [System.Drawing.Imaging.ImageFormat]::Png)
            "shot $($w[1])"
        }
        'state' {
            $r = New-Object int[] 4; $c = New-Object int[] 4
            [BeeGui.U]::GetWindowRect((Win), $r) | Out-Null
            [BeeGui.U]::GetClientRect((Win), $c) | Out-Null
            "window $($r[0]),$($r[1]) $($r[2] - $r[0])x$($r[3] - $r[1]) client $($c[2])x$($c[3]) maximized=$([BeeGui.U]::IsZoomed((Win))) minimized=$([BeeGui.U]::IsIconic((Win)))"
        }
        'clipset' { Set-Clipboard -Value $args[$i - 1].Substring(8) }
        'clipget' { "clipboard: [$(Get-Clipboard -Raw)]" }
        'show' { [BeeGui.U]::ShowWindow((Win), [int]$w[1]) | Out-Null; Start-Sleep -Milliseconds 300 }
        'quit' { if ($script:proc) { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue } }
        default { "unknown step: $($w[0])"; exit 2 }
    }
}
