#!/bin/sh
# I2C EEPROM sim (iverilog). From this directory:
#   ./run.sh
# On this machine iverilog lives in docker:
#   docker run --rm --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/eeprom tangcore-iv:1 ./run.sh
set -e
RTL=../../src
iverilog -g2012 -DSIM -o tb_eeprom_24cxx.out \
    tb_eeprom_24cxx.v $RTL/peripherals/EEPROM_24CXX.sv
vvp tb_eeprom_24cxx.out
