# PrismML Bonsai 2 27B A/B baseline

Checked 2026-09-22 against the local G: deployment and first-party sources.
No files were downloaded for this comparison.

## Official model and runtime

The official model is [PrismML's Ternary-Bonsai-2-27B GGUF repository](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf), based on Qwen3.8-27B. Its local PQ2_0 GGUF is 7,206,168,928 bytes and SHA-256 `3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1`, matching the [published file metadata](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/blame/main/Ternary-Bonsai-2-27B-PQ2_0.gguf). The optional Q8_0 projector is not loaded in these text-only trials.

The official local `llama-server.exe` reports `0.2.0-dev`, build 10709, commit `9a9394a89`; its SHA-256 is `1cdb8bd16b90310dbca148d3b07ffdc0010d49985cc37aa7bf21e805bb870cf5`. The corresponding [PrismML llama.cpp release](https://github.com/PrismML-Eng/llama.cpp/releases/tag/prism-b10709-9a9394a) publishes Windows x64 CUDA 13.3 assets. The extracted executable's per-file hash is local-only; it is not a published release checksum. The official binary's `--help` advertises the deployment's context, parallel, cache, flash-attention, chat-template, slot-save, MTP-off, and reasoning flags.

## Community MTP candidate

The installed combined ProCreations GGUF is 7,657,489,728 bytes with SHA-256 `3cb3f0056d2e34ee44245a64396004a21f8492573d6ce1266ec4b7222c131dd4`, matching the local [ProCreations SHA256SUMS](https://huggingface.co/ProCreations/Ternary-Bonsai-2-27B-MTP/blob/main/SHA256SUMS). The associated MTP runtime reports build `20260919`, commit `d8f26eec-bonsai-mtp`. That merged GGUF checksum is not a PrismML-published hash. Normal deployment and these A/B runs set `--spec-type none`; the comparison therefore measures the combined weights without MTP drafting.

The current G: `server.json` selects the combined MTP runtime/model, `127.0.0.1:8080`, alias `bonsai2-27b`, Q4_0 K/V, flash attention, Jinja, medium reasoning, 12-GiB process working-set guard, and 95% GPU-memory guard. Historical four-slot/projector records do not describe this active two-slot configuration.

## API and tool compatibility sources

PrismML's [tagged server documentation](https://github.com/PrismML-Eng/llama.cpp/blob/prism-b10709-9a9394a/tools/server/README.md) documents OpenAI-compatible Chat Completions and Responses plus Anthropic-compatible Messages and streaming support. The [PrismML tool guide](https://github.com/PrismML-Eng/Bonsai-demo/blob/main/TOOLS.md) documents Jinja-based function calling and structured `tool_calls`. These references establish the intended compatibility surface; live results for both candidates are recorded separately in the A/B report.

The install record verifies the official model and runtime identity; the benchmark compares both candidates with identical text-only inputs, settings, and API probes. Runtime binary hashes are local verification data, not substitutes for signed provenance.
