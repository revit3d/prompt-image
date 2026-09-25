#!/usr/bin/env python3
"""Prepare the pinned, bundled RU→EN translator; never reads the photo library."""

import argparse
import hashlib
from importlib import metadata
import json
from pathlib import Path
import platform
import shutil
import sys
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "tools/models/translation-source.json"
REQUIREMENTS = ROOT / "tools/models/translation-requirements.txt"
BASE_REQUIREMENTS = ROOT / "tools/models/requirements.txt"
ARTIFACTS = ROOT / "ModelArtifacts"
MAX_TOKENS = 64
PAD, EOS, VOCAB, HIDDEN = 62517, 0, 62518, 512
PUBLIC_PHRASES = [
    ("cat", "кот спит на диване", "a cat sleeping on a sofa"),
    ("beach", "семья на пляже на закате", "a family on a beach at sunset"),
    ("recipe", "скриншот рецепта блинов", "a screenshot of a pancake recipe"),
    ("receipt", "чек из продуктового магазина", "a receipt from a grocery store"),
    ("meme", "смешной мем с собакой", "a funny meme with a dog"),
    ("snow", "красная машина на заснеженной улице", "a red car on a snowy street"),
    ("birthday", "ребёнок задувает свечи на торте", "a child blowing out candles on a cake"),
    ("forest", "грибы в корзине в лесу", "mushrooms in a basket in a forest"),
    ("train", "билет на поезд в Москву", "a train ticket to Moscow"),
    ("pet", "рыжий кот у окна", "an orange cat by a window"),
]
TOKENIZER_CASES = [item[1] for item in PUBLIC_PHRASES] + [
    "", " ", "  кот\tна\nдиване  ", "ёлка", "е\u0308лка",
    "«кот» — это кот…", "café кот 😀", "кот &amp; пёс", "кот\u00a0и\u200bпёс",
    "</s>", "<unk>", "<pad>", "кот</s>пёс", "<eop><eod>",
    ">>en<<кот", "кот >>en<< пёс", ">>ru<< >>en<< кот",
    "№ 15: цена 1 000,50 ₽!", "кот на фото iPhone 17 Pro", "ＡＢＣ кот",
]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def recipe_sha256():
    digest = hashlib.sha256()
    for path in (CONFIG, BASE_REQUIREMENTS, REQUIREMENTS, Path(__file__)):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def installed_versions():
    versions = {}
    for path in (BASE_REQUIREMENTS, REQUIREMENTS):
        for line in path.read_text().splitlines():
            if not line or line.startswith(("#", "-r ")):
                continue
            name, expected = line.split("==")
            actual = metadata.version(name)
            if actual != expected:
                raise ValueError(f"Expected {name}=={expected}, found {actual}; install {REQUIREMENTS}")
            versions[name] = actual
    return versions


def fetch_verified(spec, destination, offline=False):
    destination = Path(destination)
    if destination.exists():
        if destination.stat().st_size != spec["size"] or sha256(destination) != spec["sha256"]:
            raise ValueError(f"Cached source checksum mismatch: {destination}")
        return destination
    if offline:
        raise ValueError(f"Missing cached source in offline mode: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            print(f"Downloading {destination.name}", flush=True)
            with urllib.request.urlopen(spec["url"], timeout=60) as response:
                shutil.copyfileobj(response, output)
        if temporary.stat().st_size != spec["size"] or sha256(temporary) != spec["sha256"]:
            raise ValueError(f"Downloaded source checksum mismatch: {destination.name}")
        temporary.replace(destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return destination


def file_inventory(directory):
    return {
        path.relative_to(directory).as_posix(): sha256(path)
        for path in sorted(directory.rglob("*"))
        if path.is_file() and path != directory / "translation-manifest.json"
    }


def verify_bundle(directory, expected_recipe=None):
    manifest = json.loads((directory / "translation-manifest.json").read_text())
    lock = json.loads(CONFIG.read_text())
    if manifest.get("schema_version") != 1 or manifest.get("model_id") != lock["model_id"]:
        raise ValueError("Unsupported translation manifest")
    if expected_recipe is not None and manifest.get("recipe_sha256") != expected_recipe:
        raise ValueError("Translation recipe changed; run prepare --rebuild")
    if manifest.get("source") != lock or manifest.get("license") != lock["license"]:
        raise ValueError("Translation source provenance does not match the pinned source")
    expected = {
        "source_languages": ["ru"], "target_language": "en", "max_source_tokens": MAX_TOKENS,
        "max_decoder_tokens": MAX_TOKENS, "vocab_size": VOCAB, "hidden_size": HIDDEN,
        "eos_token_id": EOS, "pad_token_id": PAD, "decoder_start_token_id": PAD,
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("Unsupported translation contract")
    files = manifest.get("files", {})
    required = {"source.spm", "target.spm", "vocab.json", "Translation-LICENSE.txt",
                "Translation-ATTRIBUTION.txt", "translation-model-card.md", "tokenizer-golden.json",
                "translation-reference.json", "translation-smoke-report.json"}
    if not required.issubset(files) or not all(
        any(name.startswith(model + ".mlpackage/") for name in files)
        for model in ("TranslationEncoder", "TranslationDecoder")
    ):
        raise ValueError("Translation bundle is incomplete")
    if files != file_inventory(directory):
        raise ValueError("Translation bundle checksum mismatch")
    report = json.loads((directory / "translation-smoke-report.json").read_text())
    if report.get("passed") is not True or report.get("exact_greedy_sequences") != len(PUBLIC_PHRASES):
        raise ValueError("Translation conversion has not passed sequence parity")
    if (report.get("schema_version") != 1 or report.get("model_id") != lock["model_id"]
            or report.get("source_commit") != lock["source_commit"]
            or report.get("recipe_sha256") != manifest.get("recipe_sha256")):
        raise ValueError("Translation smoke report provenance mismatch")
    for name in ("translation-reference.json", "tokenizer-golden.json"):
        reference = json.loads((directory / name).read_text())
        if reference.get("schema_version") != 1 or reference.get("model_id") != lock["model_id"]:
            raise ValueError(f"Translation reference provenance mismatch: {name}")
    return manifest


def source_inputs(tokenizer, text, np):
    ids = tokenizer(text, add_special_tokens=True, truncation=False)["input_ids"]
    if len(ids) > MAX_TOKENS:
        raise ValueError("Source exceeds 63 content tokens plus EOS; truncation is not allowed")
    tokens = np.full((1, MAX_TOKENS), PAD, dtype=np.int32)
    mask = np.zeros((1, MAX_TOKENS), dtype=np.int32)
    tokens[0, :len(ids)] = ids
    mask[0, :len(ids)] = 1
    return ids, tokens, mask


def decode_greedy(encoder, decoder, source_tokens, source_mask, np):
    hidden = encoder(source_tokens, source_mask)
    prefix = [PAD]
    token_ids = []
    for _ in range(MAX_TOKENS - 1):
        decoder_tokens = np.full((1, MAX_TOKENS), PAD, dtype=np.int32)
        decoder_mask = np.zeros((1, MAX_TOKENS), dtype=np.int32)
        decoder_tokens[0, :len(prefix)] = prefix
        decoder_mask[0, :len(prefix)] = 1
        index = np.array([len(prefix) - 1], dtype=np.int32)
        logits = decoder(decoder_tokens, decoder_mask, hidden, source_mask, index)
        if logits.shape != (1, VOCAB) or not np.isfinite(logits).all():
            raise ValueError("Decoder produced invalid logits")
        logits = logits.copy()
        logits[0, PAD] = -np.inf
        next_id = int(np.argmax(logits[0]))
        token_ids.append(next_id)
        if next_id == EOS:
            return token_ids
        prefix.append(next_id)
    raise ValueError("Translation did not finish before the generation limit")


def export_models(cache, output, versions, lock):
    import coremltools as ct
    import numpy as np
    import torch
    from transformers import MarianMTModel, MarianTokenizer

    torch.set_num_threads(4)
    torch.manual_seed(0)
    torch.backends.mha.set_fastpath_enabled(False)
    model = MarianMTModel.from_pretrained(cache, local_files_only=True, attn_implementation="eager").eval().float()
    tokenizer = MarianTokenizer.from_pretrained(cache, local_files_only=True)
    if (model.config.vocab_size, model.config.d_model, model.config.pad_token_id,
        model.config.eos_token_id, model.config.decoder_start_token_id) != (VOCAB, HIDDEN, PAD, EOS, PAD):
        raise ValueError("Upstream model configuration is incompatible")
    if len(tokenizer) != VOCAB:
        raise ValueError("Upstream tokenizer unexpectedly added tokens")

    class Encoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = model.model.encoder

        def forward(self, source_tokens, source_mask):
            return self.encoder(input_ids=source_tokens, attention_mask=source_mask, return_dict=False)[0]

    class Decoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.decoder = model.model.decoder
            self.lm_head = model.lm_head
            self.register_buffer("final_logits_bias", model.final_logits_bias)

        def forward(self, decoder_tokens, decoder_mask, source_hidden, source_mask, last_index):
            hidden = self.decoder(
                input_ids=decoder_tokens, attention_mask=decoder_mask,
                encoder_hidden_states=source_hidden, encoder_attention_mask=source_mask,
                use_cache=False, return_dict=False,
            )[0]
            # Project only one position: avoid allocating 64 × 62,518 logits.
            selected = torch.index_select(hidden, 1, last_index)[:, 0, :]
            return self.lm_head(selected) + self.final_logits_bias

    for name in ("source.spm", "target.spm", "vocab.json"):
        shutil.copyfile(cache / name, output / name)
    shutil.copyfile(cache / "CC-BY-4.0.txt", output / "Translation-LICENSE.txt")
    shutil.copyfile(cache / "README.md", output / "translation-model-card.md")
    (output / "Translation-ATTRIBUTION.txt").write_text(
        "Helsinki-NLP / OPUS-MT Russian-to-English translation model\n"
        "Creator: Language Technology Research Group, University of Helsinki\n"
        "Source: https://huggingface.co/Helsinki-NLP/opus-mt-ru-en\n"
        f"Revision: {lock['source_commit']}\n"
        "License: Creative Commons Attribution 4.0 International\n"
        "https://creativecommons.org/licenses/by/4.0/\n"
        "Modifications by PromptImage: Core ML FP16 conversion, separate fixed-shape encoder and decoder, "
        "bounded greedy decoding instead of upstream beam search. No endorsement implied.\n"
        "Jörg Tiedemann and Santhosh Thottingal (2020), OPUS-MT — Building open translation services for the World.\n",
        encoding="utf-8",
    )
    golden = {
        "schema_version": 1, "model_id": lock["model_id"],
        "normalization": "MarianTokenizer.__call__: special-token splitting, remove_language_code, official source SentencePiece normalization. Do not call tokenizer.normalize (Moses punctuation) separately.",
        "decode": "skip_special_tokens=True, clean_up_tokenization_spaces=False, target SentencePiece DecodePieces",
        "special_tokens": {"eos": EOS, "pad": PAD, "unk": 1},
        "cases": [{"text": text, "tokens": tokenizer(text)["input_ids"]} for text in TOKENIZER_CASES],
    }
    target_cases = [tokenizer(text_target=text)["input_ids"] for text in
                    [item[2] for item in PUBLIC_PHRASES] + ["Hello, world!", "A cat's photo — café.", "123 ₽ 😀"]]
    target_cases += [[], [PAD, EOS, 1], [PAD, 42, 1, 806, EOS]]
    golden["decoder_cases"] = [
        {"tokens": ids, "text": tokenizer.decode(ids, skip_special_tokens=True, clean_up_tokenization_spaces=False)}
        for ids in target_cases
    ]
    write_json(output / "tokenizer-golden.json", golden)
    # This independent reference can be consumed before expensive Core ML conversion finishes.
    write_json(ROOT / "build/translation-tokenizer-golden.json", golden)
    encoder, decoder = Encoder().eval(), Decoder().eval()
    _, tokens, mask = source_inputs(tokenizer, PUBLIC_PHRASES[0][1], np)
    with torch.no_grad():
        hidden = encoder(torch.from_numpy(tokens), torch.from_numpy(mask))
        d_tokens = np.full((1, MAX_TOKENS), PAD, dtype=np.int32)
        d_mask = np.zeros((1, MAX_TOKENS), dtype=np.int32)
        d_mask[0, 0] = 1
        examples = [
            ("TranslationEncoder", encoder, [tokens, mask], ["source_tokens", "source_mask"], "source_hidden"),
            ("TranslationDecoder", decoder, [d_tokens, d_mask, hidden.numpy(), mask, np.array([0], dtype=np.int32)],
             ["decoder_tokens", "decoder_mask", "source_hidden", "source_mask", "last_index"], "logits"),
        ]
        predictors = {}
        trace_errors = {}
        for name, wrapper, arrays, input_names, output_name in examples:
            print(f"Tracing and converting {name}", flush=True)
            example = tuple(torch.from_numpy(array) for array in arrays)
            traced = torch.jit.trace(wrapper, example)
            reference = wrapper(*example).numpy()
            actual = traced(*example).numpy()
            np.testing.assert_allclose(reference, actual, rtol=1e-5, atol=1e-5)
            trace_errors[name] = float(np.max(np.abs(reference - actual)))
            converted = ct.convert(
                traced, source="pytorch", convert_to="mlprogram",
                inputs=[ct.TensorType(name=key, shape=array.shape, dtype=array.dtype)
                        for key, array in zip(input_names, arrays)],
                outputs=[ct.TensorType(name=output_name, dtype=np.float32)],
                minimum_deployment_target=ct.target.iOS17,
                compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_ONLY,
            )
            converted.author = "University of Helsinki; Core ML conversion by PromptImage"
            converted.license = "CC-BY-4.0; see Translation-LICENSE.txt and Translation-ATTRIBUTION.txt"
            converted.short_description = f"{lock['model_id']} / {name}; Russian to English"
            converted.version = lock["model_id"]
            converted.user_defined_metadata["source_commit"] = lock["source_commit"]
            converted.save(str(output / f"{name}.mlpackage"))
            predictors[name] = ct.models.MLModel(str(output / f"{name}.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
            del converted, traced

        def torch_encoder(a, b):
            return encoder(torch.from_numpy(a), torch.from_numpy(b)).numpy()

        def torch_decoder(a, b, c, d, e):
            return decoder(*(torch.from_numpy(item) for item in (a, b, c, d, e))).numpy()

        def ml_encoder(a, b):
            return predictors["TranslationEncoder"].predict({"source_tokens": a, "source_mask": b})["source_hidden"]

        def ml_decoder(a, b, c, d, e):
            return predictors["TranslationDecoder"].predict(dict(zip(
                ["decoder_tokens", "decoder_mask", "source_hidden", "source_mask", "last_index"], [a, b, c, d, e]
            )))["logits"]

        references = []
        for name, text, english in PUBLIC_PHRASES:
            ids, source_tokens, source_mask = source_inputs(tokenizer, text, np)
            # Independent upstream generate(), not only our greedy implementation.
            native = model.generate(
                input_ids=torch.tensor([ids]), attention_mask=torch.ones((1, len(ids)), dtype=torch.long),
                num_beams=1, do_sample=False, max_new_tokens=MAX_TOKENS - 1, forced_eos_token_id=None,
            )[0].tolist()[1:]
            eager = decode_greedy(torch_encoder, torch_decoder, source_tokens, source_mask, np)
            converted = decode_greedy(ml_encoder, ml_decoder, source_tokens, source_mask, np)
            if native != eager:
                raise ValueError(f"{name}: fixed-shape greedy output differs from upstream generate")
            if native != converted:
                raise ValueError(f"{name}: Core ML greedy sequence differs from PyTorch: {native} != {converted}")
            translated = tokenizer.decode(native, skip_special_tokens=True, clean_up_tokenization_spaces=False)
            if not translated.strip():
                raise ValueError(f"{name}: empty translation")
            print(f"TRANSLATION_PARITY {name}: {translated}", flush=True)
            references.append({"id": name, "russian": text, "manual_english": english,
                               "source_tokens": ids, "generated_tokens": native, "translation": translated})

    report = {
        "schema_version": 1, "model_id": lock["model_id"], "source_commit": lock["source_commit"],
        "recipe_sha256": recipe_sha256(),
        "passed": True, "compute_units": "CPU_ONLY", "exact_greedy_sequences": len(references),
        "maximum_trace_absolute_errors": trace_errors,
        "limitations": "Ten handcrafted public phrases. Exact sequence parity verifies conversion, not retrieval quality, all possible queries, or iPhone performance.",
    }
    write_json(output / "translation-reference.json", {"schema_version": 1, "model_id": lock["model_id"], "cases": references})
    write_json(output / "translation-smoke-report.json", report)
    manifest = {
        "schema_version": 1, "model_id": lock["model_id"], "source_languages": ["ru"], "target_language": "en",
        "max_source_tokens": MAX_TOKENS, "max_decoder_tokens": MAX_TOKENS,
        "vocab_size": VOCAB, "hidden_size": HIDDEN, "eos_token_id": EOS, "pad_token_id": PAD,
        "decoder_start_token_id": PAD, "recipe_sha256": recipe_sha256(), "source": lock,
        "license": "CC-BY-4.0", "dependencies": versions,
        "environment": {"python": platform.python_version(), "macos": platform.mac_ver()[0], "architecture": platform.machine()},
        "conversion": {"format": "mlprogram", "precision": "FLOAT16", "minimum_target": "iOS17", "batch_size": 1},
        "generation": {"algorithm": "greedy", "banned_tokens": [PAD], "max_generated_tokens": MAX_TOKENS - 1,
                       "source_overflow": "reject", "missing_eos_at_limit": "reject", "cache": False,
                       "upstream_default": "6 beams; prototype intentionally uses deterministic greedy decoding"},
        "encoder": {"inputs": {"source_tokens": {"dtype": "int32", "shape": [1, MAX_TOKENS]},
                               "source_mask": {"dtype": "int32", "shape": [1, MAX_TOKENS]}},
                    "output": {"source_hidden": {"dtype": "float32", "shape": [1, MAX_TOKENS, HIDDEN]}}},
        "decoder": {"inputs": {"decoder_tokens": {"dtype": "int32", "shape": [1, MAX_TOKENS]},
                               "decoder_mask": {"dtype": "int32", "shape": [1, MAX_TOKENS]},
                               "source_hidden": {"dtype": "float32", "shape": [1, MAX_TOKENS, HIDDEN]},
                               "source_mask": {"dtype": "int32", "shape": [1, MAX_TOKENS]},
                               "last_index": {"dtype": "int32", "shape": [1]}},
                    "output": {"logits": {"dtype": "float32", "shape": [1, VOCAB]}}},
        "files": file_inventory(output),
    }
    write_json(output / "translation-manifest.json", manifest)


def prepare(offline=False, rebuild=False):
    output = ARTIFACTS / "Translation"
    recipe = recipe_sha256()
    if output.exists() and not rebuild:
        verify_bundle(output, recipe)
        print("Prepared translation bundle is current and all checksums match.")
        return
    if platform.system() != "Darwin" or platform.machine() != "arm64" or sys.version_info[:2] != (3, 11):
        raise ValueError("Preparation requires native Apple Silicon macOS with Python 3.11")
    versions = installed_versions()
    lock = json.loads(CONFIG.read_text())
    cache = ARTIFACTS / "TranslationDownloads"
    for name, spec in lock["files"].items():
        if Path(name).name != name:
            raise ValueError("Invalid source filename")
        fetch_verified(spec, cache / name, offline)
    (ROOT / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="translation-preparation-", dir=ARTIFACTS) as temporary:
        temporary = Path(temporary)
        staging = temporary / "Translation"
        staging.mkdir()
        export_models(cache, staging, versions, lock)
        verify_bundle(staging, recipe)
        backup = temporary / "previous-Translation"
        if output.exists():
            output.rename(backup)
        try:
            staging.rename(output)
        except BaseException:
            if backup.exists():
                backup.rename(output)
            raise
    print(f"Prepared and verified {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "verify"])
    parser.add_argument("--offline", action="store_true", help="Require checksum-verified cached sources")
    parser.add_argument("--rebuild", action="store_true", help="Replace bundle only after conversion parity succeeds")
    args = parser.parse_args()
    try:
        if args.command == "verify":
            verify_bundle(ARTIFACTS / "Translation", recipe_sha256())
            print("Translation recipe and file checksums match. No network or inference was used.")
        else:
            prepare(args.offline, args.rebuild)
    except (OSError, ValueError, metadata.PackageNotFoundError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
