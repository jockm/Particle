#!/usr/bin/env python3
"""A minimal serial terminal for the ULX3S FTDI UART (make ulx3s-term).

    python3 ulx3s_term.py PORT [BAUD]

Copies what the board sends to the screen and every key you type to the
board, without buffering or echo. Ctrl-] leaves.

Needs only the Python standard library. Standard termios on macOS stops at
230400 baud, so there the speed is set with the IOSSIOSPEED ioctl (as pyserial
does); on Linux the termios B<rate> constants cover the usual high rates.
"""

import fcntl
import os
import select
import struct
import sys
import termios
import tty

QUIT = b'\x1d'  # Ctrl-]
IOSSIOSPEED = 0x80045402  # macOS: _IOW('T', 2, speed_t)


def open_port(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    # Raw 8-N-1, no flow control, ignore modem control lines
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    if sys.platform == 'darwin':
        # Any standard rate here, then the real one with IOSSIOSPEED
        speed = termios.B9600
        termios.tcsetattr(fd, termios.TCSANOW,
                          [iflag, oflag, cflag, lflag, speed, speed, cc])
        fcntl.ioctl(fd, IOSSIOSPEED, struct.pack('I', baud))
    else:
        name = 'B%d' % baud
        if not hasattr(termios, name):
            sys.exit('[FAIL] %d baud is not supported here' % baud)
        speed = getattr(termios, name)
        termios.tcsetattr(fd, termios.TCSANOW,
                          [iflag, oflag, cflag, lflag, speed, speed, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: ulx3s_term.py PORT [BAUD]')
    path = sys.argv[1]
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 1000000
    try:
        fd = open_port(path, baud)
    except OSError as e:
        sys.exit('[FAIL] %s: %s (is another program using it?)' % (path, e))

    print('==> %s at %d baud (Ctrl-] to leave)' % (path, baud))
    stdin = sys.stdin.fileno()
    interactive = os.isatty(stdin)
    saved = termios.tcgetattr(stdin) if interactive else None
    try:
        if interactive:
            tty.setraw(stdin)
        while True:
            ready, _, _ = select.select([fd, stdin], [], [])
            if fd in ready:
                data = os.read(fd, 4096)
                if data:
                    os.write(sys.stdout.fileno(), data)
            if stdin in ready:
                data = os.read(stdin, 1024)
                if not data or QUIT in data:
                    break
                os.write(fd, data)
    finally:
        if saved is not None:
            termios.tcsetattr(stdin, termios.TCSADRAIN, saved)
        os.close(fd)
        print()


if __name__ == '__main__':
    main()
