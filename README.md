# Bonsai 2 27B on a private RTX x090 lab

This private repository is the reproducible control plane for a local Bonsai 2
27B deployment on an NVIDIA RTX 3090-class Windows host. It does not contain
weights, runtime binaries, DLLs, logs, credentials, live manifests, or
machine-specific configuration. It does include the user-adapted Jinja chat
template needed to reproduce the API behavior.

The design uses the PrismML MTP runtime and the combined
ProCreations/Ternary-Bonsai-2-27B-PQ2_0-MTP-Q8_0.gguf model. One loopback-only
server owns one shared model-weight copy; vision and the image projector are
disabled. The deployment configuration is:

- production uses exactly two warm/live slots at 262144 context tokens each
  (524288 aggregate); a separate controlled capacity trial may temporarily
  test three slots at 204800 each, then fall back to two without shrinking
  below the 204800-token trial floor;
- one shared weight copy across active slots, q4_0 K and V caches, flash
  attention, medium reasoning, unlimited reasoning budget, and MTP disabled
  by default. Draft MTP with at most two tokens is an explicit opt-in;
- process working-set request plus a 12-GiB watcher guard and a 95%
  GPU-memory guard;
  watcher logs working set and Private Bytes separately, and terminates and
  restarts after a working-set breach;
- persistent slot/KV save, restore, and bounded eviction on G:, not transparent
  GPU paging; dormant slot files use one 100-GiB disk budget and a 20-job cap;
- exactly two warm/live sessions are the two active server slots, with KV on
  the GPU; there is no separate CPU-RAM snapshot tier. Dormant sessions use
  G:-backed disk files, capped at 20 jobs and 100 GiB; incidental Windows file
  cache is reclaimable and unreserved.

All model, runtime, cache, log, benchmark, and run-state artifacts belong on
G:. Production serves two live slots; a third is permitted only in the
explicit temporary 3x204800 capacity trial. Additional requests wait in the
server-native queue. Codex, Claude Code, and Herdr session
state remains separate from saved slot/KV files. Exact KV reuse is safe only
when the caller supplies the same model/template/per-slot-context identity and
an explicit stable prompt identity; wrappers do not claim automatic session
restore.

## Contents

- config/ contains safe templates with relative paths and no secrets.
- scripts/ contains parameterized launch, supervision, testing, slot-management,
  client-wrapper, task-registration, and maintenance tools.
- docs/ covers architecture, operations, disk-cache policy, startup/recovery,
  integrations, verification, sources, and rollback.
- tests/Test-Toolkit.ps1 performs offline syntax, path, secret, and contract
  checks.

## Install outline

1. Obtain the reviewed PrismML MTP Windows CUDA runtime and approved combined
   MTP model outside this repository. Verify SHA-256 values and keep the
   private install record outside Git.
2. Copy config/server.template.json to a deployment config/server.json, adjust
   only deployment-root-relative paths, and place the runtime, model, cache,
   logs, benchmark results, and run state under one G: deployment root.
3. Run scripts/Test-Bonsai.ps1 -Mode Contract -ConfigPath ... and then
   scripts/Start-BonsaiServer.ps1 -ConfigPath ... for a foreground check.
4. Run scripts/Test-Bonsai.ps1 -Mode Live ..., then use
   scripts/Watch-BonsaiServer.ps1 for supervised operation.
5. Register the delayed logon task only after foreground and recovery checks
   pass. The task binds only to loopback and contains no tokens.

See docs/verification.md for acceptance checks and docs/rollback.md for the
reversible removal procedure. That document also records the paired RTX 3090
MTP-on/off benchmark and why the measured production default is MTP-off.

## Opt-in clients

The Codex and Claude wrappers set process-scoped local endpoint variables and
forward arguments without changing cloud defaults. The same bonsai2-27b alias
is exposed through OpenAI Responses/Chat Completions and Anthropic Messages.
Use the wrappers only when the local server is healthy. Herdr continues to
start normal codex and claude agent kinds.

## Safety boundary

Do not expose the server beyond 127.0.0.1, do not put cloud credentials in
local wrapper environments, and do not treat persisted slot files as paging.
A saved slot is serialized KV state with restore latency and strict identity
checks. Dormant saved state lives only in G:-backed files; Windows file cache
is incidental and reclaimable, not a reserved RAM tier. The launcher requests
a 64-MiB minimum / 12-GiB maximum kernel working
set before resume. Windows may deny this request under the task's
least-privilege token (Win32 1314); in that case the launcher logs
kernelWorkingSetCapApplied=false and continues under the independent
one-second watcher kill guard. That guard can observe brief overshoot; this is
not a strict kernel cap. WorkingSet64 is distinct from Private Bytes/commit and
GPU/WDDM memory. The normal template remains two slots; a controlled trial
configuration is not promoted automatically and must preserve the two-slot
production policy unless its results are reviewed.
