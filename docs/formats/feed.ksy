meta:
  id: feed
  title: GET /stories response
  endian: be
  imports:
    - postilla_enums
doc: |
  Translations in the requested languages published, corrected or removed after the
  requested cursor, ascending by cursor. Which cursor the app sends next time is in
  app-handoff.md, §2 Syncing. Removed translations are listed like any other, `since=0`
  included.
  See specification.md, `GET /stories`.
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
    doc: 61 bytes per translation.
    seq:
      - id: id
        size: 16
        doc: Story UUID, its 32 hex digits as bytes in written order
      - id: lang
        type: strz
        size: 8
        encoding: ASCII
        doc: The translation's language, a BCP 47 tag zero-padded to 8 bytes
      - id: change
        type: u1
        enum: postilla_enums::change
        valid:
          in-enum: true
        doc: What happened last to that translation
      - id: sha256
        size: 32
        doc: sha256 of the translation's .tilla, before gzip; all zero when removed
      - id: cursor
        type: u4
