meta:
  id: postilla_enums
  title: Enums shared by the backend formats
doc: |
  Imported by the other formats for their `state`, `kind`, `change` and `level` fields.
  Has no fields of its own.
enums:
  state:
    0: none # only in `failed_step`, when the draft isn't failed
    1: moderating
    2: rejected
    3: translating
    4: review
    5: narrating
    6: listening
    7: publishing
    8: published
    9: failed
    10: discarded
  kind:
    1: new # POST /drafts, starts at moderating
    2: edit # POST /stories/<id>/edit, starts at review
    3: narrate # POST /stories/<id>/narrate, starts at narrating
  change:
    1: published # new or changed
    2: removed
  level:
    1: a1
    2: a2
    3: b1
    4: b2
    5: c1
    6: c2
