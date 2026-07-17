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
[ -n "$D" ] && [ -e "$D" ] || exit 1

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
sms_tool -d "$D" at "$CMD" > "$OUT" 2>/dev/null </dev/null &
p=$!
( sleep 2; kill "$p" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
k=$!

wait "$p" 2>/dev/null
rc=$?

kill "$k" 2>/dev/null   # cancel the killer if sms_tool finished first
wait "$k" 2>/dev/null

if [ "$MODE" = "model" ]; then
	# Нужен НЕПУСТОЙ осмысленный ответ: строка помимо эха команды и OK/ERROR.
	# Настоящий MODEM даёт имя модели (FM350-GL, EC25, ...); DIAG/secondary - нет.
	MODEL=$(tr -d '\r' < "$OUT" 2>/dev/null | grep -vE '^AT|^OK$|^ERROR|^\+CME|^$' | head -1)
	rm -f "$OUT"
	[ -n "$MODEL" ] && exit 0 || exit 1
fi

rm -f "$OUT"
exit $rc   # 0 when the port answered AT, non-zero on no reply / timeout kill
