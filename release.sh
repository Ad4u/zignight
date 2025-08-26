#!/bin/bash

rm -Rf .zig-cache
rm -Rf zig-out

targets=("x86_64-windows" "x86_64-linux-gnu" "x86_64-linux-musl" "aarch64-macos")

for target in ${targets[@]}; do
  zig build -Doptimize=ReleaseFast -Dtarget=$target
  mv zig-out/bin/zignight zig-out/bin/zignight-$target
  mv zig-out/bin/zignight.exe zig-out/bin/zignight-$target.exe
done

rm zig-out/bin/zignight.pdb
