meta:
  id: auth
  title: GET /authors response
  endian: be
  imports:
    - postilla_str
doc: |
  Every author, ascending by id. Author names aren't translated.
  See specification.md, `GET /genres`, `GET /tags`, `GET /authors`, `GET /languages`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: AUTH
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
        doc: Author id
      - id: name
        type: postilla_str
        doc: Author name
