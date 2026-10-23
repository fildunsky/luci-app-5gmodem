#!/bin/sh
ESIM_CAPABLE_VIDPIDS="0e8d:7127 0e8d:7126 2cb7:0104 2cb7:0105 2c7c:0800 2c7c:0801 2c7c:0900 05c6:9025 05c6:90d5 1e2d:00b3 1e2d:00b7 1e2d:00b8 1e2d:00b9 0489:e0f0 1e2d:00f1 1e2d:00f2 1e2d:00f3 1e2d:00f4 413c:81e0 413c:81e4 0489:e0b5 105b:e0f5 105b:e11d"

esim_capable() {
	for _ecap in $ESIM_CAPABLE_VIDPIDS; do
		[ "$1" = "$_ecap" ] && return 0
	done
	case "$2" in
		*eSIM*|*ESIM*|*esim*) return 0 ;;
	esac
	return 1
}
