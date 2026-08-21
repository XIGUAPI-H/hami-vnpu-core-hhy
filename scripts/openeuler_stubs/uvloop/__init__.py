# Minimal uvloop stub for Python 3.10 (openEuler mindspeed env).
# vllm api_server only needs uvloop.run().
from __future__ import annotations

import asyncio


def install() -> None:
    return None


def run(main):
    return asyncio.run(main())
