#!/usr/bin/env python3
import sys, os, re, argparse

def main():
    parser = argparse.ArgumentParser(description="ACT16 Systems Language Compiler")
    parser.add_argument("source")
    parser.add_argument("-o", "--output", default="out.asm")
    parser.add_argument("-D", "--define", action="append", default=[])
    args = parser.parse_args()
    print(f"Compiling {args.source} to {args.output}...")
    with open(args.output, "w") as f:
        f.write('; Compiled by act16c\n.include "lib/common.inc"\n')

if __name__ == "__main__":
    main()
