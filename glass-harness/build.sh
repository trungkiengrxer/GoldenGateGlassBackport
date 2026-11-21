#!/bin/zsh
# Builds the glass harness tools into glass-harness/build/ (swiftc -O, as in each file's header).
# Run: glass-harness/build.sh
set -e
here=${0:A:h}
mkdir -p $here/build
for t in classify group compare render abicompare reflect; do
    swiftc -O -o $here/build/$t $here/$t.swift
done
echo "built $here/build/{classify,group,compare,render,abicompare,reflect}"
