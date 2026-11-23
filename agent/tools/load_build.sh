#!/bin/bash
# Start PoB and import RetaliatoryMeasures via the real UI. Usage: load_build.sh
cd ~/pob-official; U=./ui.sh
$U start; sleep 3
c(){ $U move $1 $2; sleep 1; $U click $1 $2; sleep ${3:-2}; }
c 70 96; c 495 224; $U type "White_Elephant_Hills#4548"; c 634 224 10
c 700 243; c 420 275 3; c 433 311 25; c 433 281 8
