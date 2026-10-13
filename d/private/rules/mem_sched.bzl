"""Per-target memory estimates for local D compiles, so Bazel's local scheduler runs compiles in
parallel only while their estimated peaks fit in --local_resources=memory.

MEM_MIB (mem_estimates.bzl, generated from measured peaks) maps "package:name" to MiB. Bazel takes the
estimate from a resource_set callback that must be a top-level function and only sees the OS and the
input count, so each estimate is rounded up to one of the bucket callbacks below.
"""

load("//d/private/rules:mem_estimates.bzl", "DEFAULT_MIB", "MEM_MIB")

def _gib1(_os, _inputs):
    return {"cpu": 1, "memory": 1024}

def _gib2(_os, _inputs):
    return {"cpu": 1, "memory": 2048}

def _gib3(_os, _inputs):
    return {"cpu": 1, "memory": 3072}

def _gib4(_os, _inputs):
    return {"cpu": 1, "memory": 4096}

def _gib6(_os, _inputs):
    return {"cpu": 1, "memory": 6144}

def _gib8(_os, _inputs):
    return {"cpu": 1, "memory": 8192}

def _gib10(_os, _inputs):
    return {"cpu": 1, "memory": 10240}

def _gib12(_os, _inputs):
    return {"cpu": 1, "memory": 12288}

def _gib14(_os, _inputs):
    return {"cpu": 1, "memory": 14336}

def _gib16(_os, _inputs):
    return {"cpu": 1, "memory": 16384}

def _gib18(_os, _inputs):
    return {"cpu": 1, "memory": 18432}

def _gib20(_os, _inputs):
    return {"cpu": 1, "memory": 20480}

def _gib22(_os, _inputs):
    return {"cpu": 1, "memory": 22528}

def _gib24(_os, _inputs):
    return {"cpu": 1, "memory": 24576}

def _gib28(_os, _inputs):
    return {"cpu": 1, "memory": 28672}

_BUCKETS = [
    (1024, _gib1),
    (2048, _gib2),
    (3072, _gib3),
    (4096, _gib4),
    (6144, _gib6),
    (8192, _gib8),
    (10240, _gib10),
    (12288, _gib12),
    (14336, _gib14),
    (16384, _gib16),
    (18432, _gib18),
    (20480, _gib20),
    (22528, _gib22),
    (24576, _gib24),
    (28672, _gib28),
]

def d_compile_resource_set(label):
    """The resource_set callback for the compile of `label`; the largest bucket caps it."""
    mib = MEM_MIB.get("%s:%s" % (label.package, label.name), DEFAULT_MIB)
    for limit, callback in _BUCKETS:
        if mib <= limit:
            return callback
    return _BUCKETS[-1][1]
