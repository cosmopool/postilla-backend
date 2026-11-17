meta:
  id: u32_body
  title: Bare u32 response
  endian: be
doc: |
  The 4-byte body of `POST /drafts`, `POST /stories/{id}/edit` and
  `POST /stories/{id}/narrate`: the new draft id. No magic or version.
seq:
  - id: value
    type: u4
