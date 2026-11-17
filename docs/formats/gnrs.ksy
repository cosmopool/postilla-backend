meta:
  id: gnrs
  title: GET /genres response
  endian: be
  imports:
    - postilla_str
doc: |
  Every genre, ascending by id, with its name in each language.
  See specification.md, `GET /genres`, `GET /tags`, `GET /authors`, `GET /languages`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: GNRS
  - id: version
    type: u1
    valid: 1
  - id: count
    type: u2
  - id: records
    type: record
    repeat: expr
    repeat-expr: count
types:
  record:
    seq:
      - id: id
        type: postilla_str
        doc: Genre id
      - id: it
        type: postilla_str
        doc: Italian name
      - id: pt_br
        type: postilla_str
        doc: Brazilian Portuguese name
      - id: en
        type: postilla_str
        doc: English name
