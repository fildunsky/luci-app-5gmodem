#!/bin/sh
#
# Copyright 2023-2026 Rafał Wabik (IceG) - From eko.one.pl forum
#
# Licensed to the GNU General Public License v3.0.
#

DEBUG_FILE="/tmp/my_newsms_log"

. /usr/share/5gmodem/lib.sh 2>/dev/null

# ХРАНИЛИЩЕ ВЫБИРАЕМ ПОЛНОЙ ФОРМОЙ, А НЕ КЛЮЧОМ -s.
# sms_tool -s XX шлёт короткую AT+CPMS="XX", и FM350-GL на неё возвращает
# mem2/mem3 к заводскому SM: приём уезжает на SIM, а читаем мы память модема -
# ящик выглядит пустым при пришедшей SMS. Сторож моргалки ходит по кругу, то
# есть ломал бы приём раз за разом. Печатаем ключ, только если полную форму
# применить не удалось.
store_arg() {   # $1 - порт, $2 - хранилище
	[ -n "$2" ] || return 0
	if [ -c "$1" ]; then
		case "$(sms_cpms_state "$1" 2>/dev/null)" in
			"$2|"*) return 0 ;;
			?*) sms_apply_cpms "$1" "$2" >/dev/null 2>&1 && return 0 ;;
		esac
	fi
	printf -- '-s %s' "$2"
}

debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_FILE"
}

echo "=== START DEBUG $(date '+%Y-%m-%d %H:%M:%S') ===" > "$DEBUG_FILE"

LEDX=$(uci -q get 5gmodem.sms.smsled)
debug_log "LEDX: $LEDX"

LEDT="/sys/class/leds/$LEDX/trigger"
LEDON="/sys/class/leds/$LEDX/delay_on"
LEDOFF="/sys/class/leds/$LEDX/delay_off"

TMON=$((1 * 1000))
TMOFF=$((5 * 1000))

debug_log "LED paths: LEDT=$LEDT, LEDON=$LEDON, LEDOFF=$LEDOFF"
debug_log "Timings: TMON=$TMON, TMOFF=$TMOFF"

is_new_format() {
    local sms_count="$1"
    debug_log "Checking format for: '$sms_count'"
    
    echo "$sms_count" | grep -q "dfm[0-9]\+_[0-9]\+"
    local result=$?
    
    debug_log "Format check result: $result (0=new format, 1=old format)"
    return $result
}

handle_old_format() {
    debug_log "=== OLD FORMAT ==="
    
    DEV=$(uci -q get 5gmodem.sms.readport)
    debug_log "DEV (readport): $DEV"
    
    MEM=$(uci -q get 5gmodem.sms.storage)
    debug_log "MEM (storage): $MEM"
    
    STX=$(sms_tool $(store_arg "$DEV" "$MEM") -d $DEV status | cut -c23-27)
    debug_log "STX (raw cut): '$STX'"
    
    SMS=$(echo $STX | tr -dc '0-9')
    debug_log "SMS (current count): $SMS"
    
    SMSC=$(uci -q get 5gmodem.sms.sms_count)
    debug_log "SMSC (saved raw): '$SMSC'"
    
    SMSD=$(echo $SMSC | tr -dc '0-9')
    debug_log "SMSD (saved count): $SMSD"

    if [ "$SMS" = "$SMSD" ]; then
        debug_log "No new SMS (SMS=$SMS equals SMSD=$SMSD)"
        return 0
    fi

    if [ $SMS -gt $SMSD ]; then
        debug_log "NEW SMS DETECTED! (SMS=$SMS > SMSD=$SMSD)"
        debug_log "Activating LED..."
        echo timer > $LEDT
        echo $TMOFF > $LEDOFF
        echo $TMON > $LEDON
        debug_log "LED activated successfully"
        return 1
    fi
    
    debug_log "SMS count decreased or invalid (SMS=$SMS, SMSD=$SMSD)"
    return 0
}

handle_new_format() {
    debug_log "=== NEW FORMAT ==="
    local has_new_sms=0
    local modem_count=0
    
    if [ ! -f /etc/config/defmodems ]; then
        debug_log "ERROR: /etc/config/defmodems does not exist!"
        return 0
    fi
    
    debug_log "File /etc/config/defmodems exists"
    
    SMSC=$(uci -q get 5gmodem.sms.sms_count)
    debug_log "Full sms_count from config: '$SMSC'"
    
    debug_log "Scanning for serial modems..."
    
    while uci -q get defmodems.@defmodems[$modem_count] > /dev/null 2>&1; do
        modem_num=$((modem_count + 1))
        
        MODEMDATA=$(uci -q get defmodems.@defmodems[$modem_count].modemdata)
        debug_log "Modem #$modem_num: modemdata='$MODEMDATA'"
        
        if [ "$MODEMDATA" != "serial" ]; then
            debug_log "Modem #$modem_num: skipping (not serial)"
            modem_count=$((modem_count + 1))
            continue
        fi
        
        DEV=$(uci -q get defmodems.@defmodems[$modem_count].comm_port)
        
        if [ -z "$DEV" ]; then
            debug_log "Modem #$modem_num: ERROR - no comm_port defined"
            modem_count=$((modem_count + 1))
            continue
        fi
        
        debug_log "Modem #$modem_num: comm_port='$DEV'"
        
        MEM=$(uci -q get 5gmodem.sms.storage)
        [ -z "$MEM" ] && MEM="MS"
        debug_log "Modem #$modem_num: storage='$MEM'"
        
        debug_log "Modem #$modem_num: reading SMS count with sms_tool..."
        STX=$(sms_tool $(store_arg "$DEV" "$MEM") -d $DEV status 2>/dev/null | cut -c23-27)
        SMS=$(echo $STX | tr -dc '0-9')
        
        if [ -z "$SMS" ]; then
            debug_log "Modem #$modem_num: ERROR - failed to read SMS count (STX='$STX')"
            modem_count=$((modem_count + 1))
            continue
        fi
        
        debug_log "Modem #$modem_num: current SMS count = $SMS"
        
        SMSD=$(echo "$SMSC" | grep -o "dfm${modem_num}_[0-9]\+" | cut -d'_' -f2)
        
        [ -z "$SMSD" ] && SMSD=0
        
        debug_log "Modem #$modem_num: saved SMS count = $SMSD"
        
        if [ $SMS -gt $SMSD ]; then
            debug_log "Modem #$modem_num: NEW SMS DETECTED! ($SMS > $SMSD)"
            has_new_sms=1
            break
        else
            debug_log "Modem #$modem_num: no new SMS ($SMS <= $SMSD)"
        fi
        
        modem_count=$((modem_count + 1))
        
        sleep 3
    done
    
    debug_log "Total serial modems checked: $modem_count"
    
    if [ $has_new_sms -eq 1 ]; then
        debug_log "Activating LED for new SMS..."
        echo timer > $LEDT
        echo $TMOFF > $LEDOFF
        echo $TMON > $LEDON
        debug_log "LED activated successfully"
        return 1
    fi
    
    debug_log "No new SMS detected on any modem"
    return 0
}

SMSC=$(uci -q get 5gmodem.sms.sms_count)
debug_log "=== MAIN LOGIC ==="
debug_log "sms_count value: '$SMSC'"

if is_new_format "$SMSC"; then
    debug_log "Detected NEW FORMAT - multiple modems"
    handle_new_format
    result=$?
else
    debug_log "Detected OLD FORMAT - single modem"
    handle_old_format
    result=$?
fi

debug_log "Script finished with exit code: $result"
debug_log "=== END DEBUG ==="

exit $result
