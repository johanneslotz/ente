#!/usr/bin/env python3
"""
Convert MobileCLIP-B (LT) PyTorch checkpoint to ONNX for ente Photos.

Steps:
  1. Download mobileclip_blt.pt.zip from Nextcloud (~599 MB)
  2. Load the model via Apple's ml-mobileclip (auto-cloned from GitHub if needed)
  3. Export image encoder  -> mobileclip_b_lt_image.onnx          (float32, opset 18)
  4. Export text encoder   -> mobileclip_b_lt_text_opset18.onnx   (float32, opset 18)
  5. Quantize text encoder -> mobileclip_b_lt_text_opset18_quant.onnx (int8 weights)
  6. Upload both final ONNX files to Nextcloud via WebDAV

MobileCLIP-B (LT) specs:
  embed_dim   : 512
  image_size  : 224 x 224  (NOTE: B uses 224, not 256 like S2)
  token_count : 77

Usage:
    pip install -r requirements_convert.txt
    python convert_mobileclip_b_lt.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import requests
import torch
import torch.nn as nn

# ---------------------------------------------------------------------------
# Nextcloud config
# ---------------------------------------------------------------------------
NEXTCLOUD_WEBDAV = "https://cloud.lotz.dev/public.php/webdav"
NEXTCLOUD_TOKEN  = "jCscPdqpkmJXH3r"
NEXTCLOUD_AUTH   = (NEXTCLOUD_TOKEN, "")

CHECKPOINT_ZIP   = "mobileclip_blt.pt.zip"

IMAGE_ONNX_NAME  = "mobileclip_b_lt_image.onnx"
TEXT_ONNX_FLOAT  = "mobileclip_b_lt_text_opset18.onnx"
TEXT_ONNX_QUANT  = "mobileclip_b_lt_text_opset18_quant.onnx"

# MobileCLIP-B uses 224x224 (S2 used 256x256)
IMAGE_SIZE   = 224
TOKEN_COUNT  = 77
EMBED_DIM    = 512
OPSET        = 18

ML_MOBILECLIP_REPO = "https://github.com/apple/ml-mobileclip.git"
ML_MOBILECLIP_DIR  = Path("/tmp/ml-mobileclip")


# ---------------------------------------------------------------------------
# ml-mobileclip bootstrap
# ---------------------------------------------------------------------------

def _ensure_mobileclip() -> None:
    """Clone Apple's ml-mobileclip repo and add it to sys.path if needed."""
    try:
        import mobileclip  # noqa: F401
        return  # already importable
    except ImportError:
        pass

    if not ML_MOBILECLIP_DIR.exists():
        print(f"  Cloning ml-mobileclip from GitHub -> {ML_MOBILECLIP_DIR} …")
        subprocess.run(
            ["git", "clone", ML_MOBILECLIP_REPO, str(ML_MOBILECLIP_DIR), "--depth=1", "-q"],
            check=True,
        )

    sys.path.insert(0, str(ML_MOBILECLIP_DIR))
    try:
        import mobileclip  # noqa: F401
    except ImportError as exc:
        sys.exit(f"ERROR: could not import mobileclip after cloning: {exc}")


# ---------------------------------------------------------------------------
# ONNX export wrappers
# ---------------------------------------------------------------------------

class ImageEncoderWrapper(nn.Module):
    """Wraps model.image_encoder: float32[B,3,224,224] -> float32[B,512]."""
    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self._encoder = model.image_encoder

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self._encoder(x)
        if isinstance(out, (tuple, list)):
            out = out[0]
        return out


class TextEncoderWrapper(nn.Module):
    """
    Accepts int32 tokens (Android Int32List) and returns float32[B,512].
    Converts int32 -> int64 internally for the embedding lookup.
    """
    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self._model = model

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        out = self._model.encode_text(tokens.long())
        if isinstance(out, (tuple, list)):
            out = out[0]
        return out


# ---------------------------------------------------------------------------
# Download + load
# ---------------------------------------------------------------------------

def _webdav_url(filename: str) -> str:
    return f"{NEXTCLOUD_WEBDAV}/{filename}"


def _download_with_progress(url: str, dest: Path) -> None:
    with requests.get(url, auth=NEXTCLOUD_AUTH, stream=True) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("content-length", 0))
        downloaded = 0
        with open(dest, "wb") as f:
            for chunk in resp.iter_content(chunk_size=8 * 1024 * 1024):
                if chunk:
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        pct = downloaded * 100 // total
                        mb = downloaded // 1_000_000
                        print(f"\r    {pct}%  {mb} / {total // 1_000_000} MB", end="", flush=True)
    print()


def get_checkpoint(dest_dir: Path) -> Path:
    """
    Return the path to a torch-loadable checkpoint file.
    PyTorch .pt files are ZIP archives internally, so many HF uploads rename
    them to .zip — torch.load handles both transparently.
    """
    local_zip = Path(CHECKPOINT_ZIP)
    dest      = dest_dir / CHECKPOINT_ZIP

    if local_zip.exists():
        print(f"[1/6] Using local {CHECKPOINT_ZIP} (skipping download).")
        return local_zip

    print(f"[1/6] Downloading {CHECKPOINT_ZIP} (~599 MB) from Nextcloud …", flush=True)
    _download_with_progress(_webdav_url(CHECKPOINT_ZIP), dest)
    return dest


def load_model(checkpoint: Path):
    import mobileclip  # guaranteed importable after _ensure_mobileclip()
    print("[3/6] Loading MobileCLIP-B architecture …", flush=True)
    model, _, _ = mobileclip.create_model_and_transforms("mobileclip_b", pretrained=None)
    model = model.eval()

    print("    Loading checkpoint weights …")
    state = torch.load(str(checkpoint), map_location="cpu", weights_only=False)
    if isinstance(state, dict):
        state = (
            state.get("state_dict")
            or state.get("model_state_dict")
            or state.get("model")
            or state
        )
    else:
        state = state.state_dict()
    state = {k.removeprefix("module."): v for k, v in state.items()}

    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing:
        print(f"    WARNING: {len(missing)} missing keys.  First 5: {missing[:5]}")
    if unexpected:
        print(f"    WARNING: {len(unexpected)} unexpected keys.  First 5: {unexpected[:5]}")
    print("    Weights loaded.")
    return model


# ---------------------------------------------------------------------------
# Export + quantize
# ---------------------------------------------------------------------------

def _onnx_export_single_file(
    wrapper: nn.Module,
    dummy: torch.Tensor,
    out_path: Path,
) -> None:
    """
    Export to a single monolithic ONNX file.

    PyTorch >=2.4 defaults to the dynamo exporter which stores weights in a
    separate .onnx.data sidecar file.  We force the legacy TorchScript-based
    exporter (dynamo=False) which always produces one self-contained file.
    """
    export_kwargs: dict = dict(
        opset_version=OPSET,
        input_names=["input"],
        output_names=["output"],
        do_constant_folding=True,
    )
    try:
        # PyTorch >= 2.1: dynamo=False forces the legacy TorchScript exporter
        with torch.no_grad():
            torch.onnx.export(wrapper, dummy, str(out_path), dynamo=False, **export_kwargs)
    except TypeError:
        # Older PyTorch: dynamo kwarg not recognised, use default (legacy) exporter
        with torch.no_grad():
            torch.onnx.export(wrapper, dummy, str(out_path), **export_kwargs)


def export_image_encoder(model, out_path: Path) -> None:
    print(f"[4/6] Exporting image encoder -> {out_path.name} …", flush=True)
    wrapper = ImageEncoderWrapper(model).eval()
    dummy   = torch.zeros(1, 3, IMAGE_SIZE, IMAGE_SIZE)

    with torch.no_grad():
        out = wrapper(dummy)
    if tuple(out.shape) != (1, EMBED_DIM):
        raise RuntimeError(f"Unexpected image output shape {tuple(out.shape)}")
    print(f"    Output shape OK: {tuple(out.shape)}")

    _onnx_export_single_file(wrapper, dummy, out_path)
    print(f"    Saved {out_path.name} ({out_path.stat().st_size // 1_000_000} MB)")


def export_text_encoder(model, out_path: Path) -> None:
    print(f"[5a/6] Exporting text encoder (float32) -> {out_path.name} …", flush=True)
    wrapper = TextEncoderWrapper(model).eval()
    dummy   = torch.zeros(1, TOKEN_COUNT, dtype=torch.int32)

    with torch.no_grad():
        out = wrapper(dummy)
    if tuple(out.shape) != (1, EMBED_DIM):
        raise RuntimeError(f"Unexpected text output shape {tuple(out.shape)}")
    print(f"    Output shape OK: {tuple(out.shape)}")

    _onnx_export_single_file(wrapper, dummy, out_path)
    print(f"    Saved {out_path.name} ({out_path.stat().st_size // 1_000_000} MB)")


def quantize_text_encoder(float_path: Path, quant_path: Path) -> None:
    print(f"[5b/6] Quantizing text encoder -> {quant_path.name} …", flush=True)
    try:
        from onnxruntime.quantization import QuantType, quantize_dynamic
    except ImportError:
        sys.exit("ERROR: onnxruntime not installed.  Run: pip install onnxruntime")

    quantize_dynamic(str(float_path), str(quant_path), weight_type=QuantType.QInt8)
    print(f"    Saved {quant_path.name} ({quant_path.stat().st_size // 1_000_000} MB)")


# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------

def upload_file(local_path: Path, remote_name: str) -> None:
    url = _webdav_url(remote_name)
    print(f"    {remote_name} ({local_path.stat().st_size // 1_000_000} MB) -> {url}", flush=True)
    with open(local_path, "rb") as f:
        resp = requests.put(url, auth=NEXTCLOUD_AUTH, data=f,
                            headers={"Content-Type": "application/octet-stream"})
    resp.raise_for_status()
    print(f"    Upload OK (HTTP {resp.status_code})")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    print("[0/6] Ensuring ml-mobileclip is available …", flush=True)
    _ensure_mobileclip()

    with tempfile.TemporaryDirectory(prefix="mobileclip_b_lt_") as tmp:
        tmp_dir    = Path(tmp)
        checkpoint = get_checkpoint(tmp_dir)

        print("[2/6] Probing checkpoint …", flush=True)
        # torch.load works on both .pt and .zip (PyTorch .pt IS a ZIP internally)
        model = load_model(checkpoint)

        image_onnx = tmp_dir / IMAGE_ONNX_NAME
        text_float = tmp_dir / TEXT_ONNX_FLOAT
        text_quant = tmp_dir / TEXT_ONNX_QUANT

        export_image_encoder(model, image_onnx)
        export_text_encoder(model, text_float)
        quantize_text_encoder(text_float, text_quant)

        print("[6/6] Uploading to Nextcloud …", flush=True)
        upload_file(image_onnx, IMAGE_ONNX_NAME)
        upload_file(text_quant, TEXT_ONNX_QUANT)

    base = "https://cloud.lotz.dev/s/jCscPdqpkmJXH3r/download?path=%2F&files="
    print("\nDone!  Public download URLs:")
    print(f"  Image : {base}{IMAGE_ONNX_NAME}")
    print(f"  Text  : {base}{TEXT_ONNX_QUANT}")


if __name__ == "__main__":
    main()
