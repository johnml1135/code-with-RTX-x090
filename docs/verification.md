# Verification

## Offline repository checks

From the repository root:

    pwsh -NoProfile -File tests/Test-Toolkit.ps1

This parses every PowerShell script, including the maintenance utility, checks
the safe relative server template, rejects machine-specific deployment paths
and credential-like text, and rejects model/runtime artifacts.

## Live contract

    pwsh -NoProfile -File scripts/Test-Bonsai.ps1 -Mode Contract -ConfigPath <root>\config\server.json
    pwsh -NoProfile -File scripts/Test-Bonsai.ps1 -Mode Live -ConfigPath <root>\config\server.json

The live test checks health, model alias, OpenAI Responses, and Anthropic
Messages. Add a separately reviewed vision request only when the Q8 projector
is installed.

## Four-slot acceptance

Confirm /props reports four slots with approximately 65536 context each. Issue
four moderate, distinct requests concurrently through the single endpoint and
record first-token latency, completion integrity, throughput, peak VRAM,
remaining VRAM, system RAM, and absence of starvation or CUDA OOM. The proven
reference run retained about 9.3 GiB free VRAM at peak and completed four
distinct streaming Responses requests.

Do not claim 524288 safety from this repository. It is deferred until a new
measurement has plausible VRAM headroom.

## Slot cycle

    pwsh -NoProfile -File scripts/Manage-BonsaiSlots.ps1 -Operation Test -ConfigPath <root>\config\server.json -SlotId 0 -Filename cycle.bin -IdentityText stable-test-identity

Verify the reported file size and save/restore wall times, then verify the
manager's erase result and that the manifest has no entry. Never put a live
manifest, KV file, or prompt transcript in Git.

## Recovery and queue

Kill only the one deployment-root server process and confirm watcher recovery.
Submit four moderate requests simultaneously, then up to six additional
moderate requests as a queue smoke test. Measure queue latency rather than
launching duplicate model processes. Keep client and Herdr session files
outside the slot store.

