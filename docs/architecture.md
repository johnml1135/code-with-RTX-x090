# Architecture

The deployment has one native Windows PrismML llama-server process bound to
127.0.0.1:8080. It loads one PQ2_0 weight copy and the optional Q8_0 vision
projector. Codex and Claude wrappers talk to the same OpenAI Responses and
Anthropic Messages compatible process.

The accepted baseline is aggregate context 262144 with parallel 4. The server
divides that pool into approximately 65536-token slots. The four active slots
share model weights and aggregate KV memory; memory is not four independent
copies of the model. Requests beyond four are queued by the server.

The intended job policy is up to ten admitted jobs, approximately four
executing and the remainder waiting. This is concurrency and queueing, not ten
model processes. Herdr panes remain normal codex or claude kinds and keep their
conversation state independently.

The 524288 aggregate-context experiment is intentionally not part of the
baseline. Re-test from a clean measurement plan before changing context or
parallelism.

