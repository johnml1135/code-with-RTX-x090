# Sources, pinning, and licenses

The deployment pairs the reviewed PrismML native Windows CUDA MTP runtime with
the combined ProCreations/Ternary-Bonsai-2-27B-PQ2_0-MTP-Q8_0.gguf artifact
from the public ProCreations MTP repository. Verify the selected runtime build
and model revision, exact asset names, byte sizes, and SHA-256 values in a
private install record before reproducing the deployment.

The launch configuration disables image/projector loading. Do not add a
projector or substitute stock llama.cpp binaries for the PrismML runtime.
Neither runtime/model artifacts nor CUDA libraries are redistributed here;
each remains subject to its own license and terms. See NOTICE.md for source
links and repository boundaries.
