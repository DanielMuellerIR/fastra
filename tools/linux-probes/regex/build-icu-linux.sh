#!/bin/bash
set -euo pipefail
cd /work/icu/source
CFLAGS='-O2 -march=x86-64 -mtune=generic' CXXFLAGS='-O2 -march=x86-64 -mtune=generic' ./configure --prefix=/work/runtime --disable-tests --disable-samples > /work/configure.log 2>&1
make -j4 > /work/make.log 2>&1
make install > /work/install.log 2>&1
gcc -shared -fPIC /probe/icu.c -I/work/runtime/include -L/work/runtime/lib -licui18n -licuuc -licudata -o /work/libfastra_icu_probe.so
