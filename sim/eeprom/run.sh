#!/bin/sh
# I2C EEPROM sim (iverilog). From this directory:
#   ./run.sh
# On this machine iverilog lives in docker, e.g.:
#   simrun --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/eeprom tangcore-iv:1 ./run.sh
# (simrun is an optional local helper; plain `docker run --rm` works too.)
set -e
RTL=../../src
iverilog -g2012 -DSIM -o tb_eeprom_24cxx.out \
    tb_eeprom_24cxx.v $RTL/peripherals/EEPROM_24CXX.sv
vvp tb_eeprom_24cxx.out
