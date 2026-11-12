meta:
  id: drft
  title: GET /drafts/{draft_id} response
  endian: be
  imports:
    - postilla_str
    - postilla_enums
doc: |
  A draft's state, error, moderation result and sentences.
  See specification.md, `GET /drafts/<id>`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: DRFT
  - id: version
    type: u1
    valid: 1
  - id: draft_id
    type: u4
  - id: id
    size: 16
    doc: Story UUID
  - id: state
    type: u1
    enum: postilla_enums::state
  - id: failed_step
    type: u1
    enum: postilla_enums::state
    doc: The state that failed when `state` is failed; none (0) otherwise
  - id: attempts
    type: u1
    doc: Tries made by the current or failed step
  - id: error
    type: postilla_str
    doc: Stored error; empty when there is none
  - id: moderation
    type: moderation
  - id: title
    type: postilla_str
  - id: subtitle
    type: postilla_str
  - id: level
    type: u1
    enum: postilla_enums::level
  - id: genre
    type: postilla_str
  - id: work
    type: postilla_str
  - id: part
    type: u2
  - id: paragraph_count
    type: u2
  - id: paragraphs
    type: paragraph
    repeat: expr
    repeat-expr: paragraph_count
types:
  moderation:
    doc: Jev's probabilities in thousandths (0 to 1000); all 0 before moderation.
    seq:
      - id: none
        type: u2
      - id: homophobic
        type: u2
      - id: racist
        type: u2
      - id: sexist
        type: u2
      - id: religious
        type: u2
      - id: other_hate
        type: u2
  paragraph:
    seq:
      - id: sentence_count
        type: u2
      - id: sentences
        type: sentence
        repeat: expr
        repeat-expr: sentence_count
  sentence:
    seq:
      - id: it
        type: postilla_str
        doc: Italian sentence
      - id: pt
        type: postilla_str
        doc: Portuguese sentence; empty before translation
