# Architecture

One native Windows PrismML llama-server process binds to 127.0.0.1:8080. It
loads the combined ProCreations MTP Bonsai 2 27B GGUF and one shared weight
copy for all active slots. The MTP runtime is stored beside the model on G:.
Vision is disabled with --no-mmproj; no projector is configured or loaded.

Each slot keeps its full 262144-token context. The launcher first attempts
parallel 3 with aggregate --ctx-size 786432. If the process exits before
health, times out during initialization, or fails the resident/VRAM guards, it
falls back to parallel 2 with aggregate --ctx-size 524288. It never reduces
per-slot context. After a mode remains healthy and within guards for ten
minutes, the watcher persists it as the validated winner in the G: run state.
Restarts reuse that winner. A changed runtime/model/config fingerprint
triggers a new three-slot-first trial.

Readiness uses `/health`. Model-loading failures before the first healthy
response do not trigger an extra restart. Once ready, the watcher requires ten
consecutive failed health checks before terminating the supervised child;
recovery follows the same bounded backoff as a process crash, and a successful
check resets the counter. This avoids restarting a busy but healthy inference
server.

MTP uses --spec-type none in normal startup. Draft MTP with at most two tokens
is an explicit opt-in available for benchmarking. On this RTX 3090, paired
tests showed 73% draft-token acceptance but substantially lower prefill and
decode throughput, so MTP-off is the measured production default. KV is q4_0
for K and V, flash attention is enabled, reasoning effort is medium, and
reasoning budget -1 means no token budget cap. The deployed chat template preserves tool-call,
reasoning, OpenAI Responses/Chat Completions, and Anthropic Messages formatting.

The ordinary-RAM target is the llama-server process working set, not system
commit. Before resume, the launcher assigns the suspended server to a
kill-on-close job and requests a 64-MiB minimum / 12-GiB maximum working set.
Under the task's Limited token, Windows may deny that request with Win32 1314.
In that case, active-slots.json reports kernelWorkingSetCapApplied=false and
the one-second watcher kill guard is the active enforcement; it may allow
brief overshoot and is not a strict kernel cap. The watcher samples
WorkingSet64 and terminates/restarts if it observes a value above 12 GiB.
Private Bytes/commit is logged separately; no 12-GiB private-commit cap is
imposed. GPU memory is sampled with nvidia-smi; at the configured 95%
threshold, the watcher terminates and forces a two-slot retry. These process
counters do not represent all Windows file cache or driver-pinned/WDDM memory.

The user-level API is loopback-only at http://127.0.0.1:8080 with alias
bonsai2-27b. Codex can use Responses or Chat Completions, Claude uses Anthropic
Messages, and Herdr continues to launch its normal codex/claude agents.
Requests above the active slot count wait in the server-native queue; the
toolkit does not start a process per agent.

The server receives `--slot-save-path` pointing to the configured G: cache.
Saved slot files are serialized KV state on G:, not transparent paging. They
are tied to the runtime/model/chat-template and relevant KV/MTP/reasoning
deployment fingerprint plus the per-slot context.
Two- or three-slot modes keep the same per-slot context, so a saved slot is not
invalidated solely because the server parallel count changed. Client session
identity still has to be supplied explicitly; no wrapper automatically
reattaches a saved slot to a Codex, Claude, or Herdr conversation.
