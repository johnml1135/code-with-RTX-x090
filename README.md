# Bonsai 2 27B on a private RTX x090 lab

This private repository is the reproducible control plane for a local Bonsai 2
27B deployment on an NVIDIA RTX 3090-class Windows host. It intentionally does
not contain weights, projectors, runtime binaries, DLLs, logs, credentials,
live manifests, or machine-specific configuration.

The design uses PrismML's llama.cpp fork with the
Ternary-Bonsai-2-27B-PQ2_0.gguf model and the optional
Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf projector. One loopback-only server
owns one GPU-resident weight copy. The proven baseline is:

- aggregate server context 262144;
- four server slots, approximately 65536 context per active slot;
- fork-supported 4-bit K/V cache and flash attention, with flag spellings
  confirmed from the pinned binary's help output;
- native server queueing beyond four active requests;
- explicit slot/KV save, restore, erase, and bounded eviction under a cold
  store capped at 100 GiB;
- a documented 15 GiB warm target using ordinary OS file caching or user-space
  memory mapping, not a RAM-disk driver or transparent GPU paging.

Up to ten client jobs may be admitted by letting the single server execute four
and queue the remainder. The queue is server-native; this toolkit deliberately
does not ship a fragile custom admission scheduler. Codex, Claude Code, and
Herdr session state remains separate from saved slot/KV files. Exact KV reuse
is safe only when the caller supplies the same model/template/context identity
and an explicit stable prompt identity; these clients do not automatically
expose a durable mapping, so wrappers do not claim automatic session restore.

## Contents

- config/ contains safe templates with relative paths and no secrets.
- scripts/ contains parameterized launch, supervision, testing, slot-management,
  client-wrapper, task-registration, and maintenance tools.
- docs/ covers architecture, operations, cache tiers, startup/recovery,
  integrations, verification, sources, and rollback.
- tests/Test-Toolkit.ps1 performs offline syntax, path, secret, and contract
  checks.

## Install outline

1. Obtain the official pinned PrismML Windows CUDA runtime and approved model
   artifacts outside this repository. Verify SHA-256 values and keep the
   private install record outside Git.
2. Copy config/server.template.json to a deployment config/server.json, adjust
   only paths and approved public settings, and place the runtime, model,
   projector, cache, logs, and run state under one deployment root such as
   a dedicated deployment-root directory.
3. Run scripts/Test-Bonsai.ps1 -Mode Contract -ConfigPath ... and then
   scripts/Start-BonsaiServer.ps1 -ConfigPath ... for a foreground check.
4. Run scripts/Test-Bonsai.ps1 -Mode Live ..., then use
   scripts/Watch-BonsaiServer.ps1 for supervised operation.
5. Register the delayed logon task only after foreground and recovery checks
   pass. The task binds only to loopback and contains no tokens.

See docs/verification.md for acceptance checks and docs/rollback.md for the
reversible removal procedure.

## Opt-in clients

The Codex and Claude wrappers set process-scoped local endpoint variables and
forward arguments without changing cloud defaults. Use them only when the
local server is healthy. Herdr should continue to start normal codex and
claude agent kinds; integration refresh is a host operation documented in
docs/client-integrations.md.

## Safety boundary

Do not expose the server beyond 127.0.0.1, do not put cloud credentials in
local wrapper environments, and do not treat persisted slot files as paging.
A saved slot is serialized KV state with restore latency and strict identity
checks. Re-measure VRAM, RAM, latency, throughput, and context before changing
the four-slot baseline or attempting a larger aggregate context.

