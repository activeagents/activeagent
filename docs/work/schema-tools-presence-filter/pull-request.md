# Schema tools presence filter — pull request

#718 against `main`: `feat/schema-tools-presence-filter`.

- **What:** `{"present": false}` / `{"present": true}` on any SchemaTools filter, offered in the
  schema on nullable date, time and number columns.
- **Tests:** 7 new in `test/schema_tools_test.rb` (null, not null, with a bound and an equality
  filter, string operands, a rejected operand, a string column and an enum, where it is offered),
  plus the advertised-operators test updated. 64 SchemaTools tests and 64 engine/generator
  schema-tools tests green; RuboCop clean.
- **Upgrade:** none. Existing filters behave as before; the schema gains one boolean property in
  the range object of nullable columns.
