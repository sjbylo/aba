#!/usr/bin/env python3
"""pty-run.py — Run a command in a real PTY, capture output to a file.

Usage: pty-run.py [--input-fifo <path>] <output-file> <command> [args...]

The child sees a real terminal (isatty=true, colors, read, spinners all work).
All PTY output is captured to <output-file>.
If --input-fifo is given, data written to that FIFO is forwarded to the PTY
as keyboard input (so the child's read/ask works).
Exits with the child's exit code.
"""

import os
import pty
import fcntl
import select
import struct
import sys
import termios
import time


def main():
    # Parse arguments
    input_fifo = None
    args = sys.argv[1:]

    if len(args) >= 3 and args[0] == "--input-fifo":
        input_fifo = args[1]
        args = args[2:]

    if len(args) < 2:
        print("Usage: {} [--input-fifo <path>] <output-file> <command> [args...]".format(
            sys.argv[0]), file=sys.stderr)
        sys.exit(1)

    output_file = args[0]
    cmd = args[1:]

    pid, master_fd = pty.fork()

    if pid == 0:
        # Child: exec the command — it has a real PTY
        if os.environ.get("TERM", "dumb") == "dumb":
            os.environ["TERM"] = "xterm-256color"
        os.execvp(cmd[0], cmd)
        os._exit(127)

    # Set PTY window size so programs like oc-mirror can size their progress bars.
    try:
        if os.isatty(sys.stdout.fileno()):
            winsize = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b'\x00' * 8)
        else:
            rows, cols = 24, 80
            winsize = struct.pack('HHHH', rows, cols, 0, 0)
    except (OSError, ValueError):
        rows, cols = 24, 80
        winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)

    # Open input FIFO if provided.
    # O_RDWR keeps the fd alive even when no writer has it open (avoids spurious EOF).
    input_fd = -1
    if input_fifo:
        try:
            input_fd = os.open(input_fifo, os.O_RDWR | os.O_NONBLOCK)
        except OSError:
            input_fd = -1

    # Parent: relay PTY output to file, forward input FIFO to PTY
    child_exited = False
    child_status = 0

    with open(output_file, "ab") as out:
        while True:
            read_fds = [master_fd]
            if input_fd >= 0:
                read_fds.append(input_fd)

            try:
                rlist, _, _ = select.select(read_fds, [], [], 0.1)
            except (ValueError, OSError):
                break

            # Forward input FIFO → PTY master (keyboard input for the child)
            if input_fd >= 0 and input_fd in rlist:
                try:
                    data = os.read(input_fd, 4096)
                    if data:
                        os.write(master_fd, data)
                except OSError:
                    pass

            # Read PTY master → output file
            if master_fd in rlist:
                try:
                    data = os.read(master_fd, 8192)
                except OSError:
                    break
                if not data:
                    break
                out.write(data)
                out.flush()

            if not child_exited:
                try:
                    wpid, st = os.waitpid(pid, os.WNOHANG)
                    if wpid != 0:
                        child_exited = True
                        child_status = st
                        # Drain remaining output
                        deadline = time.time() + 1.0
                        while time.time() < deadline:
                            r, _, _ = select.select([master_fd], [], [], 0.05)
                            if not r:
                                break
                            try:
                                data = os.read(master_fd, 8192)
                            except OSError:
                                break
                            if not data:
                                break
                            out.write(data)
                            out.flush()
                        break
                except ChildProcessError:
                    break

    if input_fd >= 0:
        try:
            os.close(input_fd)
        except OSError:
            pass

    try:
        os.close(master_fd)
    except OSError:
        pass

    if not child_exited:
        _, child_status = os.waitpid(pid, 0)

    rc = os.WEXITSTATUS(child_status) if os.WIFEXITED(child_status) else 1
    sys.exit(rc)

if __name__ == "__main__":
    main()
