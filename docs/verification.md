# Verification checklist

## Repository checks

Run from the repository root:

    pwsh -NoProfile -File tests/Test-Toolkit.ps1

This parses the PowerShell entry points, checks the deployment contract and
argument builder, validates the working-set and GPU thresholds at their
boundaries, and smoke-tests suspended process creation plus the best-effort
64 MiB / 12 GiB working-set request with a harmless child process. The test
accepts either a successful kernel request or Win32 1314, but no other
working-set API error. In the latter case it verifies the child still starts
and the status reports that the 1-second watcher is the active guard. The
watcher can allow brief overshoot; private commit is reported separately and
is not capped at 12 GiB.

Also run:

    git diff --check
    pwsh -NoProfile -File scripts/Test-Bonsai.ps1 -Mode Live -ConfigPath <root>\config\server.json

The live test requires a healthy local deployment and verifies the alias,
active parallel count, 262144-token per-slot context, Responses, Chat
Completions, and Anthropic Messages endpoints.

## Controlled deployment trial

Before a model trial, confirm that no process from this deployment is already
serving the configured port. Preserve the existing config, launcher, watcher,
run state, and service registration for rollback. Keep model, runtime, logs,
slot files, and benchmark output on G:.

1. Start with the combined ProCreations MTP GGUF, vision disabled, q4_0 K/V,
   medium reasoning, reasoning budget -1, and MTP disabled by default. Use
   `-MtpMode draft-mtp` only for the paired opt-in benchmark.
2. Attempt three independent 262144-token slots first (786432 aggregate
   context). If allocation, health, the 12 GiB watcher threshold, or
   GPU-memory guard fails, terminate that process and try two slots, retaining
   262144 per slot (524288 aggregate).
3. Record actual process command line, PID, private bytes, WorkingSet64,
   virtual bytes, WDDM/GPU used and total memory, active slot count, and
   per-slot context. Record whether the kernel working-set request was
   applied; if it was denied, validate peak WorkingSet64 and watcher behavior.
   Treat private bytes as commit, not resident RAM.
4. Run the local API contract suite and concurrent distinct requests. Confirm
   the server shares one model load and admits up to the active slot count.
5. Compare MTP enabled and disabled on the same slot count, prompts, output
   limits, warm-up, and measurement window. Record prompt and generation
   throughput, latency, failures, memory, and output correctness. Choose MTP
   only if it is stable and improves the measured workload.
6. Confirm the supervisor logs a capacity breach, records a forced two-slot
   retry on G:, and restarts only one server. Verify a validated winner is
   reused across restart and a changed deployment fingerprint permits a fresh
   three-slot-first attempt.
7. Exercise explicit slot save/restore/eviction under the configured G: paths.
   Saved KV state is persistent storage with restore latency, not transparent
   GPU paging or automatic Codex/Claude/Herdr conversation reassignment.
8. Verify startup-task registration and recovery without rebooting the host.
   Boot persistence is only proven by a later planned reboot and must not be
   claimed before that check.

Record trial results, artifact hashes, exact runtime/model revisions, and
acceptance decisions in the private deployment log rather than this repository
when they expose machine-specific paths or identifiers.

## RTX 3090 paired MTP benchmark

The following controlled run used the same combined GGUF/runtime, two shared
262144-token slots (524288 aggregate), q4_0 K/V, vision disabled, 96-token
maximum output, and matching prompt cases in both modes. The 196621-token case
is the largest tested prompt (about 75% of a slot); at that size only one
request was run at a time. Prefill and decode rates below are per request.

| Input tokens / active requests | MTP off prefill / decode (tok/s) | Draft MTP prefill / decode (tok/s) | Peak process WSS off / MTP (GiB) |
| --- | ---: | ---: | ---: |
| 47 / 1 | 390 / 69.3 | 96.7 / 12.5 | 7.76 / 10.12 |
| 47 / 2 | 240 / 50.7, 240 / 53.0 | 32.7 / 7.2, 32.8 / 5.6 | 8.21 / 10.12 |
| 1039 / 1 | 1213 / 69.1 | 556 / 13.9 | 8.94 / 9.56 |
| 1039 / 2 | 627 / 49.4, 628 / 52.0 | 291 / 8.2, 290 / 7.0 | 9.55 / 10.20 |
| 8209 / 1 | 1341 / 63.2 | 962 / 12.8 | 10.46 / 10.19 |
| 196621 / 1 | 625 / 19.9 | 538 / 4.5 | 11.07 / 5.14 |

Draft MTP accepted 387 of 530 proposed draft tokens (73.0%) across the run,
but still lost badly on both prefill and decode at every tested size. Its peak
whole-device GPU use was 22620 MiB (92.0%) versus 19590 MiB (79.7%) with MTP
off. Peak process Private Bytes were 34.91 GiB with MTP versus 23.73 GiB with
MTP off; these are commit counters, not ordinary resident RAM and were not
capped. Both paired runs stayed under the 12-GiB WSS limit (MTP-off maximum
11.07 GiB; MTP-on maximum 10.20 GiB). On this Ampere-generation RTX 3090 the
accepted-draft ratio did not compensate for speculative-path overhead. Keep
the combined MTP weights/runtime, but leave draft MTP off in normal startup;
explicitly opt in only when a new workload-specific benchmark justifies it.

The paired raw JSON reports, with sub-second WorkingSet64/Private Bytes
samples, remain on the private G: deployment rather than in Git. The normal
two-slot MTP-off configuration passed Responses, Chat Completions, Anthropic
Messages, SSE `[DONE]`, tool-call, and vision/video/audio-absent checks. A
controlled server-process termination was recovered by the supervisor and
returned to healthy service on two 262144-token slots. The G: slot manager
saved and restored 27 KV tokens (157393100-byte file, about 150.1 MiB); the
same test rejected both a wrong identity and a modified full deployment
fingerprint before restore, then erased the test file. Restored entries are
cache-active until explicitly released, protecting them from eviction. Startup
task mode and manual-start results are recorded after registration below; no
reboot was performed, so actual post-reboot behavior has not been claimed as
tested.
