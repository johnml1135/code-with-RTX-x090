# KV persistence and cache tiers

The slot manager uses the pinned server's slot actions to serialize KV state to
one file per saved slot. It records a small manifest containing filename,
slot, tier, byte size, token count, timestamps, identity hash, model
fingerprint, context, and parallelism. The manifest contains no prompt text or
credentials.

This is persisted slot/KV state with save and restore latency. It is not
transparent GPU paging. It is not a RAM disk. The warm tier relies only on
normal OS file cache behavior or a user-space memory-mapping strategy; no kernel
driver is installed.

The operational targets are:

- warm target: 15 GiB maximum host-RAM accounting, with three saved/restorable
  jobs as the conservative initial target;
- cold target: 100 GiB maximum on the deployment drive, with approximately 25
  saved jobs as the conservative initial target;
- eviction: oldest inactive entries only, never an active entry;
- path safety: a saved name must be a single safe basename under slotSavePath.

The deployment reference cycle saved 3098 prompt tokens to a 214071484-byte
file, about 204.2 MiB. Server save timing was about 174 ms and wall time about
248 ms; restore timing was about 118 ms and wall time about 200 ms. These are
measurements, not a capacity guarantee. Measure representative prompt fills
before expanding the warm or cold job counts.

Codex, Claude, and Herdr do not expose a stable cross-process slot identity in
their normal session APIs. The wrappers therefore do not automatically restore
KV state. A caller may use the manager explicitly when it can prove prompt,
template, model, context, and slot identity. Otherwise resend conversation
history and let the server's normal prefix-cache behavior help where available.

