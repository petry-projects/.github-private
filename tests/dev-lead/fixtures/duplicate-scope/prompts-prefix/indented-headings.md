# Fixture for indented heading duplicates

Regular heading at column 0:

## Section A

Content for section A

  ## Section A

This is a duplicate heading with 2 leading spaces (valid per Markdown spec).
Should be detected as a duplicate.

   ## Section B

Heading with 3 leading spaces.

   ## Section B

Duplicate heading with same indentation.
