meta:
  id: postilla_str
  title: Length-prefixed UTF-8 string
  endian: be
  encoding: UTF-8
doc: |
  `str` in specification.md: a u32 byte length, then that many bytes of UTF-8.
seq:
  - id: len
    type: u4
  - id: value
    type: str
    size: len
