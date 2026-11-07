"""Stalled-drive test fixture, loaded through PYTHONPATH as sitecustomize.

FM_TEST_STALL_PREFIX: every stat, lstat, statvfs, access, open, scandir and
listdir of that path or below it blocks in a real kernel wait, opening the
FIFO at FM_TEST_STALL_FIFO that never gets a writer, after appending
"<pid> <path>" to FM_TEST_STALL_LOG. It does not reproduce a stalled disk's
uninterruptible I/O: SIGKILL ends this wait.
FM_TEST_STALL_ESCAPE: the first stalled process also starts a descendant in
its own session (holding every inherited pipe) and records its pid there.
FM_TEST_FAKE_MOUNT: Path.is_mount reports True for exactly that path.
"""
import os
_prefix = os.environ.get("FM_TEST_STALL_PREFIX")
_mount = os.environ.get("FM_TEST_FAKE_MOUNT")
if _prefix:
    _open = os.open
    def _stall(path):
        try:
            path = os.fsdecode(os.fspath(path))
        except TypeError:
            return
        if path != _prefix and not path.startswith(_prefix + "/"):
            return
        fd = _open(os.environ["FM_TEST_STALL_LOG"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.write(fd, ("%d %s\n" % (os.getpid(), path)).encode())
        os.close(fd)
        record = os.environ.get("FM_TEST_STALL_ESCAPE")
        if record and not os.path.exists(record):
            # A descendant in its own session keeps every inherited pipe open.
            import subprocess
            child = subprocess.Popen(["sleep", "60"], start_new_session=True)
            with open(record, "w") as stream:
                stream.write(str(child.pid))
        _open(os.environ["FM_TEST_STALL_FIFO"], os.O_RDONLY)
    class _Stalled:
        # An instance, not a function, so Python 3.9 pathlib's accessor
        # class attributes (stat = os.stat) never bind it as a method.
        def __init__(self, real):
            self.real = real
        def __call__(self, path=".", *args, **kwargs):
            _stall(path)
            return self.real(path, *args, **kwargs)
    for _name in ("stat", "lstat", "statvfs", "access", "open", "scandir", "listdir"):
        setattr(os, _name, _Stalled(getattr(os, _name)))
if _mount:
    import pathlib
    _is_mount = pathlib.Path.is_mount
    pathlib.Path.is_mount = lambda self: os.fspath(self) == _mount or _is_mount(self)
