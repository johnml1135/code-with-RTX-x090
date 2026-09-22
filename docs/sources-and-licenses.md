# Sources, pinning, and licenses

The deployment should use a reviewed official PrismML native Windows CUDA
release. The companion lab began from the public PrismML pin
prism-b10709-9a9394a. Resolve the official release page and asset names again
when reproducing because release availability can change.

Use the public Hugging Face repository prism-ml/Ternary-Bonsai-2-27B-gguf for
the approved PQ2_0 model and optional Q8_0 projector. Record the exact
revision, asset byte sizes, ETags when available, and SHA-256 values in a
private install record, never in this source repository if they identify local
private configuration.

Do not substitute stock llama.cpp binaries for the PrismML fork, and do not
commit the development Q2_0 fork-required artifact. The model, projector,
runtime, CUDA libraries, and upstream components retain their own licenses.
See NOTICE.md for public source links and the boundary of this repository.

