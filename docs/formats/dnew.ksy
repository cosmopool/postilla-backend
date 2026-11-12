meta:
  id: dnew
  title: POST /drafts request
  endian: be
  imports:
    - postilla_str
    - postilla_enums
doc: |
  Starts a draft from the story's header and its Italian sentences.
  The server also rejects, beyond what this file checks: empty title, subtitle, genre or
  sentence; `work` empty but `part` not 0 (or the reverse); more than 20,000 characters;
  and any bytes after the last paragraph. See specification.md, `POST /drafts`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: DNEW
  - id: version
    type: u1
    valid: 1
  - id: id
    size: 16
    doc: Story UUID
  - id: title
    type: postilla_str
  - id: subtitle
    type: postilla_str
  - id: level
    type: u1
    enum: postilla_enums::level
    valid:
      in-enum: true
  - id: genre
    type: postilla_str
    doc: A genre.id
  - id: work
    type: postilla_str
    doc: Work name; empty outside a work
  - id: part
    type: u2
    doc: Part of the work; 0 outside a work
  - id: paragraph_count
    type: u2
    valid:
      min: 1
  - id: paragraphs
    type: paragraph
    repeat: expr
    repeat-expr: paragraph_count
types:
  paragraph:
    seq:
      - id: sentence_count
        type: u2
        valid:
          min: 1
      - id: sentences
        type: postilla_str
        repeat: expr
        repeat-expr: sentence_count
        doc: Italian sentences, in reading order
