# jev

A [Nushell](https://www.nushell.sh) module for [TypeSafe](https://typesafe.ai)'s
System One API. Pipe in some content and ask typed questions about it. The
answers are probabilities, so the rest of the pipeline can branch on a judgment.

```nushell
"Help! My payouts have been failing for 3 days." | jev ask {
    urgent: (jev noul "Does this convey urgency?")
} | get urgent.noul
# => 0.95
```

## Install

Plain Nushell, with no build step and no dependencies.

```nushell
git clone https://github.com/cablehead/jev.nu
use jev.nu/jev
$env.TYPESAFE_API_KEY = "apikey_..."   # from https://console.typesafe.ai/keys
```

Put the last two lines in `config.nu` to keep them.

## Tutorial

### 1. State, questions, answers

Jev is what TypeSafe calls a System One model. Like an LLM it reads natural
language. It generates no text: you define the possible answers, and it returns
a calibrated probability for each. A request has three parts.

| Jev calls it | What it is                              | In this module                                             |
| ------------ | --------------------------------------- | ---------------------------------------------------------- |
| state        | The content to judge                    | The pipeline input to `jev ask`                            |
| questions    | The judgments to make, each under an id | A record built with `jev noul`, `jev choice`, `jev score`  |
| answers      | One typed answer per question           | The record `jev ask` returns, under the same ids           |

In the example above the state is the customer's message, `urgent` is the id,
and `0.95` is the probability that the answer is yes.

Ask for a judgment a knowledgeable person makes in a second. "Does this convey
urgency?" works. "Work out what to do about this ticket" does not: split it into
small questions and decide in code.

### 2. Three types of question

| Builder      | Ask it when the answer is                 | The answer carries                               |
| ------------ | ----------------------------------------- | ------------------------------------------------ |
| `jev noul`   | yes or no                                 | `noul`, the probability of yes                   |
| `jev choice` | one of a set, with no order between them  | `choice`, `probabilities`, `confidence`          |
| `jev score`  | a position on a spectrum you can describe | `score`, `legend`, `probabilities`, `confidence` |

A builder returns a record and sends nothing, so questions can sit in a variable
where a person can review them.

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

A `score` is each level number weighted by its probability, so it lands between
levels: 1.04 is "Frustrated", leaning a little toward "Very angry". Compare it
to a threshold. Do not use it as an index.

A `noul` near 0.5 means the model cannot tell. It does not mean "somewhat". To
measure how much, use a score.

The model sees the instructions and the descriptions, never the question id, so
write the whole question in the instructions. It matches the state against each
score level on its own, so describe a situation ("a workaround exists"), not a
degree ("moderate"). Instructions and descriptions also take a record or a list,
for a rubric with examples. See
[Advanced: structure](https://docs.typesafe.ai/primitives/advanced).

### 3. Ask everything in one call

Jev reads the state once and answers every question in parallel, each on its
own. Only input tokens are billed. TypeSafe measured 13 questions in one call at
12x cheaper and 10x faster than 13 calls.

So ask every question the code might need, including ones that matter for only
some inputs, and ignore the answers it does not need. Make a second call only
when the code cannot build it without an answer from the first.

### 4. Confidence says whether to act

This ticket is about a delivery and about a charge.

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

`choice` is always the most probable option, even when it barely wins.
`confidence` runs from 0, for probability spread flat, to 1, for all of it on
one option. Set the bar by what a wrong answer costs:

```nushell
match $answers.team {
    {confidence: $c} if $c < 0.5 => (ask-a-human $ticket)
    {choice: billing, confidence: $c} if $c > 0.9 => (refund $ticket)
    {choice: $team} => (queue $team $ticket)
}
```

A noul has no `confidence`. Its distance from 0.5 is the certainty.

Answers move a little between runs: the same request a moment earlier gave 0.39.
Leave room around a threshold. `jev-latest` also moves when TypeSafe ships a
model, so once thresholds are tuned, pin the version with `--model jev-1.13.0`.

### 5. Give the state structure

A state can be a record or a list. Put everything the decision depends on into
one state, and name the part a question is about with a path in backticks.

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

Send only what the questions need. Accuracy falls as unrelated detail piles up.

### 6. A node in a pipeline

`jev ask` takes one state, and a list is one state: a conversation, say. To
judge each row of a table, `insert` runs it once per row and keeps the row,
which leaves the answers where `where` and `sort-by` can reach them.

This reads a repository's open issues with `gh` and has jev judge each one:

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
    | update body { str substring 0..3000 }     # a pasted log adds tokens, not signal
    | insert jev { select title body | jev ask $questions }
```

`repro` and `severity` only matter for a bug. They are asked of every issue
anyway, because a question costs a few tokens and a second request costs a round
trip.

From here it is ordinary Nushell, steered by jev's answers. This ranks the bugs:

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

`priority` splits one judgment in two and weights the parts in code. `/ 2` puts
the three-level score on 0 to 1. When the ranking disagrees with your team,
change a weight, not a prompt.

And this acts on them, leaving the issues jev is unsure of to a person:

```nushell
$triaged | each {|issue|
    let label = match $issue.jev.kind {
        {confidence: $c} if $c < 0.8 => "needs-triage"
        {choice: $kind} => $kind
    }
    gh issue edit $issue.number --repo nushell/nushell --add-label $label
}
```

`insert` sends one request after another: 4 seconds for these 12 issues.
`par-each` sends them together, in 0.4 seconds:

```nushell
| par-each --keep-order {|issue| $issue | insert jev { select title body | jev ask $questions } }
```

[`examples/triage.nu`](examples/triage.nu) is the runnable version:
`nu examples/triage.nu nushell/nushell`. It reads with `gh` and changes nothing.

## Reference

`jev` lists the commands. `help jev ask` has the detail and examples for each.

```nushell
jev noul <instructions> [--yes <description>] [--no <description>]
jev choice <instructions> <options>     # record: option -> description, or null
jev score <instructions> <levels>       # list of descriptions, lowest first
<state> | jev ask <questions>           # record: id -> question. Returns id -> answer
jev models
```

| `jev ask` flag  | Meaning                                                                 |
| --------------- | ----------------------------------------------------------------------- |
| `--model`, `-m` | Model or alias. Defaults to `$env.JEV_MODEL`, then `jev-latest`         |
| `--full`, `-f`  | Return the whole response: `answers`, `usage`, and the `model` version that answered |
| `--dry-run`     | Return the request body and send nothing                                |
| `--max-retries` | Retries on 429 and 529, honoring `retry-after`. Default 3               |
| `--timeout`     | Per attempt. Default 2min                                               |

| Variable           | Meaning               | Default                      |
| ------------------ | --------------------- | ---------------------------- |
| `TYPESAFE_API_KEY` | API key. Required     | none                         |
| `JEV_MODEL`        | Model or alias        | `jev-latest`                 |
| `JEV_BASE_URL`     | Endpoint, for testing | `https://api.typesafe.ai/v1` |

Limits: a choice takes 2 to 255 options, a score 2 to 10 levels. A request holds
64k tokens, with 32k for the state plus the longest question.

A question can also be a raw record in the
[API's shape](https://docs.typesafe.ai/api#question-types). `jev ask` checks it
the way the builders do.

### Errors

A question the API would reject, or would answer with nonsense, fails before
anything is sent, and the error points at your source:

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

An error from the API carries the status, the reason, and the request id. A 429
or a 529 is retried first.

## Tests

```nushell
nu tests/run.nu
```

Nothing in the suite reaches TypeSafe. Every `@example` in the module that
records a result runs as a test. The rest check the errors, and `jev ask` on the
wire against [`tests/stub.nu`](tests/stub.nu), a stand-in for the API served by
[http-nu](https://github.com/cablehead/http-nu). Without `http-nu` on the PATH
those are skipped.

## Learn more

TypeSafe's docs go deeper on the [concepts](https://docs.typesafe.ai/primitives)
and the [patterns](https://docs.typesafe.ai/patterns) this tutorial borrows.
[Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13) lists
where the model is weak. Arithmetic, counting, and date math belong in code.
