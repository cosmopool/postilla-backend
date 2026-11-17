meta:
  id: publ
  title: GET /published response
  endian: be
  imports:
    - postilla_str
    - postilla_enums
doc: |
  Every story that has been published, removed ones included, ascending by id, with each
  translation's title. See specification.md, `GET /published`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: PUBL
  - id: version
    type: u1
    valid: 1
  - id: count
    type: u4
  - id: stories
    type: story
    repeat: expr
    repeat-expr: count
types:
  story:
    seq:
      - id: id
        size: 16
        doc: Story UUID
      - id: change
        type: u1
        enum: postilla_enums::change
      - id: level
        type: u1
        enum: postilla_enums::level
      - id: genre
        type: postilla_str
        doc: Genre id
      - id: lang_count
        type: u1
      - id: translations
        type: translation
        repeat: expr
        repeat-expr: lang_count
        doc: The original included, in `language` order (original first, then ascending by id)
  translation:
    seq:
      - id: lang
        type: strz
        size: 8
        encoding: ASCII
        doc: A BCP 47 tag zero-padded to 8 bytes
      - id: title
        type: postilla_str
