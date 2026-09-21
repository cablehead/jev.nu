# jev

Nushell module for jev, TypeSafe's model that answers questions with
probabilities instead of text.

README.md explains the concepts and the commands. Read it first. `help jev ask`
has the flags.

## Using it from an agent

Run commands with `nu -c 'use /root/jev/jev; jev <command>'`. Use the absolute
path to the module directory. The key comes from `$env.TYPESAFE_API_KEY`.

```bash
nu -c 'use /root/jev/jev;
  "Help! My payouts have been failing for 3 days." | jev ask {
    team: (jev choice "Which team should handle this?" {billing: null, technical: null})
    urgent: (jev noul "Does this convey urgency?")
  }'
```

- Put every question about a state in one `jev ask` call. Jev answers them in
  parallel and only input tokens are billed.
- Ask small questions and combine the answers in code. Before weighting a score,
  divide it by its top level number.
- Do arithmetic, counting and date math in code. Jev is bad at them.
- Send only the fields the questions need. Unrelated detail lowers accuracy.
- To judge each row of a table: `insert jev { select subject body | jev ask $questions }`.
  For many rows, `par-each --keep-order {|row| $row | insert jev { ... } }` makes
  the requests at once. Twelve rows took 0.4 seconds that way, against 4.

## Changing the module

The module rejects what the API documents as invalid, plus two questions the API
accepts and answers meaninglessly: a choice with one option and a score with one
level. Check a new rule against the live API before adding it. A rule stricter
than the API blocks valid requests, which has happened once: descriptions that
were records got rejected.

README.md, the doc comments (they are the `help` text) and this file should say
the same thing the same way. One name per thing: state, question, answer,
option, level, the stub. Name the three commands instead of calling them
builders.

## Tests

```bash
nu tests/run.nu
```

The tests never call TypeSafe.

- Every `@example` with a `--result` runs as a test. Add one when you add a
  command or change what one returns.
- The rest of `tests/run.nu` checks the error messages, and `jev ask` against the
  stub (`tests/stub.nu`), a fake TypeSafe API served by http-nu. A request's
  `model` picks the stub's behavior: `busy`, `overloaded`, `invalid`, `broken`.
  Without http-nu on the PATH the stub checks are skipped.

In an http-nu handler, never `return` a response early. The returned value loses
the metadata that carries the status, so a 401 goes out as a 200.
