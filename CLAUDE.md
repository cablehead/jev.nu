# jev

Nushell wrapper for the TypeSafe System One API. Jev returns typed decisions with
calibrated probabilities instead of text, so code can branch on the answer.

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
nu -c 'use /root/jev/jev; jev noul "The message reports a bug"'
nu -c 'use /root/jev/jev; jev noul "Is this urgent?" --yes "Time-sensitive" --no "No urgency"'
nu -c 'use /root/jev/jev; jev choice "Which team?" {billing: "Refunds", technical: "Outages", sales: null}'
nu -c 'use /root/jev/jev; jev score "How frustrated?" ["Calm" "Frustrated" "Very angry"]'
```

A choice needs at least two options, mapping each to a description or to null. A
score takes levels in order, lowest first, and answers with a weighted position
that can land between two of them. A noul answers with the probability of yes and
carries no confidence.

Raw question records work too. The builders only add validation.

### Ask

State comes from the pipeline as a string, record, or list.

```bash
nu -c 'use /root/jev/jev;
  "Help! My payouts have been failing for 3 days." | jev ask {
    dept: (jev choice "Which team should handle this?" {billing: null, technical: null})
    urgent: (jev noul "Does this convey urgency?")
  }'
```

Flags:

- `--model (-m)`: model or alias, completed from `GET /v1/models` and cached for a day.
- `--return (-r)`: `answers` (default), `full` for the envelope with model and usage, `merged` to add an `answers` column to a record state.
- `--payload`: return the request body instead of sending it.
- `--max-retries`: retries on 429 and 529, honoring `retry-after`. Default 3.
- `--timeout`: per attempt. Default 2min.

`--return merged` is what keeps a table a table:

```bash
nu -c 'use /root/jev/jev;
  open tickets.json | each {|t| $t | jev ask --return merged $questions }
  | where answers.urgent.noul > 0.8'
```

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
weights in code. Keep the questions and the thresholds in one record so a human
can review them without spelunking.

Confidence is derived from the probability distribution and rides on choice and
score answers. Gate on it by stakes: a wrong read-only answer is recoverable, a
wrong destructive one is not.

Read the API reference at https://docs.typesafe.ai/api and the cookbooks at
https://docs.typesafe.ai/cookbooks.

## Tests

```bash
nu tests/examples.nu        # run the recorded @example results
nu tests/examples.nu -v     # also list the skipped network examples
```

The runner locates the module relative to itself, so it works from any checkout
and any working directory.

Every `@example` with a `--result` runs as a test. The builders are pure, so their
examples are the suite. Examples that reach the API record no result and are
skipped: they cost money and their answers move with the model. Add an example
with its result whenever you add a builder or change validation.
