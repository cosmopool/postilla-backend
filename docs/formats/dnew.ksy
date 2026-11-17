meta:
  id: dnew
  title: POST /drafts request
  endian: be
  imports:
    - postilla_str
    - postilla_enums
doc: |
  Starts a `new` draft from the story's header and its Italian sentences.
  The server also rejects with 400, beyond what this file checks: any `str` that isn't
  valid UTF-8; an empty title, subtitle, genre, license or sentence; a license that isn't
  ASCII; `work` empty but `part` not 0 (or the reverse); an empty or repeated tag;
  `adapted` 1 with an empty author; more than 20,000 characters; any bytes after the last
  paragraph; and an unknown genre, tag or author. A removed story id, or a story with a
  draft in progress, gets a 409. See specification.md, `POST /drafts`.
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
  - id: tag_count
    type: u2
  - id: tags
    type: postilla_str
    repeat: expr
    repeat-expr: tag_count
    doc: tag.ids
  - id: work
    type: postilla_str
    doc: Work name; empty outside a work
  - id: part
    type: u2
    doc: Part of the work; 0 outside a work
  - id: author
    type: postilla_str
    doc: An author.id; empty for a story written for Postilla
  - id: adapted
    type: u1
    valid:
      max: 1
    doc: 1 when adapted from the author's work, 0 otherwise
  - id: license
    type: postilla_str
    doc: SPDX id, public-domain, or LicenseRef-Postilla
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
