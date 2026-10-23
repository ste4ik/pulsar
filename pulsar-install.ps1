<#
.SYNOPSIS
  Установка pulsar на Яндекс Станцию — PowerShell-версия pulsar-install.sh.
.DESCRIPTION
  Повторяет installer/ из репозитория: модель по /proc/device-tree/compatible и архитектура,
  sha256-сверка бинарника, pulsar.prev, атомарная замена boot.sh/supervise.sh/ctl.sh, автозагрузка
  (хук в /data/quasar/rootkeeper.sh либо, если прошивка его не запускает — как на Мини 2 0.369,
  вызов boot.sh, дописанный в /etc/init.d/S99quasar), ctl.sh enable (гасит Яндекс и поднимает
  супервизор), health check на ~10 и ~30 секунде с откатом на .prev.
.PARAMETER Serial
  Серийник как в `adb devices` (для adb по сети — <IP>:5555).
.PARAMETER Bin
  Свой бинарник (по умолчанию <repo>\satellite\build\<arch>\pulsar).
.PARAMETER Repo
  Чекаут репозитория (по умолчанию каталог со скриптом).
.PARAMETER NoStart
  Разложить файлы и автозагрузку, но не запускать и не гасить Яндекс.
.PARAMETER NoBoot
  Не трогать автозагрузку (rootfs и rootkeeper.sh остаются как есть).
.PARAMETER Yes
  Не задавать вопросов.
.EXAMPLE
  .\pulsar-install.ps1 192.168.1.50:5555
#>
param(
  [Parameter(Position = 0)][string]$Serial,
  [string]$Bin,
  [string]$Repo,
  [switch]$NoStart,
  [switch]$NoBoot,
  [switch]$Yes
)

$ErrorActionPreference = "Stop"
$Hook = '[ -x /data/pulsar/boot.sh ] && /data/pulsar/boot.sh </dev/null >/dev/null 2>&1 &'
$Data = "/data/pulsar"
$Rk = "/data/quasar/rootkeeper.sh"
$S99 = "/etc/init.d/S99quasar"
$BootMark = "# pulsar-boot-hook"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RootfsRw = $false

function Say([string]$Message) { Write-Host $Message }
function Die([string]$Message) { Write-Host "ошибка: $Message" -ForegroundColor Red; exit 1 }
function Usage { Get-Help $PSCommandPath -Full | Out-Host }

if (-not $Serial) { Usage; exit 1 }
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Die "adb не найден в PATH" }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Repo) { $Repo = $ScriptDir }
$Deploy = Join-Path $Repo "satellite\deploy"
if (-not (Test-Path $Deploy)) { Die "нет $Deploy — укажи чекаут через -Repo" }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("pulsar-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Tmp | Out-Null

function Invoke-Dev([string]$Command) {
  # В PS 5.1 строки adb в stderr при $ErrorActionPreference = Stop превращаются в
  # NativeCommandError, поэтому на время вызова глушим ошибки (код возврата не нужен).
  $old = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try { $out = & adb -s $Serial shell $Command 2>$null } finally { $ErrorActionPreference = $old }
  return ((@($out) | ForEach-Object { $_.ToString() }) -join "`n") -replace "`r", ""
}
function Invoke-AdbQuiet([string[]]$AdbArgs) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try { return @(& adb @AdbArgs 2>$null) } finally { $ErrorActionPreference = $old }
}
function Test-DevPath([string]$Path) { return (Invoke-Dev "[ -e $Path ] && echo yes").Trim() -eq "yes" }
function Get-DevPid([string]$Name) { return (Invoke-Dev "pidof $Name").Trim() }
function Test-DevOk([string]$Command) { return (Invoke-Dev "{ $Command ; } >/dev/null 2>&1 && echo __ok").Trim() -eq "__ok" }
function Assert-Dev([string]$Command) {
  if (-not (Test-DevOk $Command)) { Die "на устройстве не выполнилось: $Command" }
}
function Set-RootfsRw {
  if (-not (Test-DevOk "mount -o remount,rw /")) { Die "не удалось перемонтировать / в rw" }
  $script:RootfsRw = $true
}
function Set-RootfsRo {
  if ($script:RootfsRw) {
    if (-not (Test-DevOk "mount -o remount,ro /")) { Say "  внимание: / остался в rw до перезагрузки" }
    $script:RootfsRw = $false
  }
}
function Push-File([string]$Local, [string]$Remote) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try { & adb -s $Serial push $Local $Remote 2>$null | Out-Null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
  if ($code -ne 0) { Die "adb push $Local не удался" }
}
function Pull-File([string]$Remote, [string]$Local) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try { & adb -s $Serial pull $Remote $Local 2>$null | Out-Null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
  if ($code -ne 0) { Die "adb pull $Remote не удался" }
}
function Get-ShaLocal([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() }
function Get-ShaRemote([string]$Path) {
  $out = Invoke-Dev "sha256sum $Path 2>/dev/null"
  if ($out -match '([0-9a-fA-F]{64})') { return $matches[1].ToLower() }
  return ""
}
function Test-DevicePresent {
  $lines = Invoke-AdbQuiet @("devices") | Select-Object -Skip 1
  foreach ($line in @($lines)) {
    $f = ($line -replace "`r", "").Trim() -split '\s+'
    if ($f.Count -ge 2 -and $f[0] -eq $Serial -and $f[1] -eq "device") { return $true }
  }
  return $false
}

try {
  Invoke-AdbQuiet @("start-server") | Out-Null
  if (-not (Test-DevicePresent)) {
    if ($Serial -like "*:*") { Say "== подключаюсь к $Serial"; Invoke-AdbQuiet @("connect", $Serial) | Out-Null; Start-Sleep -Seconds 1 }
  }
  if (-not (Test-DevicePresent)) { Die "устройство $Serial не в состоянии device (adb devices -l)" }

  $comp = Invoke-Dev "cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n'"
  switch -Wildcard ($comp) {
    "*yandex,station-mini2*" { $Model = "station-mini2"; $Arch = "armhf"; break }
    "*yandex,plum*"          { $Model = "plum";          $Arch = "armhf"; break }
    "*yandex,cucumber*"      { $Model = "cucumber";      $Arch = "aarch64"; break }
    default { Die "неизвестная модель; compatible: $(($comp -split "`n") -join ' ')" }
  }
  Say "== $Serial`: $Model ($Arch), ядро $((Invoke-Dev 'uname -r') -split "`n" | Select-Object -First 1)"

  if (-not $Bin) { $Bin = Join-Path $Repo "satellite\build\$Arch\pulsar" }
  if (-not (Test-Path $Bin) -or (Get-Item $Bin).Length -eq 0) {
    Die "нет бинарника $Bin (собери: make -C $Repo\satellite ARCH=$Arch binary, или укажи -Bin)"
  }

  Say "== $Serial`: демон ($Arch)"
  Assert-Dev "mkdir -p $Data"

  $want = Get-ShaLocal $Bin
  $have = Get-ShaRemote "$Data/pulsar"
  if ($want -eq $have) {
    Say "бинарник уже такой же, не копирую (.prev сохранён)"
    $Changed = $false
  } else {
    Push-File $Bin "$Data/pulsar.new"
    $got = Get-ShaRemote "$Data/pulsar.new"
    if ($want -ne $got) {
      Invoke-Dev "rm -f $Data/pulsar.new" | Out-Null
      Die "push повреждён (sha256 не совпал), ничего не изменено"
    }
    $Changed = $true
  }

  # Скрипты: в Windows-чекауте git (core.autocrlf=true) они с CRLF, а busybox sh на CRLF падает —
  # перед заливкой приводим к LF.
  $Stage = Join-Path $Tmp "deploy"
  New-Item -ItemType Directory -Path $Stage | Out-Null
  foreach ($f in @("boot.sh", "supervise.sh", "ctl.sh")) {
    $src = Join-Path $Deploy $f
    if (-not (Test-Path $src)) { Die "нет $src" }
    $text = [IO.File]::ReadAllText($src) -replace "`r`n", "`n"
    [IO.File]::WriteAllText((Join-Path $Stage $f), $text, $Utf8NoBom)
  }
  $SupChanged = $true
  if ((Get-ShaRemote "$Data/supervise.sh") -eq (Get-ShaLocal (Join-Path $Stage "supervise.sh"))) { $SupChanged = $false }
  foreach ($f in @("boot.sh", "supervise.sh", "ctl.sh")) {
    Push-File (Join-Path $Stage $f) "$Data/$f.new"
  }
  Assert-Dev "cd $Data && chmod 755 boot.sh.new supervise.sh.new ctl.sh.new && mv boot.sh.new boot.sh && mv supervise.sh.new supervise.sh && mv ctl.sh.new ctl.sh"
  if ($Changed) {
    Assert-Dev "cd $Data && chmod 755 pulsar.new && { [ ! -f pulsar ] || cp -p pulsar pulsar.prev; } && mv pulsar.new pulsar && sync"
  } else {
    Assert-Dev "sync"
  }

  Say "== $Serial`: автозагрузка"
  # rootkeeper-совместимый рут (Midi/Lite 2): onboot.sh сам запускает /data/quasar/rootkeeper.sh.
  # Vendor-рут Мини 2 (0.369) его не запускает — там патчим /etc/init.d/S99quasar (rootfs rw на
  # время записи; оригинал остаётся в /data/pulsar/S99quasar.orig).
  $BootHook = (Invoke-Dev "grep -F /data/quasar/rootkeeper.sh /system/vendor/quasar/onboot.sh 2>/dev/null").Trim() -ne ""
  $Ts = Get-Date -Format "yyyyMMddHHmmss"
  if ($NoBoot) {
    Say "  пропущено (-NoBoot)"
  } elseif (-not $BootHook) {
    if (-not (Test-DevPath $S99)) {
      Say "  $S99 не найден — автозапуск недоступен; pulsar проработает до перезагрузки"
    } elseif ((Invoke-Dev "grep -F pulsar-boot-hook $S99 2>/dev/null").Trim() -ne "") {
      Say "  $S99 уже пропатчен"
      if (-not (Test-DevPath "$Data/S99quasar.orig")) { Say "  внимание: нет $Data/S99quasar.orig — remove не сможет вернуть оригинал" }
    } else {
      $S99Old = Join-Path $Tmp "S99quasar.old"
      $S99New = Join-Path $Tmp "S99quasar.new"
      Pull-File $S99 $S99Old
      $text = [IO.File]::ReadAllText($S99Old)
      if (-not $text.EndsWith("`n")) { $text += "`n" }
      $text += "`n$BootMark`n$Hook`n"
      [IO.File]::WriteAllText($S99New, $text, $Utf8NoBom)

      Set-RootfsRw
      Assert-Dev "{ [ -f $Data/S99quasar.orig ] || cp -p $S99 $Data/S99quasar.orig; } && sync"
      Push-File $S99New "$S99.new"
      if (-not (Test-DevPath "$S99.new")) { Die "$S99.new не появился на устройстве" }
      if (-not (Test-DevOk "sh -n $S99.new")) {
        Invoke-Dev "rm -f $S99.new" | Out-Null
        Die "$S99.new не прошёл sh -n на устройстве, не записан"
      }
      Assert-Dev "chmod 755 $S99.new && mv $S99.new $S99 && sync"
      if ((Get-ShaRemote $S99) -ne (Get-ShaLocal $S99New)) { Die "$S99 на устройстве отличается от проверенного файла" }
      Set-RootfsRo
      Say "  $S99 пропатчен (оригинал: $Data/S99quasar.orig):"
      (Invoke-Dev "diff $Data/S99quasar.orig $S99 2>/dev/null") -split "`n" | Where-Object { $_ } | ForEach-Object { Say "  $_" }
    }
  } else {
    $RkOld = Join-Path $Tmp "rk.old"
    $RkNew = Join-Path $Tmp "rk.new"
    $WriteHook = $false
    if (Test-DevPath $Rk) {
      Pull-File $Rk $RkOld
      if ([IO.File]::ReadAllText($RkOld).Contains("/data/pulsar/boot.sh")) {
        Say "  хук уже есть в $Rk"
      } else {
        $WriteHook = $true
      }
    } else {
      [IO.File]::WriteAllText($RkOld, "#!/bin/sh`n", $Utf8NoBom)
      $WriteHook = $true
    }

    if ($WriteHook) {
      $oldLines = @([IO.File]::ReadAllText($RkOld) -split "`n")
      $newLines = New-Object System.Collections.Generic.List[string]
      $done = $false
      foreach ($l in $oldLines) {
        if (-not $done -and $l -match '^while[ \t]') { $newLines.Add($Hook); $newLines.Add(""); $done = $true }
        $newLines.Add($l)
      }
      if (-not $done) { $newLines.Add(""); $newLines.Add($Hook) }
      $newText = ($newLines -join "`n")
      if (-not $newText.EndsWith("`n")) { $newText += "`n" }

      $oldNonBlank = @($oldLines | Where-Object { $_ -notmatch '^\s*$' })
      $newNonBlank = @($newLines | Where-Object { $_ -ne $Hook -and $_ -notmatch '^\s*$' })
      if (($oldNonBlank -join "`n") -ne ($newNonBlank -join "`n")) { Die "правка $Rk изменила бы не только хук — не пишу" }

      [IO.File]::WriteAllText($RkNew, $newText, $Utf8NoBom)
      Push-File $RkNew "$Rk.new"
      if (-not (Test-DevOk "sh -n $Rk.new")) {
        Invoke-Dev "rm -f $Rk.new" | Out-Null
        Die "$Rk.new не прошёл sh -n на устройстве, не записан"
      }
      Assert-Dev "{ [ ! -f $Rk ] || cp -p $Rk $Rk.bak-$Ts; } && chmod 755 $Rk.new && mv $Rk.new $Rk && sync"
      if ((Get-ShaRemote $Rk) -ne (Get-ShaLocal $RkNew)) { Die "$Rk на устройстве отличается от проверенного файла" }
      Say "  $Rk изменён (бэкап $Rk.bak-$Ts на устройстве):"
      (Invoke-Dev "diff $Rk.bak-$Ts $Rk 2>/dev/null") -split "`n" | Where-Object { $_ } | ForEach-Object { Say "  $_" }
    }
  }

  if ($NoStart) {
    Say "== $Serial`: запуск пропущен (-NoStart); включить: $Data/ctl.sh enable"
    return
  }

  Say "== $Serial`: запуск"
  $Mark = "=== install-marker $PID $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  Invoke-Dev "echo $Mark >> /tmp/pulsar.log" | Out-Null
  $supPid = Get-DevPid "supervise.sh"
  $devPid = Get-DevPid "pulsar"
  if ((Test-DevPath "$Data/enabled") -and ($supPid -or $devPid)) {
    if ($SupChanged) { $Action = "reload" } else { $Action = "restart" }
    Say "== $Serial`: $Action"
    Assert-Dev "cd $Data && ./ctl.sh $Action && echo done"
  } else {
    # ctl.sh enable не гасит демон, запущенный руками, — иначе два экземпляра и драка за 6053.
    if ($supPid -or $devPid) {
      Say "== $Serial`: останавливаю демон, запущенный до установки"
      Assert-Dev 'killall supervise.sh 2>/dev/null; killall pulsar 2>/dev/null; i=0; while [ $i -lt 10 ] && pidof pulsar >/dev/null 2>&1; do sleep 1; i=$((i+1)); done; ! pidof pulsar >/dev/null 2>&1'
    }
    Say "== $Serial`: enable (q stop, супервизор)"
    Assert-Dev "cd $Data && ./ctl.sh enable && echo done"
  }

  # health check: ~10 с и ~30 с; ровно один «=== start» после маркера, без CRASH/exit/supervise.
  $HealthLog = ""
  $Bad = $false
  $Unknown = $false
  for ($round = 1; $round -le 2; $round++) {
    if ($round -eq 1) { Start-Sleep -Seconds 10 } else { Start-Sleep -Seconds 20 }
    $full = Invoke-Dev "cat /tmp/pulsar.log.1 /tmp/pulsar.log 2>/dev/null | tail -n 1500"
    $log = Invoke-Dev "tail -n 600 /tmp/pulsar.log"
    $logLines = @($log -split "`n")
    $idx = [Array]::IndexOf($logLines, $Mark)
    if ($idx -lt 0) {
      $fullLines = @($full -split "`n")
      $idx = [Array]::IndexOf($fullLines, $Mark)
      if ($idx -ge 0) { $logLines = $fullLines } else { $logLines = $null }
    }
    if ($null -eq $logLines) {
      Say "health check UNKNOWN: маркера установки нет в логе (даже в .1), откат не предлагаю"
      $Unknown = $true
      break
    }
    $rest = @()
    if ($idx + 1 -le $logLines.Count - 1) { $rest = @($logLines[($idx + 1)..($logLines.Count - 1)]) }
    $start = -1
    for ($i = 0; $i -lt $rest.Count; $i++) { if ($rest[$i].StartsWith("=== start")) { $start = $i; break } }
    if ($start -lt 0) {
      $HealthLog = "(после маркера нет «=== start»)" + ($rest -join "`n")
      $Bad = $true
      break
    }
    $window = @($rest[$start..($rest.Count - 1)])
    $HealthLog = $window -join "`n"
    $n = @($window | Where-Object { $_.StartsWith("=== start") }).Count
    if (-not (Get-DevPid "pulsar") -or $n -ne 1 -or
        $HealthLog.Contains("=== CRASH") -or $HealthLog.Contains("=== exit") -or $HealthLog.Contains("=== supervise")) {
      $Bad = $true
      break
    }
  }

  if (-not $Bad -and -not $Unknown) {
    Say "$Serial`: health check ok"
  } else {
    if ($Bad) {
      Write-Host "$Serial`: health check FAILED, лог:" -ForegroundColor Red
      @($HealthLog -split "`n") | Select-Object -Last 15 | ForEach-Object { Write-Host $_ }
      if ($Changed -and (Test-DevPath "$Data/pulsar.prev")) {
        $ans = "y"
        if (-not $Yes) { $ans = Read-Host "Откатить на предыдущий бинарник? [Y/n]"; if (-not $ans) { $ans = "y" } }
        if ($ans -notmatch '^[nN]') {
          Assert-Dev "cd $Data && cp -p pulsar.prev pulsar.rb && mv pulsar pulsar.bad && mv pulsar.rb pulsar && sync && ./ctl.sh restart && echo done"
          Write-Host "$Serial`: откатился (плохой бинарник оставлен как $Data/pulsar.bad)" -ForegroundColor Red
        }
      }
    }
    exit 1
  }

  Say ""
  (Invoke-Dev "cd $Data && ./ctl.sh status; ./ctl.sh log 5") -split "`n" | ForEach-Object { Say $_ }
  Say ""
  Say "готово. Снять: .\pulsar-remove.ps1 $Serial"
}
finally {
  # rootfs не должен остаться в rw, даже если скрипт упал посреди записи.
  if ($script:RootfsRw) { Invoke-Dev "mount -o remount,ro /" | Out-Null }
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
