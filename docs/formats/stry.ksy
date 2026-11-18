meta:
  id: stry
  title: POST /stories request
  endian: be
doc: |
  Publishes or republishes every translation of one story, whose files are already in R2.
  `22 + 40 × lang_count` bytes. The server also rejects with 400, beyond what this file
  checks: a body of any other length, a `lang` that isn't non-empty ASCII followed only by
  zero bytes, a repeated `lang`, no `it` (the original), and a `lang` not in `language`.
  A removed story, or a published translation the body doesn't carry, gets a 409. See specification.md, `POST /stories`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: STRY
  - id: version
    type: u1
    valid: 1
  - id: id
    size: 16
    doc: Story UUID, its 32 hex digits as bytes in written order
  - id: lang_count
    type: u1
    valid:
      min: 1
  - id: translations
    type: translation
    repeat: expr
    repeat-expr: lang_count
types:
  translation:
    seq:
      - id: lang
        type: strz
        size: 8
        encoding: ASCII
        doc: The translation's language, a BCP 47 tag zero-padded to 8 bytes
      - id: sha256
        size: 32
        doc: sha256 of the translation's .tilla, before gzip
