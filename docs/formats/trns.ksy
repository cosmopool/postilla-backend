meta:
  id: trns
  title: PUT /drafts/{draft_id}/translation request
  endian: be
  imports:
    - postilla_str
doc: |
  Replaces one language's title, subtitle and sentences in a draft. The server also
  rejects, beyond what this file checks: a `lang` that is neither the draft's original nor
  one of its translated languages, a `paragraph_count` that isn't the draft's, a
  translation whose sentence count differs from the Italian's in any paragraph, an empty
  title, subtitle or sentence, or any bytes after the last paragraph (400); Italian on a
  draft that isn't an `edit` draft, a `revision` that isn't the draft's, or a draft not at `review` (409). On an
  `edit` draft the Italian may change a paragraph's sentence count.
  See specification.md, `PUT /drafts/<id>/translation`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: TRNS
  - id: version
    type: u1
    valid: 1
  - id: lang
    type: strz
    size: 8
    encoding: ASCII
    doc: The language being replaced, a BCP 47 tag zero-padded to 8 bytes
  - id: revision
    type: u4
    doc: The draft revision this edit is based on
  - id: title
    type: postilla_str
  - id: subtitle
    type: postilla_str
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
        doc: Sentences in `lang`, in reading order
