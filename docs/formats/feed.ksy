meta:
  id: feed
  title: GET /stories response
  endian: be
doc: |
  Stories published after the requested cursor, ascending by cursor. The last record's
  `cursor` is the value the app sends next time. See specification.md, `GET /stories`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: FEED
  - id: version
    type: u1
    valid: 1
  - id: count
    type: u4
  - id: records
    type: record
    repeat: expr
    repeat-expr: count
types:
  record:
    doc: 52 bytes per story.
    seq:
      - id: id
        size: 16
        doc: Story UUID, its 32 hex digits as bytes in written order
      - id: sha256
        size: 32
        doc: sha256 of the story's .tilla.gz
      - id: cursor
        type: u4
