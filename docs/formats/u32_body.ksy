meta:
  id: u32_body
  title: Bare u32 response
  endian: be
doc: |
  The 4-byte body of `POST /stories` (the story's cursor) and of `POST /drafts` and
  `POST /stories/{id}/narrate` (the new draft id). No magic or version.
seq:
  - id: value
    type: u4
