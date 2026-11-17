meta:
  id: hedr
  title: PUT /drafts/{draft_id}/header request
  endian: be
  imports:
    - postilla_str
    - postilla_enums
doc: |
  Replaces a draft's story-level fields; the title and subtitle are edited through
  `PUT /drafts/{draft_id}/translation`. The server also rejects with 400, beyond what this
  file checks: any `str` that isn't valid UTF-8; an empty genre or license; a license that
  isn't ASCII; `work` empty but `part` not 0 (or the reverse); an empty or repeated tag;
  `adapted` 1 with an empty author; any bytes after `license`; and an unknown genre, tag or
  author. A `revision` that isn't the draft's gets a 409.
  See specification.md, `PUT /drafts/<id>/header`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: HEDR
  - id: version
    type: u1
    valid: 1
  - id: revision
    type: u4
    doc: The draft revision this edit is based on
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
    doc: An author.id, or empty
  - id: adapted
    type: u1
    valid:
      max: 1
  - id: license
    type: postilla_str
