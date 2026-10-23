#!/usr/bin/env bash
# Снятие pulsar с Яндекс Станции — обратная операция к pulsar-install.sh:
#   1) ctl.sh disable: снимает флаг enabled, гасит супервизор и демон, поднимает штатный Яндекс
#      (q start) — Яндекс запускается сейчас и после каждой перезагрузки;
#   2) возвращает /etc/init.d/S99quasar из /data/pulsar/S99quasar.orig, если install его патчил
#      (rootfs на время записи перемонтируется rw и обратно ro);
#   3) убирает из /data/quasar/rootkeeper.sh только нашу строку-хук (с бэкапом и проверкой sh -n),
#      остальные строки не трогаются;
#   4) спрашивает, удалить ли оставшиеся файлы /data/pulsar (api_key, state.conf, pulsar.prev,
#      ключ Sendspin) и логи в /tmp. --purge удаляет без вопроса, --keep не спрашивает.
#
# Использование:
#   ./pulsar-remove.sh <серийник> [--purge | --keep] [--yes]
#
#   --purge  удалить /data/pulsar и /tmp/pulsar.log* без вопроса
#   --keep   оставить файлы и не спрашивать
#   --yes    не задавать вопросов (файлы остаются)
#
# /system не затрагивается; /etc/init.d/S99quasar меняется только обратно, если install его
# патчил. /data/quasar/activate_* не трогаются. В Home Assistant устройство ESPHome останется
# «недоступным» — его нужно удалить руками (Настройки → Устройства и службы → ESPHome).
set -u

HOOK='[ -x /data/pulsar/boot.sh ] && /data/pulsar/boot.sh </dev/null >/dev/null 2>&1 &'
DATA=/data/pulsar
RK=/data/quasar/rootkeeper.sh
S99=/etc/init.d/S99quasar
S99_ORIG=$DATA/S99quasar.orig

die() { printf 'ошибка: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

SERIAL= PURGE=0 KEEP=0 ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)    PURGE=1; shift ;;
    --keep)     KEEP=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*) die "неизвестный ключ $1 (см. --help)" ;;
    *)  [ -z "$SERIAL" ] || die "лишний аргумент: $1"; SERIAL=$1; shift ;;
  esac
done

[ -n "$SERIAL" ] || { usage; exit 1; }
command -v adb >/dev/null 2>&1 || die "adb не найден в PATH"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t pulsar) || die "не создать временный каталог"
ROOTFS_RW=0
cleanup() {
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
  *yandex,station-mini2*) MODEL=station-mini2 ;;
  *yandex,plum*)          MODEL=plum ;;
  *yandex,cucumber*)      MODEL=cucumber ;;
  *) MODEL=неизвестная ;;
esac
say "== $SERIAL: $MODEL"

say "== $SERIAL: выключаю pulsar"
if dev_has "$DATA/ctl.sh"; then
  dev "cd $DATA && ./ctl.sh disable" | sed 's/^/  /'
else
  must 'killall supervise.sh 2>/dev/null; killall pulsar 2>/dev/null; i=0; while [ $i -lt 10 ] && pidof pulsar >/dev/null 2>&1; do sleep 1; i=$((i+1)); done; ! pidof pulsar >/dev/null 2>&1'

  if dev_has /system/vendor/quasar/q; then
    must '/system/vendor/quasar/q start'
  else
    say "  q не найден: Яндекс после перезагрузки поднимется сам"
  fi
fi
[ -z "$(dev_pid pulsar)" ] || die "pulsar всё ещё работает — посмотри $DATA/ctl.sh log 100"
[ -z "$(dev_pid supervise.sh)" ] || die "supervise.sh всё ещё работает"
if dev_has "$DATA/enabled"; then
  must "rm -f $DATA/enabled"
  say "  снят $DATA/enabled"
fi

say "== $SERIAL: автозагрузка (S99quasar)"
if ! dev_has "$S99"; then
  say "  $S99 нет — нечего восстанавливать"
elif ! dev "grep -F pulsar-boot-hook $S99 2>/dev/null" | grep -q .; then
  say "  $S99 не пропатчен — не трогаю"
elif ! dev_has "$S99_ORIG"; then
  say "  внимание: $S99 пропатчен, но $S99_ORIG нет — верни оригинал вручную"
else
  s99_orig=$TMP/S99quasar.orig
  pull "$s99_orig" "$S99_ORIG" || die "не удалось забрать $S99_ORIG"
  dev_ok "mount -o remount,rw /" || die "не удалось перемонтировать / в rw"
  ROOTFS_RW=1
  push "$s99_orig" "$S99.new" || die "adb push S99quasar.new не удался"
  dev_has "$S99.new" || die "$S99.new не появился на устройстве"
  if ! dev_ok "sh -n $S99.new"; then
    devq "rm -f $S99.new"
    die "$S99.new не прошёл sh -n на устройстве, не записан"
  fi
  must "chmod 755 $S99.new && mv $S99.new $S99 && sync"
  [ "$(sha_remote "$S99")" = "$(sha_local "$s99_orig")" ] || die "$S99 на устройстве отличается от $S99_ORIG"
  dev_ok "mount -o remount,ro /" || say "  внимание: / остался в rw до перезагрузки"
  ROOTFS_RW=0
  say "  $S99 восстановлен из $S99_ORIG (автозапуск снова у Яндекса)"
fi

say "== $SERIAL: хук автозагрузки"
TS=$(date +%Y%m%d%H%M%S)
rk_old=$TMP/rk.old
rk_new=$TMP/rk.new
if ! dev_has "$RK"; then
  say "  $RK нет — хука тоже нет"
elif ! dev "grep -F /data/pulsar/boot.sh $RK 2>/dev/null" | grep -q .; then
  say "  хука в $RK нет"
else
  pull "$rk_old" "$RK" || die "не удалось забрать $RK"
  grep -vxF -- "$HOOK" "$rk_old" > "$rk_new"
  [ -s "$rk_new" ] || die "после удаления хука $RK стал бы пустым — не пишу"
  # Измениться должна только строка хука.
  grep -v '^[[:space:]]*$' "$rk_new" > "$TMP/a"
  grep -vxF -- "$HOOK" "$rk_old" | grep -v '^[[:space:]]*$' > "$TMP/b"
  cmp -s "$TMP/a" "$TMP/b" || die "удаление хука затронуло бы другие строки — не пишу"

  push "$rk_new" "$RK.new" || die "adb push rootkeeper.sh.new не удался"
  if ! dev_ok "sh -n $RK.new"; then
    devq "rm -f $RK.new"
    die "$RK.new не прошёл sh -n на устройстве, не записан"
  fi
  must "cp -p $RK $RK.bak-$TS && chmod 755 $RK.new && mv $RK.new $RK && sync"
  [ "$(sha_remote "$RK")" = "$(sha_local "$rk_new")" ] || die "$RK на устройстве отличается от проверенного файла"
  say "  $RK изменён (бэкап $RK.bak-$TS на устройстве):"
  dev "diff $RK.bak-$TS $RK 2>/dev/null" | sed 's/^/  /'
fi

DELETE=0
if [ "$PURGE" = 1 ]; then
  DELETE=1
elif [ "$KEEP" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
  printf 'Удалить оставшиеся файлы pulsar (%s: api_key, state.conf, pulsar.prev; /tmp/pulsar.log*)? [y/N] ' "$DATA"
  read -r ans || ans=n
  case "$ans" in y*|Y*) DELETE=1 ;; esac
fi

if [ "$DELETE" = 1 ]; then
  dev_has "$DATA" || die "$DATA уже нет"
  must "rm -rf $DATA && rm -f /tmp/pulsar.log /tmp/pulsar.log.1 && sync"
  say "  $DATA и /tmp/pulsar.log* удалены"
else
  say "  файлы оставлены в $DATA (api_key и state.conf сохранены)"
fi

say "== $SERIAL: проверка"
i=0
while [ $i -lt 15 ] && [ -z "$(dev_pid quasar_launcher2)" ]; do sleep 1; i=$((i+1)); done
say "  pulsar pid: $(dev_pid pulsar)"
say "  quasar pid: $(dev_pid quasar_launcher2 maind)"
if dev_has "$RK"; then
  say "  хук в rootkeeper.sh: $(dev "grep -cF /data/pulsar/boot.sh $RK 2>/dev/null" | tr -dc '0-9')"
fi
say ""
say "Яндекс управляет колонкой снова, в том числе после перезагрузки."
if [ "$DELETE" = 1 ]; then
  say "Файлы удалены; вернуть: ./pulsar-install.sh $SERIAL (api_key будет новый — в Home Assistant устройство придётся добавить заново)"
else
  say "Файлы остались в $DATA; вернуть: ./pulsar-install.sh $SERIAL"
fi
