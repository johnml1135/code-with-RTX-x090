# KV persistence and disk cache policy

The deployment has exactly two warm/live sessions: the two active
llama-server slots, with active KV state on the GPU subject to runtime/GPU
limits. There is no separate CPU-RAM snapshot tier. Dormant saved-slot state
is serialized by llama-server into files under `slotSavePath` on G:. There is
no RAM disk, preloader, dormant-session RAM reservation, or promise that an
inactive slot remains resident.

Windows may keep recently read model or slot-file pages in its normal file
cache. That cache is incidental, reclaimable by Windows, not reserved for
Bonsai, and not counted as a dormant KV tier. The deployment does not pin or
prefault those pages. The server's 12-GiB process working-set guard remains
separate from Private Bytes/commit and driver/WDDM memory; no 12-GiB commit
cap is imposed.

The single saved-state policy is:

- one G:-backed disk budget capped at 100 GiB;
- at most 20 saved jobs, subject to each save's actual file size;
- oldest inactive entries may be evicted to satisfy either limit;
- active restored entries and the save currently being created are protected;
- if limits cannot be met without evicting active/protected state, the
  operation fails without evicting those entries;
- safe single-basename paths under `slotSavePath`; no prompt text or credentials
  in the manifest.

The manifest records file size, token count, timestamps, identity hash,
deployment fingerprint, context, and parallelism. Older manifests may contain
`warm`/`cold` labels; those labels are ignored as obsolete metadata and removed
the next time the manifest is written. They do not designate separate storage
or authorize RAM residency. Legacy entries without the full deployment
fingerprint are refused for restore and must be re-saved before reuse.

Save requires a non-empty explicit identity. Restore verifies that identity
and the active deployment fingerprint, then marks the manifest entry `active`
so disk-budget eviction cannot remove the persisted state. After the restored
context is no longer needed, explicitly release it with
`Manage-BonsaiSlots.ps1 -Operation Release -Filename <name> -IdentityText <id>`;
release marks it `inactive` and eligible for oldest-first disk eviction. The
manager cannot infer whether a client is still relying on a restored context,
so release is an operator assertion, not automatic activity detection. If a
single save or active/protected set cannot fit the disk budget/job-count cap,
Save/Evict reports failure rather than claiming the state was retained.

The previous smoke measurement (27 tokens, 157,393,100 bytes, about 150.1 MiB;
server save/restore about 140/133 ms) is not representative enough to size
dormant-session behavior. A 3,098-token reference used 214,071,484 bytes
(about 204.2 MiB), showing file size does not scale linearly with token count.
Acceptance therefore measures save and restore separately with realistic
32K-token and near-full-context prompts, records actual file sizes, and uses
five seconds as the maximum acceptable restore time. Any produced test slot
files must be erased after the measurements. No smaller smoke result is used
to infer 32K or 200K behavior.

Two active inference slots at 262144 tokens each remain the production
setting. A controlled three-slot GPU trial at 204800 tokens per slot uses a
temporary third live slot; it does not create three CPU-RAM snapshots or
change the two-session production warm/live policy. Saved state for inactive
conversations remains on G: regardless of active slot count. The 100-GiB,
20-job target is disk persistence, not 20 simultaneous model contexts.

Codex, Claude, and Herdr do not expose a stable cross-process slot identity in
their normal session APIs. Wrappers therefore do not automatically restore KV
state. A caller may use the manager explicitly when it can prove prompt,
template, model, context, and slot identity. Otherwise resend conversation
history and let the server's normal prefix-cache behavior help where
available.
