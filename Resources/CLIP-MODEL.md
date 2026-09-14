# Beacon local image search

Run `python3 scripts/prepare-models.py` before building a bundle. The run and
release scripts call it automatically if assets are missing. It downloads about
108 MB from [Apple's published Core ML models](https://huggingface.co/apple/coreml-mobileclip),
verifies pinned SHA-256 checksums, and compiles both encoders with Core ML.
Full Xcode, Python ML packages, and a model conversion environment are unnecessary.
Generated weights are ignored by Git; model and tokenizer license notices ship in the bundle.

Contract: MobileCLIP-S0, center-cropped 256×256 RGB image, `[1,77]` Int32 text
IDs, and matching 512-value normalized embeddings. The cache is versioned by
model and preprocessing. `scripts/test-semantic.sh --models` exercises the real
encoders without reading personal files or contacting an AI provider.

Enable **AI → Manage → Index images on this Mac**. The index stays local and
reports its progress. It covers Desktop, Downloads, Documents, Pictures, and
Movies. Explicit Photos authorization adds locally available Photos originals.
Cloud-only files are skipped. New/modified images are refreshed every two minutes;
indexing pauses when disabled or when the Mac is hot. The last index is retained
if a scan is interrupted or access is temporarily unavailable.

Queries apply dates before semantic ranking, then verify at most 40 candidates
with the user's configured AI provider. This is bounded retrieval, not proof that
every matching photo was found. No provider calls occur during indexing.

Cache: `~/Library/Application Support/Beacon/image-index.v2.json`.
The current implementation keeps vectors in memory and persists them as JSON;
very large libraries would benefit from a disk-backed vector store. CloudStorage
folders and undownloaded Photos originals are not included in this version.
