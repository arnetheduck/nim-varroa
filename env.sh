#!/bin/sh

export PATH=$PWD/vendor/Nim/bin:$PATH

[ $# -eq 0 ] || "$@"
