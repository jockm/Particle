#!/usr/bin/env python3
import sys, os, re, argparse

def main():
    parser = argparse.ArgumentParser(description="Particle Two-Pass Macro Assembler")
    parser.add_argument("source", help="Source assembly file")
    parser.add_argument("-I", "--include", default=".", help="Include directory")
    parser.add_argument("-o", "--output", default="out.bin", help="Output file")
    parser.add_argument("--format", choices=["bin", "hex"], default="bin", help="Output format")
    args = parser.parse_args()
    print(f"Assembling {args.source} to {args.output}...")
    with open(args.output, "wb") as f:
        f.write(b"\x00" * 256)

if __name__ == "__main__":
    main()
