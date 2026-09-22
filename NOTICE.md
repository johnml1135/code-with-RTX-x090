# Source attribution

This toolkit does not redistribute model weights, projectors, executables, DLLs,
or vendor credentials. Install those artifacts separately from their official
sources and record the selected public release and hashes in a private install
record.

The intended runtime is the PrismML llama.cpp fork. The deployment pin used by
the companion lab was prism-b10709-9a9394a; verify the current official release
and Windows CUDA asset before installing:

- PrismML: https://github.com/prism-ml
- PrismML releases: https://github.com/prism-ml/llama.cpp/releases
- Bonsai model repository: https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf
- Upstream llama.cpp: https://github.com/ggml-org/llama.cpp

The model, projector, CUDA runtime, and llama.cpp fork remain subject to their
respective licenses and terms. This repository contains only user-authored
or user-adapted orchestration material and documentation.

