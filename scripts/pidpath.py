#!/usr/bin/env python3
"""Prints the real executable path of a running process (libproc), e.g. to check which copy of an app is running."""
import ctypes, sys
buf = ctypes.create_string_buffer(4096)
n = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(int(sys.argv[1] or 0), buf, 4096)
print(buf.value.decode() if n > 0 else "")
