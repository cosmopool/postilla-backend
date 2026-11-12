meta:
  id: postilla_enums
  title: Enums shared by the backend formats
doc: |
  Imported by the other formats for their `state` and `level` fields. Has no fields of its own.
enums:
  state:
    0: none # only in `failed_step`, when the draft isn't failed
    1: moderating
    2: rejected
    3: translating
    4: review
    5: narrating
    6: publishing
    7: published
    8: failed
    9: discarded
  level:
    1: a1
    2: a2
    3: b1
    4: b2
