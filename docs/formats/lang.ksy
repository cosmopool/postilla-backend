meta:
  id: lang
  title: GET /languages response
  endian: be
  imports:
    - postilla_str
doc: |
  Every language, ascending by id.
  See specification.md, `GET /genres`, `GET /tags`, `GET /authors`, `GET /languages`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: LANG
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
        doc: Language id, a BCP 47 tag
      - id: name
        type: postilla_str
        doc: The language's own name
      - id: target
        type: u1
        valid:
          max: 1
        doc: 1 when the language can be a target (learned), 0 otherwise
      - id: translate
        type: u1
        valid:
          max: 1
        doc: 1 when stories are translated into it
