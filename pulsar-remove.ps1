<#
.SYNOPSIS
  Снятие pulsar с Яндекс Станции — PowerShell-версия pulsar-remove.sh.
.DESCRIPTION
  1) ctl.sh disable: снимает флаг enabled, гасит супервизор и демон, поднимает штатный Яндекс
     (q start) — Яндекс запускается сейчас и после каждой перезагрузки;
  2) возвращает /etc/init.d/S99quasar из /data/pulsar/S99quasar.orig, если install его патчил
     (rootfs на время записи перемонтируется rw и обратно ro);
  3) убирает из /data/quasar/rootkeeper.sh только нашу строку-хук (с бэкапом и проверкой sh -n),
     остальные строки не трогаются;
  4) спрашивает, удалить ли оставшиеся файлы /data/pulsar (api_key, state.conf, pulsar.prev,
     ключ Sendspin) и /tmp/pulsar.log*; -Purge удаляет без вопроса, -Keep не спрашивает.
  /system не затрагивается; /etc/init.d/S99quasar меняется только обратно. В Home Assistant
  устройство ESPHome останется «недоступным» — его нужно удалить руками.
.PARAMETER Serial
  Серийник как в `adb devices` (для adb по сети — <IP>:5555).
.PARAMETER Purge
  Удалить /data/pulsar и /tmp/pulsar.log* без вопроса.
.PARAMETER Keep
  Оставить файлы и не спрашивать.
.PARAMETER Yes
  Не задавать вопросов (файлы остаются).
.EXAMPLE
  .\pulsar-remove.ps1 192.168.1.50:5555
#>
param(
  [Parameter(Position = 0)][string]$Serial,
  [switch]$Purge,
  [switch]$Keep,
  [switch]$Yes
)

$ErrorActionPreference = "Stop"
$Hook = '[ -x /data/pulsar/boot.sh ] && /data/pulsar/boot.sh </dev/null >/dev/null 2>&1 &'
$Data = "/data/pulsar"
$Rk = "/data/quasar/rootkeeper.sh"
$S99 = "/etc/init.d/S99quasar"
$S99Orig = "$Data/S99quasar.orig"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RootfsRw = $false

function Say([string]$Message) { Write-Host $Message }
function Die([string]$Message) { Write-Host "ошибка: $Message" -ForegroundColor Red; exit 1 }
function Usage { Get-Help $PSCommandPath -Full | Out-Host }

if (-not $Serial) { Usage; exit 1 }
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Die "adb не найден в PATH" }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("pulsar-remove-" + [guid]::NewGuid().ToString("N"))
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
    "*yandex,station-mini2*" { $Model = "station-mini2"; break }
    "*yandex,plum*"          { $Model = "plum"; break }
    "*yandex,cucumber*"      { $Model = "cucumber"; break }
    default { $Model = "неизвестная" }
  }
  Say "== $Serial`: $Model"

  Say "== $Serial`: выключаю pulsar"
  if (Test-DevPath "$Data/ctl.sh") {
    (Invoke-Dev "cd $Data && ./ctl.sh disable") -split "`n" | ForEach-Object { Say "  $_" }
  } else {
    Assert-Dev 'killall supervise.sh 2>/dev/null; killall pulsar 2>/dev/null; i=0; while [ $i -lt 10 ] && pidof pulsar >/dev/null 2>&1; do sleep 1; i=$((i+1)); done; ! pidof pulsar >/dev/null 2>&1'
    if (Test-DevPath "/system/vendor/quasar/q") {
      Assert-Dev "/system/vendor/quasar/q start"
    } else {
      Say "  q не найден: Яндекс после перезагрузки поднимется сам"
    }
  }
  if (Get-DevPid "pulsar") { Die "pulsar всё ещё работает — посмотри $Data/ctl.sh log 100" }
  if (Get-DevPid "supervise.sh") { Die "supervise.sh всё ещё работает" }
  if (Test-DevPath "$Data/enabled") {
    Assert-Dev "rm -f $Data/enabled"
    Say "  снят $Data/enabled"
  }

  Say "== $Serial`: автозагрузка (S99quasar)"
  if (-not (Test-DevPath $S99)) {
    Say "  $S99 нет — нечего восстанавливать"
  } elseif ((Invoke-Dev "grep -F pulsar-boot-hook $S99 2>/dev/null").Trim() -eq "") {
    Say "  $S99 не пропатчен — не трогаю"
  } elseif (-not (Test-DevPath $S99Orig)) {
    Say "  внимание: $S99 пропатчен, но $S99Orig нет — верни оригинал вручную"
  } else {
    $S99Local = Join-Path $Tmp "S99quasar.orig"
    Pull-File $S99Orig $S99Local
    Set-RootfsRw
    Push-File $S99Local "$S99.new"
    if (-not (Test-DevPath "$S99.new")) { Die "$S99.new не появился на устройстве" }
    if (-not (Test-DevOk "sh -n $S99.new")) {
      Invoke-Dev "rm -f $S99.new" | Out-Null
      Die "$S99.new не прошёл sh -n на устройстве, не записан"
    }
    Assert-Dev "chmod 755 $S99.new && mv $S99.new $S99 && sync"
    if ((Get-ShaRemote $S99) -ne (Get-ShaLocal $S99Local)) { Die "$S99 на устройстве отличается от $S99Orig" }
    Set-RootfsRo
    Say "  $S99 восстановлен из $S99Orig (автозапуск снова у Яндекса)"
  }

  Say "== $Serial`: хук автозагрузки"
  $Ts = Get-Date -Format "yyyyMMddHHmmss"
  $RkOld = Join-Path $Tmp "rk.old"
  $RkNew = Join-Path $Tmp "rk.new"
  if (-not (Test-DevPath $Rk)) {
    Say "  $Rk нет — хука тоже нет"
  } elseif ((Invoke-Dev "grep -F /data/pulsar/boot.sh $Rk 2>/dev/null").Trim() -eq "") {
    Say "  хука в $Rk нет"
  } else {
    Pull-File $Rk $RkOld
    $oldLines = @([IO.File]::ReadAllText($RkOld) -split "`n")
    $newLines = @($oldLines | Where-Object { $_ -ne $Hook })
    $newText = ($newLines -join "`n")
    if (-not $newText.EndsWith("`n")) { $newText += "`n" }
    [IO.File]::WriteAllText($RkNew, $newText, $Utf8NoBom)
    if ((Get-Item $RkNew).Length -eq 0) { Die "после удаления хука $Rk стал бы пустым — не пишу" }
    # Измениться должна только строка хука.
    $a = @($newLines | Where-Object { $_ -notmatch '^\s*$' })
    $b = @($oldLines | Where-Object { $_ -ne $Hook -and $_ -notmatch '^\s*$' })
    if (($a -join "`n") -ne ($b -join "`n")) { Die "удаление хука затронуло бы другие строки — не пишу" }

    Push-File $RkNew "$Rk.new"
    if (-not (Test-DevOk "sh -n $Rk.new")) {
      Invoke-Dev "rm -f $Rk.new" | Out-Null
      Die "$Rk.new не прошёл sh -n на устройстве, не записан"
    }
    Assert-Dev "cp -p $Rk $Rk.bak-$Ts && chmod 755 $Rk.new && mv $Rk.new $Rk && sync"
    if ((Get-ShaRemote $Rk) -ne (Get-ShaLocal $RkNew)) { Die "$Rk на устройстве отличается от проверенного файла" }
    Say "  $Rk изменён (бэкап $Rk.bak-$Ts на устройстве):"
    (Invoke-Dev "diff $Rk.bak-$Ts $Rk 2>/dev/null") -split "`n" | Where-Object { $_ } | ForEach-Object { Say "  $_" }
  }

  $Delete = $false
  if ($Purge) {
    $Delete = $true
  } elseif (-not $Keep -and -not $Yes) {
    $ans = Read-Host "Удалить оставшиеся файлы pulsar ($Data`: api_key, state.conf, pulsar.prev; /tmp/pulsar.log*)? [y/N]"
    if ($ans -match '^[yY]') { $Delete = $true }
  }
  if ($Delete) {
    if (-not (Test-DevPath $Data)) { Die "$Data уже нет" }
    Assert-Dev "rm -rf $Data && rm -f /tmp/pulsar.log /tmp/pulsar.log.1 && sync"
    Say "  $Data и /tmp/pulsar.log* удалены"
  } else {
    Say "  файлы оставлены в $Data (api_key и state.conf сохранены)"
  }

  Say "== $Serial`: проверка"
  for ($i = 0; $i -lt 15; $i++) {
    if (Get-DevPid "quasar_launcher2") { break }
    Start-Sleep -Seconds 1
  }
  Say "  pulsar pid: $(Get-DevPid 'pulsar')"
  Say "  quasar pid: $(Get-DevPid 'quasar_launcher2 maind')"
  if (Test-DevPath $Rk) {
    $count = Invoke-Dev "grep -cF /data/pulsar/boot.sh $Rk 2>/dev/null"
    if ($count -match '(\d+)') { Say "  хук в rootkeeper.sh: $($matches[1])" } else { Say "  хук в rootkeeper.sh: 0" }
  }
  Say ""
  Say "Яндекс управляет колонкой снова, в том числе после перезагрузки."
  if ($Delete) {
    Say "Файлы удалены; вернуть: .\pulsar-install.ps1 $Serial (api_key будет новый — в Home Assistant устройство придётся добавить заново)"
  } else {
    Say "Файлы остались в $Data; вернуть: .\pulsar-install.ps1 $Serial"
  }
}
finally {
  if ($script:RootfsRw) { Invoke-Dev "mount -o remount,ro /" | Out-Null }
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
