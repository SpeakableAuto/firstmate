#!/usr/bin/env python3
"""Clear an allowlisted cache using pinned, no-follow directory descriptors.

Usage: fm-disk-cache-clear.py <absolute-real-home> <cache-relative-path>
Only .npm/_cacache and Library/Developer/Xcode/DerivedData are accepted.
Every lookup and removal after opening / is relative to an opened directory;
renaming an ancestor can never redirect deletion through a replacement link.
Detected replacements fail closed. Child symlinks are unlinked, never followed.
Requires Python 3 with POSIX dir_fd, O_NOFOLLOW and fd-listdir support.
"""

import os
import stat
import sys
from contextlib import ExitStack


ALLOWED = {".npm/_cacache", "Library/Developer/Xcode/DerivedData"}


def identity(value):
    return value.st_dev, value.st_ino


def clear_cache(home, relative):
    if relative not in ALLOWED or not home.startswith("/") or home == "/":
        raise ValueError("refusing path outside the cache allowlist")
    parts = home.strip("/").split("/") + relative.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("refusing non-canonical cache path")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    chain = []

    def unchanged():
        for parent, name, opened in chain:
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISDIR(current.st_mode) or identity(current) != identity(opened):
                raise OSError("refusing replaced cache directory: " + name)

    def open_directory(stack, parent, name, expected):
        fd = os.open(name, flags, dir_fd=parent)
        stack.callback(os.close, fd)
        opened = os.fstat(fd)
        if identity(opened) != identity(expected):
            raise OSError("refusing replaced cache directory: " + name)
        return fd, opened

    def empty(fd):
        for name in os.listdir(fd):
            unchanged()
            entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISDIR(entry.st_mode):
                with ExitStack() as stack:
                    child, opened = open_directory(stack, fd, name, entry)
                    chain.append((fd, name, opened))
                    try:
                        empty(child)
                        unchanged()
                        os.rmdir(name, dir_fd=fd)
                    finally:
                        chain.pop()
            else:
                # unlinkat never follows a link, even if the entry changes here.
                os.unlink(name, dir_fd=fd)
        unchanged()

    with ExitStack() as stack:
        fd = os.open("/", flags)
        stack.callback(os.close, fd)
        for name in parts:
            unchanged()
            try:
                entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                return
            child, opened = open_directory(stack, fd, name, entry)
            chain.append((fd, name, opened))
            fd = child
        empty(fd)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError(__doc__)
        clear_cache(*sys.argv[1:])
    except (OSError, ValueError, NotImplementedError) as error:
        print("cache cleanup refused: " + str(error), file=sys.stderr)
        sys.exit(1)
