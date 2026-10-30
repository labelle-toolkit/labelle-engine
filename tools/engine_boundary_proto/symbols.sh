#!/bin/bash
# usage: symbols.sh <archive.a> <out.tsv>  -- defined function sizes (bytes) per symbol
NM=C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0/upstream/bin/llvm-nm.exe
$NM -S "$1" 2>/dev/null | awk '$3 ~ /^[Tt]$/ {sz=strtonum("0x"$2); n=$4; for(i=5;i<=NF;i++) n=n" "$i; print sz"\t"n}' > "$2"
wc -l < "$2"
