meta:
  id: dlst
  title: GET /drafts response
  endian: be
  imports:
    - postilla_str
    - postilla_enums
doc: |
  Drafts, newest first, optionally filtered by state. See specification.md, `GET /drafts`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: DLST
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
    seq:
      - id: draft_id
        type: u4
      - id: id
        size: 16
        doc: Story UUID
      - id: state
        type: u1
        enum: postilla_enums::state
      - id: title
        type: postilla_str
