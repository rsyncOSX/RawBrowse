# GitHub AI model publication

RawBrowse downloads only DataComp CLIP and Meta SAM 3 from https://github.com/rsyncOSX/AI-models. The repository does not need Apple asset packs, an app group, or a downloader extension.

Publish `manifest.json` on the repository's `main` branch. RawBrowse reads:

`https://raw.githubusercontent.com/rsyncOSX/AI-models/main/manifest.json`

Use `manifest.template.json` as a schema example, not a live manifest. Replace every placeholder and list **every file** in each converted Core AI bundle, including model weights, configuration, tokenizer resources, and required notices. Paths are relative to the model's root, with no enclosing `Models/CLIP-DataComp` or `Models/SAM3` directory. Model IDs must be `clip-datacomp` and `sam3`.

Store large files as GitHub release assets. File URLs must use HTTPS and either `github.com/rsyncOSX/AI-models/releases/download/…` or `raw.githubusercontent.com/rsyncOSX/AI-models/…`. Pin release tags or commit revisions. Do not use Git LFS pointer URLs as model downloads.

For each file record its exact `byteCount` and lowercase `sha256` (`shasum -a 256 FILE`). Publish all files before the manifest. RawBrowse verifies each download, stages the complete model, and then installs it in its own Application Support directory. Failed or cancelled downloads do not install partial models. Installed models remain available offline.

Include the applicable licence and notices from `Notices/CLIP-DataComp` and `Notices/SAM3`. RawBrowse retains verified SAM licence acceptance before downloads. Historical provenance files refer to previous Apple archives; their archive hashes are not the hashes of individual GitHub files.

After publishing, validate both complete model bundles in RawBrowse, including CLIP indexing/search and SAM 3 subject review. Existing installed models are reused; remove and download again to adopt a newer model publication.
