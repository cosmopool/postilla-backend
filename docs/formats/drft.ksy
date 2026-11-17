meta:
  id: drft
  title: GET /drafts/{draft_id} response
  endian: be
  imports:
    - postilla_str
    - postilla_enums
doc: |
  A draft's status, header, its title and subtitle in every translated language, and its
  sentences: each Italian sentence followed by its translations, in the order of
  `languages`. See specification.md, `GET /drafts/<id>`.
doc-ref: ../specification.md
seq:
  - id: magic
    contents: DRFT
  - id: version
    type: u1
    valid: 1
  - id: draft_id
    type: u4
  - id: id
    size: 16
    doc: Story UUID
  - id: state
    type: u1
    enum: postilla_enums::state
  - id: kind
    type: u1
    enum: postilla_enums::kind
  - id: failed_step
    type: u1
    enum: postilla_enums::state
    doc: The state that failed when `state` is failed; none (0) otherwise
  - id: attempts
    type: u1
    doc: Tries made by the current or failed step
  - id: error
    type: postilla_str
    doc: Stored error; empty when there is none
  - id: moderation
    type: moderation
  - id: revision
    type: u4
    doc: Current revision
  - id: title
    type: postilla_str
    doc: Italian title
  - id: subtitle
    type: postilla_str
    doc: Italian subtitle
  - id: level
    type: u1
    enum: postilla_enums::level
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
  - id: lang_count
    type: u1
    doc: Number of translated languages that follow
  - id: languages
    type: language
    repeat: expr
    repeat-expr: lang_count
    doc: Translated languages, ascending by id (the original has its own fields)
  - id: paragraph_count
    type: u2
  - id: paragraphs
    type: paragraph
    repeat: expr
    repeat-expr: paragraph_count
types:
  moderation:
    doc: Jev's probabilities in thousandths (0 to 1000); all 0 before moderation.
    seq:
      - id: none
        type: u2
      - id: homophobic
        type: u2
      - id: racist
        type: u2
      - id: sexist
        type: u2
      - id: religious
        type: u2
      - id: other_hate
        type: u2
  language:
    seq:
      - id: lang
        type: strz
        size: 8
        encoding: ASCII
        doc: A BCP 47 tag zero-padded to 8 bytes
      - id: title
        type: postilla_str
        doc: Title in that language; empty before translation
      - id: subtitle
        type: postilla_str
        doc: Subtitle in that language; empty before translation
  paragraph:
    doc: Sentence counts follow the Italian.
    seq:
      - id: sentence_count
        type: u2
      - id: sentences
        type: sentence
        repeat: expr
        repeat-expr: sentence_count
  sentence:
    seq:
      - id: it
        type: postilla_str
        doc: Italian sentence
      - id: translations
        type: postilla_str
        repeat: expr
        repeat-expr: _root.lang_count
        doc: |
          One sentence per entry of `languages`, in that order; empty where that language
          isn't translated yet
