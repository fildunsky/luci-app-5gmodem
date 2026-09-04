#!/bin/sh
#
# Bounded AT probe. Exit 0 if the given tty answers within ~2 seconds, else 1.
#
# sms_tool and gcom have NO timeout and block ~35 seconds on a silent DIAG port
# with no reply. That froze the whole info page (every metrics poll ran sms_tool
# on the pinned port) and port auto-detection whenever a wrong/DIAG port was
# selected - the only recovery was editing the config by hand. This helper caps
# the wait by running sms_tool in the background and killing it if it does not
# answer quickly. As a side effect it also rejects DIAG/NMEA ports (they never
# answer AT), so callers get a real AT port.
#
# Usage:
#   atprobe.sh /dev/ttyUSBx           -> exit 0 if the port answers "AT" (OK)
#   atprobe.sh /dev/ttyUSBx model     -> exit 0 ONLY if the port answers
#                                        AT+CGMM with a real model string.
#
# Зачем режим "model": у многопортовых модемов (Fibocom FM350 - 7 ttyUSB!) на
# голый "AT" отвечает НЕ ОДИН порт, и часть из них - вспомогательные/DIAG,
# которые НЕ отдают метрик. detect брал первый ответивший на "AT" - и на части
# прошивок это оказывался не тот порт: IP поднимался, а метрики/логи молчали
# (порт жив, но AT+CGMM/CSQ на нём пусты). Проверка модели отсекает такие:
# настоящий MODEM-порт отвечает на AT+CGMM именем модели, DIAG/NMEA - нет.

D="$1"
MODE="$2"
# ТОЛЬКО символьное устройство. Проверка была `-e` (просто существует), и это
# держало «замёрзший» баг: после ВЫНИМАНИЯ модема его узел /dev/ttyUSBx исчезает,
# но sms_tool, обратившись к мёртвому пути, СОЗДАЁТ на его месте ОБЫЧНЫЙ ФАЙЛ
# (open с O_CREAT). `-e` засчитывал этот фантом как живой порт, atprobe отвечал
# «ок», опрос считал модем на месте и ВЕЧНО отдавал устаревший снимок (23 ч и
# дальше), а самолечение «модема нет в списке» не запускалось. Настоящий AT-порт
# (ttyUSB/ttyACM/cdc-wdm/smd) - ВСЕГДА символьное устройство, поэтому `-c`
# отсекает фантом: DEVICE становится пустым, и карточка честно показывает пропажу.
[ -n "$D" ] && [ -c "$D" ] || exit 1

CMD="AT"
[ "$MODE" = "model" ] && CMD="AT+CGMM"

OUT="/tmp/.atprobe.$$"
# run sms_tool in the background; a killer terminates it after 2s if it hangs.
# 'wait' returns the instant sms_tool finishes, so a good port answers in well
# under a second while a silent one is capped at 2s.
#
# ДЕСКРИПТОРЫ ОТВЯЗЫВАЕМ ОТ ПОДОБОЛОЧКИ (>/dev/null на ней самой): иначе сторож
# наследует stdout вызывающего, осиротевший sleep держит пайп, и читатель
# (rpcd/cgi-io) ждёт EOF лишние 2 c. Замерено: 5gmodem.sh json 0.64 -> 2.03 c.
sms_tool -d "$D" at "$CMD" > "$OUT" 2>/dev/null </dev/null 8>&- 9>&- &
p=$!
# 8>&- 9>&-: вызывающие держат flock порта на fd 8 (atlock) - без закрытия
# осиротевший сторож продолжал держать порт после нашего выхода (класс бага
# описан в обёртке sms_tool 5gmodem.sh; сегодня он же был пойман в at_query).
( exec 8>&- 9>&-; sleep 2; kill "$p" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
k=$!

# НЕ голый wait: если порт повесил sms_tool в D-state (вис в драйвере tty),
# kill сторожа не берёт, и wait застревал бы навсегда - rpcd отваливается по
# 30 c, страница падает с XHR error (T99W175 05c6:9025, 17.08.2026). Ждём
# опросом с потолком ~3 c; неубиваемого бросаем сиротой - ядро дореапит.
# Дробный sleep есть не во всех busybox (стенд GL9869: «invalid number», и цикл
# стал бы busy-loop с нулевым таймаутом): проба sleep 0.0 мгновенна и валидна
# только на FANCY_SLEEP, без него шаг - целая секунда с пересчётом потолка.
if (sleep 0.0) 2>/dev/null; then ts=0.1; tmax=30; else ts=1; tmax=3; fi
i=0
while kill -0 "$p" 2>/dev/null && [ "$i" -lt "$tmax" ]; do i=$((i+1)); sleep "$ts"; done
if kill -0 "$p" 2>/dev/null; then rc=1; else wait "$p" 2>/dev/null; rc=$?; fi

kill "$k" 2>/dev/null   # cancel the killer if sms_tool finished first
wait "$k" 2>/dev/null

if [ "$MODE" = "model" ]; then
	# Нужен НЕПУСТОЙ осмысленный ответ: строка помимо эха команды и OK/ERROR.
	# Настоящий MODEM даёт имя модели (FM350-GL, EC25, ...); DIAG/secondary - нет.
	MODEL=$(tr -d '\r' 2>/dev/null < "$OUT" | grep -vE '^AT|^OK$|^ERROR|^\+CME|^$' | head -1)
	rm -f "$OUT"
	[ -n "$MODEL" ] && exit 0 || exit 1
fi

rm -f "$OUT"
exit $rc   # 0 when the port answered AT, non-zero on no reply / timeout kill
