#!/usr/bin/python3
# ABOUTME: Records an escaping fixture process identity without racing the Swift test executor.

import ctypes
import os
import sys
import tempfile
import time


class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def main() -> int:
    if len(sys.argv) != 2:
        return 64

    process_id = os.getpid()
    os.setsid()
    information = ProcBSDInfo()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidinfo = libproc.proc_pidinfo
    proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    proc_pidinfo.restype = ctypes.c_int
    size = proc_pidinfo(
        process_id,
        3,
        0,
        ctypes.byref(information),
        ctypes.sizeof(information),
    )
    if size != ctypes.sizeof(information) or information.pbi_pid != process_id:
        return 70

    record = (
        f"{process_id} {information.pbi_start_tvsec} "
        f"{information.pbi_start_tvusec}\n"
    ).encode("ascii")
    # Publish only a complete record, preserving create-only semantics and mode 0600.
    descriptor, pending_record = tempfile.mkstemp(
        prefix="identity-pending-", dir=os.path.dirname(os.path.abspath(sys.argv[1]))
    )
    try:
        if os.write(descriptor, record) != len(record):
            return 74
        os.fsync(descriptor)
        os.link(pending_record, sys.argv[1])
    finally:
        os.close(descriptor)
        os.unlink(pending_record)

    os.close(0)
    os.close(1)
    os.close(2)
    time.sleep(30)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
