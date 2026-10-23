#!/bin/sh

_STAMP=/etc/5gmodem/.modemdir-migrated
if [ ! -f "$_STAMP" ] && [ -d /etc/modem ]; then
	mkdir -p /etc/5gmodem/modem/atcmmds /etc/5gmodem/modem/ussdcodes 2>/dev/null
	_files=0
	for _src in /etc/modem/atcmmds.user /etc/modem/phonebook.user \
	            /etc/modem/ussdcodes.user \
	            /etc/modem/atcmmds/*.user /etc/modem/ussdcodes/*.user; do
		[ -s "$_src" ] || continue
		_dst="/etc/5gmodem/modem/${_src#/etc/modem/}"
		cmp -s "$_src" "$_dst" && continue
		cp "$_src" "$_dst" 2>/dev/null || continue
		_files=$((_files + 1))
	done
	: > "$_STAMP" 2>/dev/null
	[ "$_files" -gt 0 ] && \
		logger -t 5gmodem "lists moved from /etc/modem to /etc/5gmodem/modem: $_files files"
fi

[ -f /etc/config/sms_tool_js ] || exit 0
uci -q get 5gmodem.sms >/dev/null 2>&1 || uci -q set 5gmodem.sms=sms

_moved=0
for _k in storage mergesms pnumber prefix lednotify ussd ussd_3g pdu sendingroup delay \
          information readport sendport ussdport atport callport \
          calllog_enabled sms_via_mm ussd_via_mm coding algorithm direction \
          checktime prestart ledtype ontopsms smsled sms_count sms_count_index \
          forward_sms_enabled forward_sms_mail_smtp forward_sms_mail_smtp_port \
          forward_sms_mail_user forward_sms_mail_password forward_sms_mail_sender \
          forward_sms_mail_recipient forward_sms_mail_security; do
	[ -n "$(uci -q get "5gmodem.sms.$_k")" ] && continue
	_v=$(uci -q get "sms_tool_js.@sms_tool_js[0].$_k")
	[ -n "$_v" ] || continue
	uci -q set "5gmodem.sms.$_k=$_v"
	_moved=$((_moved + 1))
done

if [ "$_moved" -gt 0 ]; then
	uci -q commit 5gmodem
	logger -t 5gmodem "SMS settings migrated to 5gmodem.sms: $_moved values"
fi

exit 0
