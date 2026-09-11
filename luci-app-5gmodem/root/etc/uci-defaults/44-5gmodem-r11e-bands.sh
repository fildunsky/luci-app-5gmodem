#!/bin/sh
#
# ЧУЖИЕ СОХРАНЁННЫЕ ДИАПАЗОНЫ У MikroTik R11e-LTE (2cd2:0001).
#
# До 2.4.65 при замене модема в том же USB-разъёме новому доставался выбор
# диапазонов прежнего (save_band*). Профиля диапазонов у R11e-LTE до этой версии
# не было вовсе, значит сохранённый набор в его секции заведомо не его. Теперь
# профиль есть, и прото дозвона записал бы этот набор в модем перед подключением
# (живой отчёт 11.09.2026: «1 3 7 8 38» от прежнего модема - без B20).
# Один раз, по метке: при обновлении пакета скрипт запускается снова, а выбор,
# сделанный уже для самой R11e-LTE, стирать нельзя.
[ "$(uci -q get 5gmodem.@5gmodem[0].r11e_bands_migrated)" = "1" ] && exit 0
for _s in $(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[A-Za-z0-9_]*\)\.vidpid='2cd2:0001'\$/\1/p"); do
	for _o in save_band save_band5gnsa save_band5gsa band_full; do
		uci -q delete "5gmodem.$_s.$_o" 2>/dev/null
	done
done
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 && uci -q set 5gmodem.@5gmodem[0].r11e_bands_migrated=1
uci -q commit 5gmodem
exit 0
