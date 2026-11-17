# Schema tools presence filter — issues

## The gap

`permitted_filters!` drops a `nil` value as "no filter", which is right: models send `null` for
every optional parameter they leave out. But it leaves no way to ask for the records where a
column *is* null — tickets with no assignee, requests not yet approved, posts never published.
A host's instructions had to teach the model a sentinel range (`{"after": "2000-01-01"}` on a
timestamp) to mean "is set", and there was no sentinel at all for "is not set" on a foreign key.

## Decisions

| Question | Decision |
|---|---|
| Make `null` mean IS NULL? | No. It would turn every omitted optional parameter into a filter. |
| Operator name | `present`, a key inside the existing object form, beside `before`/`gte`. |
| Strings: does `""` count as empty? | No. `present` is NULL / NOT NULL everywhere; it is only *offered* on dates, times and numbers, where `""` cannot occur. |
| Where it is offered | In the range object of nullable range columns (dates, times, numbers, so foreign keys too). Not wrapped around every nullable string or enum, to keep the schema small. |
| Where it is accepted | Any filterable column, including an enum, which otherwise rejects an object. |
| Operands | `true`/`false` or their strings. Anything else is an error, never a guess. |

## Not done

- A blank-string-aware form for text columns (`present` meaning "not null and not empty").
- Offering `present` on nullable strings and enums in the schema.
