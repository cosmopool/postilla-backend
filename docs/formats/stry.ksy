meta:
  id: stry
  title: POST /stories request
  endian: be
doc: |
  Publishes or republishes a story whose files are already in R2. Always 54 bytes.
  See specification.md, `POST /stories`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: STRY
  - id: version
    type: u1
    valid: 1
  - id: id
    size: 16
    doc: Story UUID
  - id: sha256
    size: 32
    doc: sha256 of the .tilla.gz
  - id: has_opus
    type: u1
    valid:
      max: 1
    doc: 1 when the story has a .opus, 0 for a story without narration
