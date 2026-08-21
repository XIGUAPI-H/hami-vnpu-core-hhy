import inspect
import vllm_ascend.platform as p
print("=== NPUPlatform.mem_get_info ===")
print(inspect.getsource(p.NPUPlatform.mem_get_info))
print("=== NPUPlatform.clear_npu_memory ===")
print(inspect.getsource(p.NPUPlatform.clear_npu_memory))
print("=== NPUPlatform.empty_cache ===")
try:
    print(inspect.getsource(p.NPUPlatform.empty_cache))
except Exception as e:
    print("no empty_cache:", e)

import torch_npu
print("=== torch_npu.npu.mem_get_info ===")
try:
    print(inspect.getsource(torch_npu.npu.mem_get_info))
except Exception as e:
    print("not python:", e, "module:", torch_npu.npu.mem_get_info.__module__)
print("=== torch_npu.npu.memory_stats ===")
try:
    print(inspect.getsource(torch_npu.npu.memory_stats))
except Exception as e:
    print("not python:", e)
