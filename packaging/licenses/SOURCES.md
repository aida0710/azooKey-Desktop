# Bundled components

The build copies the license and notice files from its resolved SwiftPM
checkouts, including the converter, dictionary and their dependencies.
The Linux package also carries the Swift distribution's runtime license.

- llama.cpp / ggml: azooKey fork, revision
  `10131b23ee0dbd9d03dfc618cec9fe3402919277`, MIT.
  <https://github.com/azooKey/llama.cpp/blob/10131b23ee0dbd9d03dfc618cec9fe3402919277/LICENSE>
- marisa-trie, included by SwiftyMarisa: BSD 2-clause option.
  <https://github.com/s-yata/marisa-trie/blob/master/COPYING.md>
- Zenzai v3.2 small Q5_K_M: Apache-2.0 according to its model card.
  <https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf>
  The Apache license text is included alongside this file.
- Base N-gram data: <https://huggingface.co/Miwa-Keita/base_n5_lm>.
  This is the same submodule and pinned content used by upstream. Its published
  repository has no separate license metadata; this file does not assign one.

Model revisions and hashes are verified by `Tools/fetch-models.py` against
the repository's pinned submodules, before packaging.
