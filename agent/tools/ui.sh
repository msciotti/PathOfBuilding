#!/bin/bash
# ui.sh start|shot [file]|click X Y|rclick X Y|move X Y|type TEXT|key KEY|stop
export DISPLAY=:99 WINEPREFIX=$HOME/pob-official/prefix WINEDEBUG=-all
case $1 in
start) pgrep Xvfb >/dev/null || (Xvfb :99 -screen 0 1440x900x24 >/dev/null 2>&1 &); sleep 2
  cd ~/pob-official; nohup wine "Path of Building.exe" >~/tmp/pobwine.log 2>&1 & sleep 40;;
shot) ffmpeg -loglevel error -y -f x11grab -video_size 1440x900 -i :99 -frames:v 1 ${2:-$HOME/tmp/shot.png};;
click) xdotool mousemove $2 $3 click 1;;
rclick) xdotool mousemove $2 $3 click 3;;
move) xdotool mousemove $2 $3;;
type) xdotool type --delay 20 "$2";;
key) xdotool key "$2";;
stop) wineserver -k;;
esac
