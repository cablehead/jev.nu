# jev

A [Nushell](https://www.nushell.sh) module for jev, [TypeSafe](https://typesafe.ai)'s
model that answers questions with probabilities instead of text. Pipe in
content and ask questions about it. The answers are numbers, so you can filter
and sort on them.

```nushell
"Help! My payouts have been failing for 3 days." | jev ask {
    urgent: (jev noul "Does this convey urgency?")
} | get urgent.noul
# => 0.95
```

## Install

The module is a single Nushell file.

```nushell
git clone https://github.com/cablehead/jev.nu
use jev.nu/jev
$env.TYPESAFE_API_KEY = "apikey_..."   # from https://console.typesafe.ai/keys
```

Put the last two lines in `config.nu` to keep them.

## Tutorial

### 1. State, questions, answers

Jev reads text like an LLM but never writes any. You list the possible answers,
and it gives each one a probability. TypeSafe calls this a System One model. A
request has three parts:

| Jev calls it | What it is                                         | In this module                                                |
| ------------ | -------------------------------------------------- | ------------------------------------------------------------- |
| state        | The content to judge                               | What you pipe into `jev ask`                                  |
| questions    | What you want to know, each under an id you choose | A record built with `jev noul`, `jev choice` or `jev score`   |
| answers      | One answer per question                            | The record `jev ask` returns, under the same ids              |

In the example above the state is the customer's message, the one question has
the id `urgent`, and `0.95` is the probability that the answer is yes.

Jev is built for questions a person could answer at a glance, like "Does this
convey urgency?". For anything bigger, ask several small questions and combine
the answers in code.

### 2. Three types of question

| Command      | Use it when the answer is       | The answer has                                   |
| ------------ | ------------------------------- | ------------------------------------------------ |
| `jev noul`   | yes or no                       | `noul`: the probability of yes                   |
| `jev choice` | one of a list of options        | `choice`, `probabilities`, `confidence`          |
| `jev score`  | a point on a scale you describe | `score`, `legend`, `probabilities`, `confidence` |

These commands only build a question. Nothing is sent until `jev ask`.

```nushell
let questions = {
    team: (jev choice "Which team should handle this?" {
        billing: "Payments, invoicing, refunds"
        technical: "Bugs, outages, integrations"
        sales: null     # the name says enough
    })
    urgent: (jev noul "Does this convey urgency?")
    anger: (jev score "How frustrated is the customer?" ["Calm" "Frustrated" "Very angry"])
}

"Help! My payouts have been failing for 3 days." | jev ask $questions | table -e
# => ╭────────┬──────────────────────────────────────────╮
# => │        │ ╭───────────────┬──────────────────────╮ │
# => │ team   │ │ type          │ choice               │ │
# => │        │ │ choice        │ billing              │ │
# => │        │ │ confidence    │ 0.76                 │ │
# => │        │ │               │ ╭───────────┬──────╮ │ │
# => │        │ │ probabilities │ │ sales     │ 0.00 │ │ │
# => │        │ │               │ │ technical │ 0.16 │ │ │
# => │        │ │               │ │ billing   │ 0.84 │ │ │
# => │        │ │               │ ╰───────────┴──────╯ │ │
# => │        │ ╰───────────────┴──────────────────────╯ │
# => │        │ ╭──────┬──────╮                          │
# => │ urgent │ │ type │ noul │                          │
# => │        │ │ noul │ 0.95 │                          │
# => │        │ ╰──────┴──────╯                          │
# => │        │ ╭───────────────┬────────────────────╮   │
# => │ anger  │ │ type          │ score              │   │
# => │        │ │ score         │ 1.04               │   │
# => │        │ │ confidence    │ 0.93               │   │
# => │        │ │               │ ╭───┬────────────╮ │   │
# => │        │ │ legend        │ │ 0 │ Calm       │ │   │
# => │        │ │               │ │ 1 │ Frustrated │ │   │
# => │        │ │               │ │ 2 │ Very angry │ │   │
# => │        │ │               │ ╰───┴────────────╯ │   │
# => │        │ │               │ ╭───┬──────╮       │   │
# => │        │ │ probabilities │ │ 0 │ 0.00 │       │   │
# => │        │ │               │ │ 1 │ 0.95 │       │   │
# => │        │ │               │ │ 2 │ 0.05 │       │   │
# => │        │ │               │ ╰───┴──────╯       │   │
# => │        │ ╰───────────────┴────────────────────╯   │
# => ╰────────┴──────────────────────────────────────────╯
```

Score levels are numbered from 0, and `score` is their average weighted by
probability. So 1.04 means "Frustrated", with a slight lean toward "Very angry".

A noul near 0.5 means jev can't tell, not that the answer is "somewhat". To
measure how much, use a score.

Jev never sees the question id, so put the whole question in the instructions.
It judges each score level without seeing the others, so describe a level as a
situation, e.g. "a workaround exists". A degree like "moderate" gives it nothing
to match.

Instructions and descriptions can also be records or lists, e.g. a rubric with
examples. See [Advanced: structure](https://docs.typesafe.ai/primitives/advanced).

### 3. Ask everything in one call

Jev answers the questions in a call in parallel, and one answer never affects
another. Only input tokens are billed. TypeSafe measured 13 questions in one
call as 12x cheaper and 10x faster than 13 calls.

So ask everything the code might need, even questions that only matter for some
inputs, and ignore the answers you don't use. Make a second call only when its
questions depend on an answer from the first.

### 4. Confidence

This ticket is about a delivery and also about a charge:

```nushell
"I ordered the standing desk two weeks ago and tracking still says label created. Was I even charged?"
| jev ask {
    team: (jev choice "Which team should handle this?" {
        billing: "Charges, invoices, refunds"
        orders: "Order status, delivery, returns"
        account: "Login, password, profile"
    })
} | get team | reject type | table -e
# => ╭───────────────┬────────────────────╮
# => │ choice        │ orders             │
# => │ confidence    │ 0.29               │
# => │               │ ╭─────────┬──────╮ │
# => │ probabilities │ │ orders  │ 0.53 │ │
# => │               │ │ billing │ 0.47 │ │
# => │               │ │ account │ 0.00 │ │
# => │               │ ╰─────────┴──────╯ │
# => ╰───────────────┴────────────────────╯
```

`choice` is the most probable option, even when it barely wins. `confidence` is
low when the options are close, as here, and 1 when one option has all the
probability. Pick a threshold by how bad a wrong answer would be:

```nushell
match $answers.team {
    {confidence: $c} if $c < 0.5 => (ask-a-human $ticket)
    {choice: billing, confidence: $c} if $c > 0.9 => (refund $ticket)
    {choice: $team} => (queue $team $ticket)
}
```

A noul has no `confidence`. How far it is from 0.5 tells you the same thing.

The numbers move a little between runs. The same request a moment earlier gave
a confidence of 0.39, so leave room around a threshold. `jev-latest` also changes when TypeSafe
ships a new model. Once your thresholds are tuned, pin the version with
`--model jev-1.13.0`.

### 5. Records and lists as state

The state doesn't have to be a string. Put everything the decision depends on
into one record, and point a question at a part of it with a path in backticks:

```nushell
{
    ticket: {subject: "Duplicate charge", body: "I was charged twice for order A-104. Please refund the duplicate."}
    order: {id: "A-104", charges: [{amount_usd: 49, status: captured}, {amount_usd: 49, status: captured}]}
    refund_policy: "Duplicate charges are eligible for a refund."
} | jev ask {
    requested: (jev noul "Does `ticket.body` request a refund?")
    supported: (jev noul "Does `refund_policy` support the refund requested in `ticket.body`, given `order.charges`?")
} | to nuon
# => {requested: {type: noul, noul: 0.99}, supported: {type: noul, noul: 0.98}}
```

Leave out what the questions don't need. TypeSafe reports that accuracy drops as
unrelated detail grows.

### 6. In a pipeline

`jev ask` judges one state per call, and a list counts as one state (a
conversation, for example). To judge every row of a table, call it once per row
with `insert`.

This reads a repository's open issues with `gh` and adds jev's answers to each
one as a `jev` column:

```nushell
let questions = {
    kind: (jev choice "What kind of issue is this?" {
        bug: "Something does not work the way the docs or common sense say it should"
        feature: "A request for new behavior"
        question: "The author is asking how to do something"
        other: null
    })
    repro: (jev noul "Does `body` include a command or steps that reproduce the problem?")
    severity: (jev score "How badly does the problem in `body` hurt the person reporting it?" [
        "Cosmetic, or an easy workaround exists"
        "A feature is broken, and the workaround is awkward"
        "A crash, a hang, lost data, or no workaround"
    ])
}

let triaged = gh issue list --repo nushell/nushell --limit 12 --json number,title,body
    | from json
    | update body { str substring 0..3000 }     # keep a long pasted log from using up the token budget
    | insert jev { select title body | jev ask $questions }
```

`repro` and `severity` only matter for bugs. They are asked about every issue
anyway, because that is cheaper than a second request for just the bugs.

The answers are now columns, so the rest is ordinary Nushell. This ranks the
bugs:

```nushell
$triaged
| where jev.kind.choice == bug and jev.kind.confidence > 0.8
| insert priority {|issue| 0.7 * $issue.jev.severity.score / 2 + 0.3 * $issue.jev.repro.noul }
| sort-by priority --reverse
| select number title priority
| first 4
# => ╭───┬────────┬──────────────────────────────────────────────────────────────────────────┬──────────╮
# => │ # │ number │                                  title                                   │ priority │
# => ├───┼────────┼──────────────────────────────────────────────────────────────────────────┼──────────┤
# => │ 0 │  19035 │ Infinite memory allocation when `print` runs inside a streaming closure  │     0.97 │
# => │   │        │ with a zero-width terminal                                               │          │
# => │ 1 │  18989 │ Handle to background job is dropped if `$env.PROMPT` closure is exited   │     0.82 │
# => │   │        │ prematurely                                                              │          │
# => │ 2 │  19016 │ External completer migration from #18791 completes the wrong command     │     0.70 │
# => │   │        │ after a pipe                                                             │          │
# => │ 3 │  18983 │ Errors in a menu `source` closure are dropped silently                   │     0.65 │
# => ╰───┴────────┴──────────────────────────────────────────────────────────────────────────┴──────────╯
```

`priority` combines two answers with weights of 0.7 and 0.3. The score runs from
0 to 2, so `/ 2` brings it to the same 0 to 1 range as the noul. If the ranking
looks wrong, change the weights.

This labels each issue, and gives the ones jev is unsure about to a person:

```nushell
$triaged | each {|issue|
    let label = match $issue.jev.kind {
        {confidence: $c} if $c < 0.8 => "needs-triage"
        {choice: $kind} => $kind
    }
    gh issue edit $issue.number --repo nushell/nushell --add-label $label
}
```

`insert` makes the requests one at a time, which took 4 seconds for these 12
issues. `par-each` makes them all at once and took 0.4:

```nushell
| par-each --keep-order {|issue| $issue | insert jev { select title body | jev ask $questions } }
```

[`examples/triage.nu`](examples/triage.nu) is a runnable version:
`nu examples/triage.nu nushell/nushell`. It only reads.

## Reference

`jev` lists the commands. `help jev ask` has the details for one.

```nushell
jev noul <instructions> [--yes <description>] [--no <description>]
jev choice <instructions> <options>     # record: option -> description, or null
jev score <instructions> <levels>       # list of descriptions, lowest first
<state> | jev ask <questions>           # record: id -> question. Returns id -> answer
jev models
```

| `jev ask` flag  | Meaning                                                                              |
| --------------- | ------------------------------------------------------------------------------------ |
| `--model`, `-m` | Model or alias. Defaults to `$env.JEV_MODEL`, then `jev-latest`                      |
| `--full`, `-f`  | Return the whole response: `answers`, `usage`, and the `model` version that answered |
| `--dry-run`     | Return the request body and send nothing                                             |
| `--max-retries` | Retries on 429 and 529, honoring `retry-after`. Default 3                            |
| `--timeout`     | Per attempt. Default 2min                                                            |

| Variable           | Meaning               | Default                      |
| ------------------ | --------------------- | ---------------------------- |
| `TYPESAFE_API_KEY` | API key. Required     | none                         |
| `JEV_MODEL`        | Model or alias        | `jev-latest`                 |
| `JEV_BASE_URL`     | Endpoint, for testing | `https://api.typesafe.ai/v1` |

A choice takes 2 to 255 options and a score 2 to 10 levels. A request can hold
64k tokens, of which the state plus the longest question can use 32k.

A question can also be a plain record in the
[API's shape](https://docs.typesafe.ai/api#question-types). `jev ask` checks it
the way the three commands do.

### Errors

A mistake in a question is caught before anything is sent:

```nushell
jev score "How angry?" ["Furious"]
# => Error: nu::shell::error
# =>
# =>   x too few levels
# =>    ,-[source:1:24]
# =>  1 | jev score "How angry?" ["Furious"]
# =>    :                        ^^^^^|^^^^^
# =>    :                             `-- 1 of the 2 levels a score needs
# =>    `----
# =>   help: The API scores a lone level 0 with full confidence, which tells you
# =>         nothing. For a yes/no judgment use `jev noul`.
```

An error from the API shows the status, TypeSafe's message and the request id. A
429 or 529 is retried first.

## Tests

```nushell
nu tests/run.nu
```

The tests never call TypeSafe. They run every `@example` in the module that has
a recorded result, and check the error messages. `jev ask` is tested against the
stub, [`tests/stub.nu`](tests/stub.nu): a fake TypeSafe API served by
[http-nu](https://github.com/cablehead/http-nu). Without `http-nu` on the PATH,
the stub checks are skipped.

## Learn more

TypeSafe's docs cover the [question types](https://docs.typesafe.ai/primitives)
and [common patterns](https://docs.typesafe.ai/patterns) in more depth.
[Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13) lists
what the model is bad at, e.g. arithmetic and counting. Do those in code.
