meta:
  id: trns
  title: PUT /drafts/{draft_id}/translation request
  endian: be
  imports:
    - postilla_str
doc: |
  Replaces a draft's Portuguese sentences. Every count must equal the draft's, and no
  sentence may be empty; the server checks both against the stored draft.
  See specification.md, `PUT /drafts/<id>/translation`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: TRNS
  - id: version
    type: u1
    valid: 1
  - id: paragraph_count
    type: u2
  - id: paragraphs
    type: paragraph
    repeat: expr
    repeat-expr: paragraph_count
types:
  paragraph:
    seq:
      - id: sentence_count
        type: u2
      - id: sentences
        type: postilla_str
        repeat: expr
        repeat-expr: sentence_count
        doc: Portuguese sentences, in reading order
