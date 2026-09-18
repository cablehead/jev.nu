<h1>
<p align="center">
  jev
</h1>
  <p align="center">
    A <a href="https://www.nushell.sh">Nushell</a> module for <a href="https://typesafe.ai">TypeSafe</a>'s System One API: typed decisions with calibrated probabilities, for code that needs to branch on a judgement.
    <br />
    <a href="#install">Install</a>
    ·
    <a href="#reference">Reference</a>
    ·
    <a href="https://docs.typesafe.ai/api">API docs</a>
  </p>
</p>

---

<!-- BEGIN mktoc -->

- [Install](#install)
- [Reference](#reference)
  - [Ask: hello world](#ask-hello-world)
  - [Configuration](#configuration)
  - [Questions](#questions)
    - [`jev noul` - yes/no](#jev-noul---yesno)
    - [`jev choice` - pick one](#jev-choice---pick-one)
    - [`jev score` - rate on a scale](#jev-score---rate-on-a-scale)
  - [Ask everything at once](#ask-everything-at-once)
  - [Confidence](#confidence)
  - [Return modes](#return-modes)
  - [Structured state](#structured-state)
  - [Reviewing a request before sending it](#reviewing-a-request-before-sending-it)
  - [Models](#models)
  - [Errors and retries](#errors-and-retries)
  - [Validation](#validation)
- [Commands](#commands)
- [Tests](#tests)

<!-- END mktoc -->

## Install

The module is plain Nushell, with no build step and no dependencies. Clone it
and point `use` at the module directory:

```nushell
$ git clone https://github.com/cablehead/jev.nu ~/src/jev.nu
$ use ~/src/jev.nu/jev
$ jev
╭───┬────────────┬──────────────────────────────────────────╮
│ # │    name    │               description                │
├───┼────────────┼──────────────────────────────────────────┤
│ 0 │ jev ask    │ Ask a batch of questions about one state │
│ 1 │ jev choice │ Build a pick-one question                │
│ 2 │ jev models │ List the models this account can send    │
│ 3 │ jev noul   │ Build a yes/no question                  │
│ 4 │ jev score  │ Build a rate-it-on-a-scale question      │
╰───┴────────────┴──────────────────────────────────────────╯
```

Add it to `config.nu` to have it always loaded. Get a key from
[console.typesafe.ai](https://console.typesafe.ai/keys) and export it:

```nushell
$env.TYPESAFE_API_KEY = "apikey_..."
```

## Reference

### Ask: hello world

State goes in on the pipeline. Questions come in as a record, and the answers
come back under the same keys.

```nushell
$ "Help! My payouts have been failing for 3 days." | jev ask {
    urgent: (jev noul "Does this convey urgency?")
  } | get urgent.noul
0.95
```

No text, no parsing. `0.95` is the model's probability that the answer is yes.
Answers nest, so `to nuon` is the quickest way to see a whole one at the prompt.

### Configuration

| Variable             | Meaning                      | Default                      |
| -------------------- | ---------------------------- | ---------------------------- |
| `TYPESAFE_API_KEY`   | API key. Required.           | none                         |
| `JEV_MODEL`          | Default model or alias       | `jev-latest`                 |
| `JEV_BASE_URL`       | Endpoint, for testing        | `https://api.typesafe.ai/v1` |

### Questions

Three question types, three builders. Each returns a record and sends nothing,
so you can hold them in a constant and review them in one place.

#### `jev noul` - yes/no

Answers with the probability that the answer is yes, from 0 to 1. Near 0.5 means
the model splits its bet, not that the truth is in the middle. There is no
confidence on a noul: the value is already the certainty.

```nushell
$ jev noul "The message reports a bug"
$ jev noul "Does this convey urgency?" --yes "Explicitly time-sensitive" --no "No urgency expressed"
```

`--yes` and `--no` describe what each side means. They land in the request as
`criteria.true` and `criteria.false`.

#### `jev choice` - pick one

For an answer that is one of a known set with no order between them. Map each
option to a description, or to `null` when the name says enough.

```nushell
$ "Help! My payouts have been failing for 3 days." | jev ask {
    dept: (jev choice "Which team should handle this?" {
      billing: "Payments, invoicing, refunds"
      technical: "Bugs, outages, integrations"
      sales: null
    })
  } | get dept | to nuon
{type: choice, choice: billing, confidence: 0.79, probabilities: {technical: 0.14, billing: 0.86, sales: 0.0}}
```

Add an `other` option when the list might not cover every input.

#### `jev score` - rate on a scale

For an answer that falls on a spectrum you can describe. Levels are ordered,
lowest first.

```nushell
$ "Help! My payouts have been failing for 3 days." | jev ask {
    frustration: (jev score "How frustrated is the customer?" ["Calm" "Frustrated" "Very angry"])
  } | get frustration | to nuon
{type: score, score: 1.04, confidence: 0.94, legend: {"0": Calm, "1": Frustrated, "2": "Very angry"}, probabilities: {"0": 0.0, "1": 0.96, "2": 0.04}}
```

The score is probability-weighted, so it lands between levels. Read it as a
number and threshold it, not as an index.

### Ask everything at once

Every question in a request is evaluated against the state in parallel, and only
input tokens are billed. Batching 13 questions into one call measures 12x cheaper
and 10x faster than 13 calls, with the same answers. So ask everything the code
might need, including questions whose answer only matters for some inputs, and
ignore the ones you do not use.

```nushell
$ let questions = {
    dept: (jev choice "Which team should handle this?" {billing: null, technical: null, sales: null})
    urgent: (jev noul "Does this convey urgency?")
    frustration: (jev score "How frustrated is the customer?" ["Calm" "Frustrated" "Very angry"])
  }

$ let a = "Help! My payouts have been failing for 3 days." | jev ask $questions
$ if $a.urgent.noul > 0.8 and $a.frustration.score > 1.5 { page-someone } else { queue $a.dept.choice }
```

A judgement that depends on several things gets split into one question per
thing, combined with weights you keep in code. When the result does not match
what your team would decide, change the weights, not a prompt.

### Confidence

Choice and score answers carry a `confidence` from 0 to 1, derived from how
peaked the probability distribution is. Gate on it by stakes: a wrong read-only
answer is recoverable, a wrong destructive one is not.

```nushell
match $a.dept {
  {confidence: $c} if $c < 0.5 => (route-to-human $ticket)
  {choice: "billing", confidence: $c} if $c > 0.9 => (auto-refund $ticket)
  {choice: $team} => (queue $team)
}
```

The full `probabilities` map is always in the answer, so you are free to compute
your own measure instead.

### Return modes

`--return answers` is the default. `full` gives the envelope, which is where the
resolved model id and the token usage live:

```nushell
$ $ticket | jev ask --return full $questions | select model usage | to nuon
{model: "jev-1.13.0", usage: {input_tokens: 414, output_tokens: 70}}
```

An alias moves when a release ships, so log `model` if you have tuned thresholds
against a version.

`merged` adds an `answers` column to a record state, which is what keeps a table
a table:

```nushell
$ open tickets.json | each {|t| $t | jev ask --return merged $questions }
  | select id answers.dept.choice answers.dept.confidence answers.urgent.noul
╭───┬────┬─────────────────────┬─────────────────────────┬─────────────────────╮
│ # │ id │ answers.dept.choice │ answers.dept.confidence │ answers.urgent.noul │
├───┼────┼─────────────────────┼─────────────────────────┼─────────────────────┤
│ 0 │  1 │ billing             │                    1.00 │                0.63 │
│ 1 │  2 │ technical           │                    1.00 │                0.89 │
╰───┴────┴─────────────────────┴─────────────────────────┴─────────────────────╯
```

From there it is ordinary Nushell: `where answers.urgent.noul > 0.8`,
`sort-by answers.frustration.score`.

### Structured state

State can be a record or a list, not just a string. When a question is about one
part of it, name that part in the instructions with a dot path in backticks.

```nushell
$ {
    ticket: {subject: "Duplicate charge", body: "I was charged twice for order A-104."}
    order: {id: "A-104", charges: [{amount_usd: 49}, {amount_usd: 49}]}
    refund_policy: "Duplicate charges are eligible for a refund."
  } | jev ask {
    requested: (jev noul "Does `ticket.body` request a refund?")
    supported: (jev noul "Does `refund_policy` support a refund, given `order.charges`?")
  }
```

### Reviewing a request before sending it

`--payload` returns the body instead of sending it. The questions and the
thresholds are the part a human needs to read, so make them easy to look at.

```nushell
$ "a ticket" | jev ask --payload {urgent: (jev noul "Is this urgent?")} | to nuon
{state: "a ticket", model: "jev-latest", questions: {urgent: {type: noul, instructions: "Is this urgent?"}}}
```

### Models

```nushell
$ jev models
╭───┬─────────────┬────────────┬───────────────────────────────────────────────╮
│ # │    name     │  released  │                  description                  │
├───┼─────────────┼────────────┼───────────────────────────────────────────────┤
│ 0 │ jev-latest  │ a week ago │ The latest iteration of TypeSafe's System One │
│   │             │            │  Model: Jev                                   │
│ 1 │ jev-preview │ a week ago │ A preview version of `jev-latest`: should be  │
│   │             │            │ better in most ways                           │
╰───┴─────────────┴────────────┴───────────────────────────────────────────────╯
```

`--model` completes from this list, cached in `$nu.cache-dir` for a day. A
versioned id like `jev-1.13.0` is accepted whether or not it appears.

### Errors and retries

429 and 529 are retried with backoff, honoring `retry-after` when the response
carries one, three times by default. Everything else fails with the reason and
the request id:

```nushell
$ $ticket | jev ask $questions
Error: nu::shell::error

  x typesafe 401: Cannot authenticate with the server. Please check your API key and try again.
  help: Check $env.TYPESAFE_API_KEY. Keys are issued at https://console.typesafe.ai/keys
        request id: req_01a0b62941e07e429e4ae0cc556693dd
```

### Validation

The builders check the shape of a question before it costs a round trip, and the
error points at your source:

```nushell
$ jev choice "Which team?" {billing: null}
Error: nu::shell::error

  x too few options
   ,-[entry #1:1:26]
 1 │ jev choice "Which team?" {billing: null}
   ·                          ───────┬───────
   ·                                 ╰── 1 of the 2 options a choice needs
   ╰────
  help: A choice needs at least two options. For a yes/no judgment use `jev noul`.
```

> [!NOTE]
> A one-level score is worth catching here, because the API accepts it and
> answers `score: 0.0, confidence: 1.0`. That looks like a strong answer and
> means nothing.

Raw question records work too. The builders only add the checking.

```nushell
$ $ticket | jev ask {urgent: {type: "noul", instructions: "Is this urgent?"}}
```

## Commands

```nushell
jev noul [
  instructions: any           # string, record, or list
  --yes: string               # what a yes (near 1) means
  --no: string                # what a no (near 0) means
]: nothing -> record

jev choice [
  instructions: any
  criteria: record            # option -> description, or null
]: nothing -> record

jev score [
  instructions: any
  criteria: list              # ordered levels, lowest first
]: nothing -> record

jev ask [
  questions: record           # question id -> question
  --model (-m): string        # default $env.JEV_MODEL
  --return (-r): string       # answers (default), full, merged
  --payload                   # return the request body, send nothing
  --max-retries: int          # on 429 and 529, default 3
  --timeout: duration         # per attempt, default 2min
]: [string -> any, record -> any, list -> any]

jev models []: nothing -> table
```

## Tests

```bash
$ nu tests/examples.nu
╭───┬────────────┬─────────────────────────────────────────────────┬──────╮
│ # │    name    │                     example                     │  ok  │
├───┼────────────┼─────────────────────────────────────────────────┼──────┤
│ 0 │ jev ask    │ review the request without sending it           │ true │
│ 1 │ jev choice │ route a ticket, describing two of three options │ true │
│ 2 │ jev noul   │ a bare yes/no question                          │ true │
│ 3 │ jev noul   │ spell out what each side means                  │ true │
│ 4 │ jev score  │ rate customer frustration on three levels       │ true │
╰───┴────────────┴─────────────────────────────────────────────────┴──────╯
5 passed, 3 skipped
```

Every `@example` that records a `--result` runs as a test. The builders are pure,
so their examples are the suite. Examples that reach the API record no result and
are skipped: they cost money and their answers move with the model.
