#!/usr/bin/env python3
"""Fetch the pinned Apple MobileCLIP-S0 encoders and compile with Core ML.
Uses only Python's standard library and the macOS Swift toolchain. About 108 MB.
Generated weights stay out of Git. Run before packaging (run/release do this).
"""
import gzip
import hashlib
import pathlib
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / '.build' / 'model-download'
RESOURCES = ROOT / 'Resources'
REVISION = '3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947'
CLIP_REVISION = 'd05afc436d78f1c48dc0dbf8e5980a9d471f35f6'
FILES = {
 'mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/model.mlmodel': '2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591',
 'mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin': '87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6',
 'mobileclip_s0_image.mlpackage/Manifest.json': 'fe07dde983dae92c1799132816ce55f9ff8487f2681b530abf7222025aa27fa4',
 'mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/model.mlmodel': '81eba836ff4dbc8ae021d70006288b533ba7eed3c2973d245b0d5ea047305bfd',
 'mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin': '34723e51445b2630106e94e1fdbebed80e7676b404fb839f4eb9bec97bdcad68',
 'mobileclip_s0_text.mlpackage/Manifest.json': 'a7cb0864a627468a953afd107262097ad74a0fcf82e49df7e00b9c86385bb7db',
}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def download(url, destination, checksum, compressed=False):
    if destination.is_file() and digest(destination) == checksum:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    print('Downloading', destination.name, flush=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if compressed:
        data = gzip.decompress(data)
    if hashlib.sha256(data).hexdigest() != checksum:
        raise RuntimeError('Checksum mismatch: ' + destination.name)
    temporary = destination.with_name(destination.name + '.download')
    temporary.write_bytes(data)
    temporary.replace(destination)

for filename, checksum in FILES.items():
    download('https://huggingface.co/apple/coreml-mobileclip/resolve/' + REVISION + '/' + filename,
             CACHE / filename, checksum)
download('https://raw.githubusercontent.com/openai/CLIP/' + CLIP_REVISION + '/clip/bpe_simple_vocab_16e6.txt.gz',
         RESOURCES / 'bpe_simple_vocab_16e6.txt',
         '67603cfda2e032ad77b5f8808af37789d590db664b26df8705d2bf8b3c553fc8', compressed=True)
compiler = CACHE / 'compile-models'
subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(CACHE / 'module-cache'),
                str(ROOT / 'scripts/compile-models.swift'), '-o', str(compiler)], check=True)
subprocess.run([str(compiler), str(CACHE), str(RESOURCES)], check=True)
print('MobileCLIP image + text encoders and tokenizer are ready.')
