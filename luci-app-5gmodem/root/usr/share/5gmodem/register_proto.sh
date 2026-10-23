#!/bin/sh

HANDLER=/lib/netifd/proto/fibocom.sh
STAMP=/etc/5gmodem_proto.md5

NEED=0
HAS_FIBO=0
_rp_known=$(ubus call network get_proto_handlers 2>/dev/null)
for _if in $(uci -q show network 2>/dev/null \
		| sed -n "s/^network\.\([^.]*\)\.proto='fibocom'\$/\1/p"); do
	HAS_FIBO=1
	_av=$(ubus call network.interface."$_if" status 2>/dev/null \
		| jsonfilter -e '@.available' 2>/dev/null)
	[ "$_av" = "false" ] && ! printf '%s' "$_rp_known" | grep -q '"fibocom"' && NEED=1
done

if [ -r "$HANDLER" ] && ! ubus call network get_proto_handlers 2>/dev/null \
		| grep -q '"fibocom"'; then
	if [ "$REGISTER_PROTO_FORCE" = "1" ] || [ "$HAS_FIBO" = "1" ]; then
		NEED=1
	else
		logger -t 5gmodem "register_proto: proto fibocom is not registered, but no interfaces use it - leaving the network alone (registration will happen on interface creation or after a reboot)"
	fi
fi

CUR=""
[ -r "$HANDLER" ] && CUR=$(md5sum "$HANDLER" 2>/dev/null | awk '{print $1}')
if [ "$HAS_FIBO" = 1 ] && [ -n "$CUR" ] \
   && [ "$CUR" != "$(cat "$STAMP" 2>/dev/null)" ]; then
	logger -t 5gmodem "register_proto: fibocom handler updated; dialing will pick up the new code from disk, metadata after a reboot (not restarting the network for this)"
fi

HAS_QMIRAW=0
for _if in $(uci -q show network 2>/dev/null \
		| sed -n "s/^network\.\([^.]*\)\.proto='qmiraw'\$/\1/p"); do
	HAS_QMIRAW=1
done
if [ -r /lib/netifd/proto/qmiraw.sh ] && ! ubus call network get_proto_handlers 2>/dev/null \
		| grep -q '"qmiraw"'; then
	if [ "$REGISTER_PROTO_FORCE" = "1" ] || [ "$HAS_QMIRAW" = "1" ]; then
		NEED=1
	fi
fi

if [ "$NEED" = "1" ]; then
	logger -t 5gmodem "register_proto: our proto is not registered in netifd - restarting the network (interfaces will briefly drop)"
	/etc/init.d/network restart >/dev/null 2>&1
fi

[ -n "$CUR" ] && printf '%s\n' "$CUR" > "$STAMP" 2>/dev/null
exit 0
