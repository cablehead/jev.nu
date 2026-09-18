# jev

Nushell wrapper for the TypeSafe System One API. Jev returns typed decisions with
calibrated probabilities instead of text, so code can branch on the answer.

README.md is the tutorial: the concepts, then a worked pipeline. Read it first.

The key comes from `$env.TYPESAFE_API_KEY`. The default model comes from
`$env.JEV_MODEL` (`jev-latest` when unset), and `$env.JEV_BASE_URL` overrides the
endpoint for testing.

## LLM Usage

Run commands via `nu -c 'use /root/jev/jev; jev <command>'`. Use the full absolute
path to the module directory. The examples below assume the checkout is at
`/root/jev`; substitute your own path.

### Build questions

Three question types. Each builder returns a record and sends nothing.

```bash
nu -c 'use /root/jev/jev; jev noul "Does the message report a bug?"'
nu -c 'use /root/jev/jev; jev noul "Is this urgent?" --yes "Time-sensitive" --no "No urgency"'
nu -c 'use /root/jev/jev; jev choice "Which team?" {billing: "Refunds", technical: "Outages", sales: null}'
nu -c 'use /root/jev/jev; jev score "How frustrated?" ["Calm" "Frustrated" "Very angry"]'
```

A choice takes 2 to 255 options, each mapped to a description or to null. A score
takes 2 to 10 levels, lowest first, and answers with a weighted position that can
land between two of them. A noul answers with the probability of yes and carries
no confidence.

Instructions and every description take a string, a record, or a list. Reach for
structure when two options blur: `{what: "...", not_for: "...", examples: [...]}`.

Raw question records work too. `jev ask` runs the same checks on them.

### Ask

One state comes from the pipeline, as a string, record, or list. A list is one
state, not many.

```bash
nu -c 'use /root/jev/jev;
  "Help! My payouts have been failing for 3 days." | jev ask {
    team: (jev choice "Which team should handle this?" {billing: null, technical: null})
    urgent: (jev noul "Does this convey urgency?")
  }'
```

Flags:

- `--model (-m)`: model or alias. Pin a version such as `jev-1.13.0` once thresholds are tuned.
- `--full (-f)`: return the whole response, with the model version and the token usage.
- `--dry-run`: return the request body and send nothing.
- `--max-retries`: retries on 429 and 529, honoring `retry-after`. Default 3.
- `--timeout`: per attempt. Default 2min.

To judge each row of a table, let `insert` run `jev ask` per row. The closure
gets the row as `$in`, so select the fields the questions need:

```bash
nu -c 'use /root/jev/jev;
  open tickets.json
  | insert jev { select subject body | jev ask $questions }
  | where jev.urgent.noul > 0.8'
```

Wrap it in `par-each --keep-order {|row| $row | insert jev { ... } }` to send the
requests together. Twelve rows measured 0.4 seconds against 4.

### Models

```bash
nu -c 'use /root/jev/jev; jev models'
```

## Design notes

Every question in a request is evaluated against the state in parallel, and only
input tokens are billed. Batching 13 questions into one call measures 12x cheaper
and 10x faster than 13 calls. So ask everything the code might need in one call,
including questions whose answer only matters for some inputs, and drop the ones
you do not use.

Ask for a judgment a knowledgeable person makes in a second. A judgment that
depends on several things gets split into one question per thing, combined with
weights in code. Divide a score by its top level number before weighting it. Keep
the questions and the thresholds in one record so a human can review them without
spelunking.

Confidence is derived from the probability distribution and rides on choice and
score answers. Gate on it by stakes: a wrong read-only answer is recoverable, a
wrong destructive one is not. Answers move a little between identical runs, so
leave room around a threshold.

Jev is weak at arithmetic, counting, and date math. Do those in code and ask only
for the judgment. Send only the state a question needs: unrelated detail costs
accuracy. See https://docs.typesafe.ai/model-jaggedness/jev-1.13.

The module validates only what the API documents, plus the two shapes the API
accepts and answers with nonsense: a one-option choice and a one-level score.
Check a new rule against the live API before adding it. A rule stricter than the
API blocks legal requests.

Read the API reference at https://docs.typesafe.ai/api and the cookbooks at
https://docs.typesafe.ai/cookbooks.

## Tests

```bash
nu tests/run.nu
```

Nothing in the suite reaches TypeSafe. It has two parts:

- Every `@example` with a `--result` runs as a test. The builders are pure, so
  their examples cover the happy paths. Add an example with its result whenever
  you add a builder or change what one returns.
- The checks in `tests/run.nu` cover the errors, and `jev ask` on the wire against
  `tests/stub.nu`, a stand-in for the API served by http-nu. The `model` of a
  request picks the stub's behavior (`busy`, `overloaded`, `invalid`). Without
  http-nu on the PATH these are skipped.

In an http-nu handler, do not `return` a response early: the returned value loses
the metadata that carries the status, and a 401 goes out as a 200.
