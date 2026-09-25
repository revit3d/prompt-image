# Step 1.3: public evaluation sample

The initial benchmark uses public images so development can begin without exporting your personal library. It contains **400 images**: **320 COCO 2017 validation photos** and **80 TextVQA validation images with scene text**. Files and labels stay in the Git-ignored `PrivateData/Evaluation/` directory, outside the app sources.

These dataset utilities prepare and freeze evaluation inputs; they do not run a model. [Step 3.4](RETRIEVAL.md) adds a separate on-device development visual retrieval run using this corpus. The corpus and query counts are practical pilot choices, not a statistically precise estimate for all users.

## Download and inspect the sample

Run from the repository root with Python 3.9 or later; the tools use Python's standard library:

```sh
python3 tools/evaluation.py init
python3 tools/download_evaluation.py
python3 tools/evaluation.py inventory
```

The downloader selects a fixed subset using seed `173`. It retrieves individual images rather than a complete image archive, with four concurrent downloads, a 5 MiB cap per image, and a 20-second timeout per request. Rerunning resumes existing files; files with recorded hashes must still match those hashes. Failed downloads leave already completed images available for the next attempt.

COCO's captions are read from its annotation ZIP using HTTP Range requests, avoiding the full archive when the server supports this. If Range requests are unavailable, the downloader stops. To permit the approximately 241 MB annotation archive as a fallback, run:

```sh
python3 tools/download_evaluation.py --allow-full-coco-archive
```

Metadata downloads are capped at 300 MiB. TextVQA metadata is downloaded separately. Actual image download size depends on the selected source files. The downloader checks JPEG start/end markers and hashes; this is not a complete image decoder. Open sample files and all labeled target images to verify their contents and readability.

The local files are:

```text
PrivateData/Evaluation/
  images/coco/                 320 ordinary scene photographs
  images/textvqa/              80 photographs containing text
  images.csv                   Local image IDs, paths, and SHA-256 hashes
  queries.csv                  Russian/English queries and acceptable matches
  queries.development.csv      56 queries for model and ranking development
  queries.holdout.csv          24 queries reserved for candidate evaluation
  benchmark.json              Counts and hashes of the frozen benchmark files
  provenance.csv               Image source URLs, listed licenses, hashes, sizes
  sources/
    captions_val2017.json      Original COCO captions and image metadata
    TextVQA_0.5.1_val.json      Original TextVQA questions and human answers
    selection.json             Chosen images and their annotation evidence
    SOURCE_INFO.json           Source URLs, selection settings, metadata hashes
```

The files are downloaded to the Mac. These dataset tools do not access the Photos library, upload data, or put the sample on your phone. The downloader needs a network connection; inventory and validation are local. The separate [retrieval-demo preparation and developer transfer](RETRIEVAL.md) copies unchanged images into the app's data container. Git exclusion does not encrypt files or control backups and folder synchronization.

## Sources and what this sample covers

[COCO](https://cocodataset.org/#download) supplies ordinary photographs and captions. Selection uses only images whose individual license URL is a Creative Commons Attribution license; `provenance.csv` records the actual listed license for each image. COCO's annotation license and individual image licenses are separate; see its [terms of use](https://cocodataset.org/#termsofuse).

[TextVQA](https://textvqa.org/dataset/) supplies images, questions, and ten human answers per question. The sampler keeps one question per image when at least eight answers agree on a text-like answer, excluding simple yes/no, numeric, and common color answers. Agreement supplies useful evidence but does not prove the answer is visible text: inspect each chosen target before writing a retrieval query. TextVQA publishes its annotations under CC BY 4.0.

The TextVQA image files come from the [CVDF Open Images mirror](https://github.com/cvdfoundation/open-images-dataset). [Open Images](https://github.com/openimages/dataset) lists source images under CC BY 2.0 and says that individual license status is not warranted. Original image URLs and dataset licenses are retained locally. The manifest does not contain verified photographer credits for every image; it is a development record, not a package cleared for public redistribution. Keep the downloaded corpus out of the app bundle and Git.

The benchmark covers visual scenes and mostly English text on signs, products, and similar objects. It does **not** establish quality on personal memories, Russian text recognition, phone screenshots, recipes, or memes. Russian queries that quote English lettering can exercise Russian query handling, but they do not test Cyrillic OCR. Add a separately documented personal and Cyrillic-text supplement before deciding whether the app is useful for the intended Russian audience.

## Prepare and review 80 queries

The query structure is **40 retrieval scenarios**, each with a Russian and English wording:

| Kind | Development scenarios | Held-out scenarios | Queries in both languages |
| --- | ---: | ---: | ---: |
| `visual` | 14 | 6 | 40 |
| `text` | 14 | 6 | 40 |
| Total | 28 | 12 | 80 |

Both wordings of a scenario share a `group_id`, split, and intended answers. Different scenarios may search the same corpus; the holdout separates queries, not images. Do not place translations, paraphrases, or effectively identical retrieval intents in different splits.

`init` creates a blank template when no query file exists. A fresh download provides images and annotation evidence, not automatically verified queries. If `queries.csv` has already been populated for this project, review those rows rather than replacing them.

For each scenario:

1. Use `sources/selection.json` to find a suitable image and its original caption or question/answer evidence.
2. Open the image and check that the intended match is visible. For visual queries, describe visible objects, attributes, or a scene. For text queries, search for actual visible lettering. Do not turn a question about an unknown word into a retrieval query without supplying text the search can match.
3. Write a natural Russian query in the `ru` row and an equivalent English query in the `en` row. Preserve quoted image text when its exact spelling is the search target.
4. Find the image in `images.csv` using `relative_path`, then copy its `image_id` into `expected_image_ids`. Separate multiple known acceptable matches with `|`, without spaces. Use the same intended answer set for both languages.
5. Record annotation provenance, ambiguities, and any limits in `notes`. Known positives are not guaranteed exhaustive relevance labels.

The local image IDs are `img_` plus the first 12 hexadecimal characters of the file's SHA-256 hash. The full hash is retained and shortened-ID collisions are detected. Exact-byte duplicate files share one ID and do not increase the unique-image count; no source files are deleted. Editing or re-exporting an image can change its ID, so keep the sample stable after labeling.

The query columns are:

| Column | Meaning |
| --- | --- |
| `query_id` | Unique ID for a language version |
| `group_id` | Retrieval scenario shared by its language versions |
| `split` | Development or held-out assignment from the template |
| `language` | `ru` or `en` |
| `kind` | `visual` or `text` |
| `query` | Text to enter in the search field |
| `expected_image_ids` | Known acceptable local image IDs, separated by `|` |
| `notes` | Source evidence and optional explanation |

Save edits as UTF-8 CSV to preserve Cyrillic text. Every query needs at least one known acceptable match. Replace a query with no correct match; do not invent one to fill the template.

Use development queries to choose and tune models, translation, and ranking. Set held-out queries aside after labeling and use them to check the resulting candidate. If repeated tuning depends on held-out results, prepare fresh held-out scenarios before claiming a final result. Since this corpus uses public benchmark images, model pretraining may have included them; a successful run is useful engineering evidence, not proof of unseen personal-photo performance.

## Validate and reuse on the phone

Run:

```sh
python3 tools/evaluation.py validate
```

Resolve reported structural issues and manually check the labels against the images. Step 1.3's public-data preparation is complete when 400 unique images are present and viewable, the source records exist, all 80 queries have reviewed answers, and validation passes. An empty template alone is not a completed benchmark.

After reviewing the labels, run `python3 tools/evaluation.py freeze`. This validates the dataset, exports the two separate query files, and records their SHA-256 fingerprints in `benchmark.json`. Use `queries.development.csv` during development and reserve `queries.holdout.csv` for candidate evaluation. Preserve a copy of the existing benchmark before intentional corrections, then run `freeze` again to refresh the exports. Freezing records a revision; it does not make files read-only or prevent you from inspecting the held-out labels.

For step 3.4, follow [RETRIEVAL.md](RETRIEVAL.md) to transfer a developer-only copy to `Documents/RetrievalDemo` in the app's data container. This preserves the 400 image files and exports only the 28 development visual queries. It requires no Photos import or permission and is suitable for testing the embedding/translation/ranking pipeline before persistent library indexing exists.

Before testing PhotoKit search in a later step, transfer copies of the sample into an iPhone album named **PromptImage Evaluation**. That future transfer is separate from the step 3.4 demo and modifies the phone's library; downloading to the Mac or copying into the app container does not. Keep those imported images available locally because the first prototype will skip iCloud downloads.

Exported-file IDs and dataset IDs are **not PhotoKit asset identifiers**. Filename or byte-hash equality does not reliably map a Mac file to a phone asset, especially if Photos converts it during import. Add and verify that mapping when PhotoKit access is implemented.

## Scoring

For each query, **success@5** is 1 if at least one known acceptable image appears among the first five results, otherwise 0. Average these values and report both counts and percentages. Report visual and text queries separately, Russian and English separately within each kind, and development results separately from held-out results.

The step 3.4 [scoring command](RETRIEVAL.md#run-the-development-evaluation) reports development visual success@1, success@5, and MRR@10 separately for Russian and English, with 14 queries in each denominator. Failed and missing queries score zero; they are not removed from the denominator. Top-ten rankings support truncated MRR@10 only. Text queries and held-out queries are not evaluated by that run.

The provisional prototype target is at least 80% success@5 for straightforward held-out visual queries and text queries. There are only six held-out scenarios per kind, so a few failures change the percentage substantially. Russian and English versions of one scenario are related observations, not independent evidence.

An unlisted image may still be relevant. Review apparent failures and document legitimate missing labels before interpreting results; preserve original labels and record corrections instead of silently changing them to favor a model. This dataset cannot establish recall over the user's entire library.
