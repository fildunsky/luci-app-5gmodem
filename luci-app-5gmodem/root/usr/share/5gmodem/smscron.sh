#!/bin/sh
#
# РАСПИСАНИЕ ПЕРЕЗАПУСКА УВЕДОМИТЕЛЯ SMS.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ СКРИПТ. Это единственное, ради чего приложению был нужен
# `write` на /etc/crontabs/root - а такое право означает исполнение ЛЮБЫХ команд
# от root по расписанию. Страница читала файл целиком, фильтровала строки и
# записывала обратно; то есть из браузера можно было положить в crontab что
# угодно, и проверить это было нечем (фильтр жил бы в странице, а страница
# выполняется у пользователя).
#
# Здесь право сужено до одного действия: включить/выключить НАШУ строку с
# заданным интервалом. Ни одной чужой строки скрипт не касается, интервал
# проверяется. Та же модель, что в setopt.sh и atcmd.sh: узкий глагол вместо
# общего исполнителя.
#
# ЗАЧЕМ ВООБЩЕ CRON. Уведомитель (5gmodem-sms-notify) со временем перестаёт
# замечать новые сообщения - процесс переживает переподключения модема хуже, чем
# хотелось бы, и лечится перезапуском. Пользователь выбирает период в настройках
# («перезапускать процесс проверки входящих каждые N часов»).
#
# Usage: smscron.sh on <часы> | off | status

CRON=/etc/crontabs/root
MARK=5gmodem-sms-notify
RES=/usr/share/5gmodem

# Только наши строки. Чужие не трогаем НИКОГДА: в crontab у человека может быть
# что угодно, и потерять это из-за нашей настройки - недопустимо.
_strip_ours() {
	[ -f "$CRON" ] || { : > "$CRON"; return; }
	grep -v "$MARK" "$CRON" 2>/dev/null | grep -v '^[[:space:]]*$' > "$CRON.tmp" 2>/dev/null
	mv "$CRON.tmp" "$CRON" 2>/dev/null
}

case "$1" in
on)
	H="$2"
	# Интервал приходит со страницы и уходит В CRONTAB. Пропускаем только целое
	# число часов в разумных пределах: «*/0» cron не поймёт, а «*/999» бессмысленно.
	case "$H" in
		''|*[!0-9]*) echo '{"error":"bad interval"}'; exit 2 ;;
	esac
	[ "$H" -ge 1 ] && [ "$H" -le 24 ] || { echo '{"error":"interval out of range"}'; exit 2; }

	_strip_ours
	printf '1 */%s * * * /etc/init.d/%s enable && /etc/init.d/%s restart\n' \
		"$H" "$MARK" "$MARK" >> "$CRON"
	/etc/init.d/cron restart >/dev/null 2>&1
	/etc/init.d/"$MARK" enable >/dev/null 2>&1
	/etc/init.d/"$MARK" start >/dev/null 2>&1
	logger -t 5gmodem "smscron: SMS notifier restart scheduled every ${H}h"
	echo '{"result":"ok","every":'"$H"'}'
	;;
off)
	_strip_ours
	/etc/init.d/cron restart >/dev/null 2>&1
	/etc/init.d/"$MARK" stop >/dev/null 2>&1
	/etc/init.d/"$MARK" disable >/dev/null 2>&1
	logger -t 5gmodem "smscron: SMS notifier schedule removed"
	echo '{"result":"ok"}'
	;;
status)
	# Отдаём ТОЛЬКО свою строку: содержимое чужого crontab наружу не выносим -
	# в нём могут быть пути, имена и что угодно ещё, к нам не относящееся.
	_ours=$(grep "$MARK" "$CRON" 2>/dev/null | head -1)
	_every=$(printf '%s' "$_ours" | sed -n 's|^1 \*/\([0-9]*\) .*|\1|p')
	printf '{"enabled":%s,"every":"%s"}\n' \
		"$([ -n "$_ours" ] && echo 1 || echo 0)" "$_every"
	;;
*)
	echo '{"error":"usage: on <hours> | off | status"}'
	exit 2 ;;
esac
exit 0
