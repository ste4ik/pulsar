#!/usr/bin/env bash
# Установка pulsar на Яндекс Станцию — повторяет installer/ из репозитория и делает автозапуск:
#   1) определяет модель по /proc/device-tree/compatible и архитектуру (armhf для
#      station-mini2/plum, aarch64 для cucumber);
#   2) заливает бинарник как pulsar.new, сверяет sha256, сохраняет старый в pulsar.prev;
#   3) атомарно заменяет boot.sh / supervise.sh / ctl.sh;
#   4) автозагрузка:
#      - прошивка сама запускает /data/quasar/rootkeeper.sh (Midi, Lite 2) — дописывает туда
#        строку-хук (бэкап + sh -n);
#      - прошивка не запускает его (Мини 2, 0.369) — дописывает вызов boot.sh в конец
#        /etc/init.d/S99quasar. Rootfs на время записи перемонтируется rw, оригинал остаётся в
#        /data/pulsar/S99quasar.orig, после записи / снова ro. После каждой загрузки сначала
#        поднимается штатная обвязка Яндекса (adbd, iptables, звук), затем boot.sh гасит квазар
#        и запускает супервизор pulsar;
#   5) запускает: ctl.sh enable гасит Яндекс (q stop) и поднимает supervise.sh;
#   6) проверяет здоровье на ~10 и ~30 секунде и предлагает откат на pulsar.prev.
#
# Использование:
#   ./pulsar-install.sh <серийник> [--bin <файл>] [--repo <путь>] [--no-start] [--no-boot] [--yes]
#
#   <серийник>   как в `adb devices` (для adb по сети — <IP>:5555)
#   --bin        свой бинарник pulsar (по умолчанию <repo>/satellite/build/<arch>/pulsar)
#   --repo       чекаут репозитория (по умолчанию каталог со скриптом)
#   --no-start   разложить файлы и автозагрузку, но не запускать и не гасить Яндекс
#   --no-boot    не трогать автозагрузку вообще
#   --yes        не задавать вопросов (откат при провале health check — молча)
#
# В /system не пишется ничего. Без rootkeeper.sh меняется только /etc/init.d/S99quasar
# (в конец дописываются комментарий и строка запуска); оригинал возвращает pulsar-remove.sh.
set -u

HOOK='[ -x /data/pulsar/boot.sh ] && /data/pulsar/boot.sh </dev/null >/dev/null 2>&1 &'
DATA=/data/pulsar
RK=/data/quasar/rootkeeper.sh
S99=/etc/init.d/S99quasar
BOOT_MARK='# pulsar-boot-hook'

die() { printf 'ошибка: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

SERIAL= BIN= REPO= DO_START=1 DO_BOOT=1 ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bin)  [ $# -ge 2 ] || die "--bin требует путь"; BIN=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || die "--repo требует путь"; REPO=$2; shift 2 ;;
    --no-start) DO_START=0; shift ;;
    --no-boot)  DO_BOOT=0; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*) die "неизвестный ключ $1 (см. --help)" ;;
    *)  [ -z "$SERIAL" ] || die "лишний аргумент: $1"; SERIAL=$1; shift ;;
  esac
done

[ -n "$SERIAL" ] || { usage; exit 1; }
command -v adb >/dev/null 2>&1 || die "adb не найден в PATH"

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$HERE}
DEPLOY=$REPO/satellite/deploy
[ -d "$DEPLOY" ] || die "нет $DEPLOY — укажи чекаут через --repo"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t pulsar) || die "не создать временный каталог"
ROOTFS_RW=0
cleanup() {
  # rootfs не должен остаться в rw, даже если скрипт упал посреди записи.
  [ "$ROOTFS_RW" = 1 ] && devq "mount -o remount,ro /" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

dev() { adb -s "$SERIAL" shell "$1" | tr -d '\r'; }
devq() { adb -s "$SERIAL" shell "$1" >/dev/null 2>&1; }
dev_has() { [ "$(dev "[ -e $1 ] && echo yes")" = yes ]; }
dev_pid() { dev "pidof $1"; }
dev_ok() { [ "$(dev "{ $1; } >/dev/null 2>&1 && echo ok")" = ok ]; }
must() { dev_ok "$1" || die "на устройстве не выполнилось: $1"; }

# Локальные пути для adb (Windows-бинарь), удалённые — как есть.
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
push() { adb -s "$SERIAL" push "$(win "$1")" "$2" >/dev/null; }
pull() { adb -s "$SERIAL" pull "$2" "$(win "$1")" >/dev/null; }

sha_local() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "нет sha256sum/shasum"
  fi
}
sha_remote() { dev "sha256sum $1 2>/dev/null" | awk 'NF {print $1; exit}'; }

device_present() {
  adb devices | tr -d '\r' | awk -v s="$SERIAL" 'NR > 1 && $1 == s && $2 == "device" { f = 1 } END { exit !f }'
}

adb start-server >/dev/null 2>&1 || true
if ! device_present; then
  case "$SERIAL" in
    *:*) say "== подключаюсь к $SERIAL"; adb connect "$SERIAL" >/dev/null 2>&1 || true; sleep 1 ;;
  esac
fi
device_present || die "устройство $SERIAL не в состоянии device (adb devices -l)"

comp=$(dev "cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n'")
case "$comp" in
  *yandex,station-mini2*) MODEL=station-mini2; ARCH=armhf ;;
  *yandex,plum*)          MODEL=plum;          ARCH=armhf ;;
  *yandex,cucumber*)      MODEL=cucumber;      ARCH=aarch64 ;;
  *) die "неизвестная модель; compatible: $(printf '%s' "$comp" | tr '\n' ' ')" ;;
esac
say "== $SERIAL: $MODEL ($ARCH), ядро $(dev 'uname -r' | head -n1)"

[ -n "$BIN" ] || BIN=$REPO/satellite/build/$ARCH/pulsar
[ -s "$BIN" ] || die "нет бинарника $BIN (собери: make -C $REPO/satellite ARCH=$ARCH binary, или укажи --bin)"

say "== $SERIAL: демон ($ARCH)"
must "mkdir -p $DATA"

want=$(sha_local "$BIN")
have=$(sha_remote "$DATA/pulsar")
if [ "$want" = "$have" ]; then
  say "бинарник уже такой же, не копирую (.prev сохранён)"
  CHANGED=0
else
  push "$BIN" "$DATA/pulsar.new" || die "adb push не удался"
  got=$(sha_remote "$DATA/pulsar.new")
  if [ "$want" != "$got" ]; then
    devq "rm -f $DATA/pulsar.new"
    die "push повреждён (sha256 не совпал), ничего не изменено"
  fi
  CHANGED=1
fi

# Скрипты: работающая оболочка дочитывает файл на ходу, поэтому подмена атомарная (новый inode).
# В Windows-чекауте git (core.autocrlf=true) они с CRLF, а busybox sh на CRLF-скрипте падает
# («: not found», «Illegal number»), поэтому перед заливкой приводим к LF.
stage=$TMP/deploy
mkdir -p "$stage"
for f in boot.sh supervise.sh ctl.sh; do
  [ -f "$DEPLOY/$f" ] || die "нет $DEPLOY/$f"
  sed 's/\r$//' "$DEPLOY/$f" > "$stage/$f"
done
sup_have=$(sha_remote "$DATA/supervise.sh")
SUP_CHANGED=1
[ "$sup_have" = "$(sha_local "$stage/supervise.sh")" ] && SUP_CHANGED=0
for f in boot.sh supervise.sh ctl.sh; do
  push "$stage/$f" "$DATA/$f.new" || die "adb push $f не удался"
done
must "cd $DATA && chmod 755 boot.sh.new supervise.sh.new ctl.sh.new && mv boot.sh.new boot.sh && mv supervise.sh.new supervise.sh && mv ctl.sh.new ctl.sh"

if [ "$CHANGED" = 1 ]; then
  must "cd $DATA && chmod 755 pulsar.new && { [ ! -f pulsar ] || cp -p pulsar pulsar.prev; } && mv pulsar.new pulsar && sync"
else
  must "sync"
fi

say "== $SERIAL: автозагрузка"
# Есть два пути: прошивка сама запускает rootkeeper.sh (rootkeeper-совместимый рут Midi/Lite 2,
# в onboot.sh строка `[ -x /data/quasar/rootkeeper.sh ] && ...`) — дописываем хук туда. Если нет
# (Мини 2, 0.369, vendor-рут по маркеру activate_adb_quasmodrom) — единственная точка, откуда
# стартует Яндекс, это /etc/init.d/S99quasar; дописываем вызов boot.sh в её конец.
if dev "grep -F /data/quasar/rootkeeper.sh /system/vendor/quasar/onboot.sh 2>/dev/null" | grep -q .; then
  BOOT_HOOK=1
else
  BOOT_HOOK=0
fi
TS=$(date +%Y%m%d%H%M%S)
rk_old=$TMP/rk.old
rk_new=$TMP/rk.new

if [ "$DO_BOOT" = 0 ]; then
  say "  пропущено (--no-boot)"
elif [ "$BOOT_HOOK" = 0 ]; then
  # onboot.sh уже выполнился: adbd, iptables, звук и сам квазар подняты. boot.sh дожидается
  # quasar_launcher2, гасит штатный стек и уходит в supervise.sh; порядок тот же, что у
  # rootkeeper-хука. Оригинал S99quasar лежит в /data/pulsar/S99quasar.orig.
  if ! dev_has "$S99"; then
    say "  $S99 не найден — автозапуск недоступен; pulsar проработает до перезагрузки"
  elif dev "grep -F pulsar-boot-hook $S99 2>/dev/null" | grep -q .; then
    say "  $S99 уже пропатчен"
    dev_has "$DATA/S99quasar.orig" || say "  внимание: нет $DATA/S99quasar.orig — remove не сможет вернуть оригинал"
  else
    s99_old=$TMP/S99quasar.old
    s99_new=$TMP/S99quasar.new
    pull "$s99_old" "$S99" || die "не удалось забрать $S99"
    cp "$s99_old" "$s99_new"
    printf '\n%s\n%s\n' "$BOOT_MARK" "$HOOK" >> "$s99_new"

    dev_ok "mount -o remount,rw /" || die "не удалось перемонтировать / в rw"
    ROOTFS_RW=1
    must "{ [ -f $DATA/S99quasar.orig ] || cp -p $S99 $DATA/S99quasar.orig; } && sync"
    push "$s99_new" "$S99.new" || die "adb push S99quasar.new не удался"
    dev_has "$S99.new" || die "$S99.new не появился на устройстве"
    if ! dev_ok "sh -n $S99.new"; then
      devq "rm -f $S99.new"
      die "$S99.new не прошёл sh -n на устройстве, не записан"
    fi
    must "chmod 755 $S99.new && mv $S99.new $S99 && sync"
    [ "$(sha_remote "$S99")" = "$(sha_local "$s99_new")" ] || die "$S99 на устройстве отличается от проверенного файла"
    dev_ok "mount -o remount,ro /" || say "  внимание: / остался в rw до перезагрузки"
    ROOTFS_RW=0
    say "  $S99 пропатчен (оригинал: $DATA/S99quasar.orig):"
    dev "diff $DATA/S99quasar.orig $S99 2>/dev/null" | sed 's/^/  /'
  fi
else
  if dev_has "$RK"; then
    pull "$rk_old" "$RK" || die "не удалось забрать $RK"
    if grep -qF '/data/pulsar/boot.sh' "$rk_old"; then
      say "  хук уже есть в $RK"
    else
      write_hook=1
    fi
  else
    printf '#!/bin/sh\n' > "$rk_old"
    write_hook=1
  fi

  if [ "${write_hook:-0}" = 1 ]; then
    awk -v hook="$HOOK" '
      !done && /^while[ \t]/ { print hook; print ""; done = 1 }
      { print }
      END { if (!done) { print ""; print hook } }
    ' "$rk_old" > "$rk_new"
    grep -vxF -- "$HOOK" "$rk_new" | grep -v '^[[:space:]]*$' > "$TMP/a"
    grep -v '^[[:space:]]*$' "$rk_old" > "$TMP/b"
    cmp -s "$TMP/a" "$TMP/b" || die "правка $RK изменила бы не только хук — не пишу"

    push "$rk_new" "$RK.new" || die "adb push rootkeeper.sh.new не удался"
    if ! dev_ok "sh -n $RK.new"; then
      devq "rm -f $RK.new"
      die "$RK.new не прошёл sh -n на устройстве, не записан"
    fi
    must "{ [ ! -f $RK ] || cp -p $RK $RK.bak-$TS; } && chmod 755 $RK.new && mv $RK.new $RK && sync"
    [ "$(sha_remote "$RK")" = "$(sha_local "$rk_new")" ] || die "$RK на устройстве отличается от проверенного файла"
    say "  $RK изменён (бэкап $RK.bak-$TS на устройстве):"
    dev "diff $RK.bak-$TS $RK 2>/dev/null" | sed 's/^/  /'
  fi
fi

if [ "$DO_START" = 0 ]; then
  say "== $SERIAL: запуск пропущен (--no-start); включить: $DATA/ctl.sh enable"
  exit 0
fi

say "== $SERIAL: запуск"
MARK="=== install-marker $$ $(date +%s)"
devq "echo '$MARK' >> /tmp/pulsar.log"
if dev_has "$DATA/enabled" && { [ -n "$(dev_pid supervise.sh)" ] || [ -n "$(dev_pid pulsar)" ]; }; then
  # Уже включено: перезапуск. Если сменился supervise.sh — перечитать его (reload), иначе достаточно
  # restart: супервизор сам поднимет новый бинарник.
  if [ "$SUP_CHANGED" = 1 ]; then ACTION=reload; else ACTION=restart; fi
  say "== $SERIAL: $ACTION"
  must "cd $DATA && ./ctl.sh $ACTION && echo done"
else
  # ctl.sh enable не гасит демон, запущенный руками (стенд без супервизора) — иначе получился бы
  # второй экземпляр и драка за порт 6053.
  if [ -n "$(dev_pid pulsar)" ] || [ -n "$(dev_pid supervise.sh)" ]; then
    say "== $SERIAL: останавливаю демон, запущенный до установки"
    must 'killall supervise.sh 2>/dev/null; killall pulsar 2>/dev/null; i=0; while [ $i -lt 10 ] && pidof pulsar >/dev/null 2>&1; do sleep 1; i=$((i+1)); done; ! pidof pulsar >/dev/null 2>&1'
  fi
  say "== $SERIAL: enable (q stop, супервизор)"
  must "cd $DATA && ./ctl.sh enable && echo done"
fi

# health check: ~10 с и ~30 с. Живой процесс, ровно один «=== start» после маркера и никаких
# «=== CRASH/exit/supervise» — бинарник, который падает и перезапускается между проверками,
# иначе выглядел бы здоровым.
health() {
  local round full log n bad=0
  for round in 1 2; do
    if [ "$round" = 1 ]; then sleep 10; else sleep 20; fi
    full=$(dev "cat /tmp/pulsar.log.1 /tmp/pulsar.log 2>/dev/null | tail -n 1500")
    log=$(dev "tail -n 600 /tmp/pulsar.log")
    if [[ $log != *"$MARK"* ]]; then
      if [[ $full == *"$MARK"* ]]; then log=$full; else log=; fi
    fi
    if [ -z "$log" ]; then
      say "health check UNKNOWN: маркера установки нет в логе (даже в .1), откат не предлагаю"
      return 1
    fi
    log=${log#*"$MARK"}
    if [[ $log != *"=== start"* ]]; then
      log="(после маркера нет «=== start»)$log"
      bad=1; break
    fi
    # Выход старого демона (`=== exit`) пишется после маркера, но до старта нового — судим только
    # по логу начиная с первого «=== start» после маркера (как installer/).
    prefix=${log%%"=== start"*}
    log=${log#"$prefix"}
    n=$(printf '%s\n' "$log" | grep -c '^=== start')
    if [ -z "$(dev_pid pulsar)" ] || [ "$n" != 1 ] \
       || [[ $log == *"=== CRASH"* ]] || [[ $log == *"=== exit"* ]] || [[ $log == *"=== supervise"* ]]; then
      bad=1; break
    fi
  done
  if [ "$bad" = 0 ]; then
    say "$SERIAL: health check ok"
    return 0
  fi
  printf '%s: health check FAILED, лог:\n' "$SERIAL" >&2
  printf '%s\n' "$log" | tail -n 15 >&2
  return 2
}

if health; then
  :
else
  rc=$?
  if [ "$rc" = 2 ] && [ "$CHANGED" = 1 ] && dev_has "$DATA/pulsar.prev"; then
    ans=y
    if [ "$ASSUME_YES" = 0 ]; then
      printf 'Откатить на предыдущий бинарник? [Y/n] '
      read -r ans || ans=y
    fi
    case "$ans" in
      n*|N*) ;;
      *) must "cd $DATA && cp -p pulsar.prev pulsar.rb && mv pulsar pulsar.bad && mv pulsar.rb pulsar && sync && ./ctl.sh restart && echo done"
         printf '%s: откатился (плохой бинарник оставлен как %s/pulsar.bad)\n' "$SERIAL" "$DATA" >&2 ;;
    esac
  fi
  exit 1
fi

say ""
dev "cd $DATA && ./ctl.sh status; ./ctl.sh log 5"
say ""
say "готово. Снять: ./pulsar-remove.sh $SERIAL"
