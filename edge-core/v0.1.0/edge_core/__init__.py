CORE_ABI = 1
CORE_VERSION = "0.1.0"

from .runtime import dispatch, self_test

__all__ = ["CORE_ABI", "CORE_VERSION", "dispatch", "self_test"]
