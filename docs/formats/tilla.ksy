meta:
  id: tilla
  title: One translation of a Postilla story (.tilla, before gzip)
  endian: be
  encoding: UTF-8
  imports:
    - postilla_str
doc: |
  See tilla.md. One file per translation; stored gzipped in R2 as
  stories/<id>/<lang>/<sha256>.tilla.gz.
seq:
  - id: magic
    contents: TILLA
  - id: version
    type: u1
    valid: 1
  - id: id
    size: 16
  - id: lang
    type: strz
    size: 8
    encoding: ASCII
  - id: original
    type: strz
    size: 8
    encoding: ASCII
  - id: title
    type: postilla_str
  - id: subtitle
    type: postilla_str
  - id: level
    type: u1
    doc: 1 A1, 2 A2, 3 B1, 4 B2, 5 C1, 6 C2
  - id: genre
    type: postilla_str
  - id: tag_count
    type: u2
  - id: tags
    type: postilla_str
    repeat: expr
    repeat-expr: tag_count
  - id: work
    type: postilla_str
  - id: part
    type: u2
  - id: author
    type: postilla_str
  - id: adapted
    type: u1
  - id: license
    type: postilla_str
  - id: words
    type: u2
  - id: band_words
    type: u2
    repeat: expr
    repeat-expr: 4
  - id: audio_ms
    type: u4
  - id: opus_sha256
    size: 32
  - id: opus_size
    type: u4
  - id: paragraph_count
    type: u2
  - id: paragraphs
    type: paragraph
    repeat: expr
    repeat-expr: paragraph_count
types:
  paragraph:
    seq:
      - id: sentence_count
        type: u2
      - id: sentences
        type: sentence
        repeat: expr
        repeat-expr: sentence_count
  sentence:
    seq:
      - id: text
        type: postilla_str
      - id: word_count
        type: u2
      - id: words
        type: word
        repeat: expr
        repeat-expr: word_count
      - id: start_ms
        type: u4
      - id: end_ms
        type: u4
  word:
    seq:
      - id: start
        type: u2
        doc: Byte offset in the sentence text
      - id: end
        type: u2
        doc: Byte offset just past the word
