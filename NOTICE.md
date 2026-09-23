# Source attribution

This toolkit does not redistribute model weights, projectors, executables,
DLLs, or vendor credentials. Install those artifacts separately from their
upstream sources and record the selected public release and hashes in a private
install record.

The intended runtime is the PrismML llama.cpp fork. Verify the runtime release
and Windows CUDA asset before installing. The model artifact is a combined
MTP GGUF published by ProCreations; vision/projector loading is disabled:

- PrismML: https://github.com/prism-ml
- PrismML releases: https://github.com/prism-ml/llama.cpp/releases
- ProCreations MTP Bonsai model: https://huggingface.co/ProCreations/Ternary-Bonsai-2-27B-MTP
- Upstream llama.cpp: https://github.com/ggml-org/llama.cpp

The model, CUDA runtime, and llama.cpp fork remain subject to their respective
licenses and terms. This repository contains only user-authored or
user-adapted orchestration material and documentation.
