# Typed decisions from the TypeSafe System One API
#
# A System One model reads a state and answers typed questions about it with
# calibrated probabilities, so code can branch on a judgment. Build questions
# with `jev noul`, `jev choice`, and `jev score`, then put them to a state with
# `jev ask`.
#
# $env.TYPESAFE_API_KEY  required, from https://console.typesafe.ai/keys
# $env.JEV_MODEL         default model, `jev-latest` when unset
# $env.JEV_BASE_URL      endpoint, to point the module at a stub

const BASE_URL = "https://api.typesafe.ai/v1"
const DEFAULT_MODEL = "jev-latest"
const MODEL_ALIASES = [jev-latest jev-preview]
const RETRY_STATUS = [429 529]
const MAX_RETRY_WAIT = 1min

# Instructions and every description take text or JSON structure.
const ENTRY_TYPES = [string record list]
const MAX_OPTIONS = 255
const MAX_LEVELS = 10

def fail [msg: string, label: string, span: record, help: string] {
    error make { msg: $msg, label: { text: $label, span: $span }, help: $help }
}

def type-of []: any -> string {
    describe --detailed | get type
}

# Check one question against the shapes the API accepts.
#
# The API answers a one-option choice or a one-level score with full confidence,
# which reads as a strong answer and means nothing, so both are errors here.
# `spans` says where to point. A builder passes the span of each argument.
# `jev ask` passes the span of its questions record, and the id of the question.
def check-question [
    question: record
    spans: record<instructions: record, criteria: record>
    --id: string
] {
    let prefix = if $id == null { "" } else { $"question ($id): " }
    let type = $question.type? | default "nothing"
    let instructions = $question.instructions?
    let criteria = $question.criteria?

    if $type not-in [noul choice score] {
        fail $"($prefix)unknown type" $"type is ($type)" $spans.instructions "A question type is noul, choice, or score."
    }

    if ($instructions | type-of) not-in $ENTRY_TYPES {
        fail $"($prefix)invalid instructions" $"instructions is ($instructions | type-of)" $spans.instructions "Instructions are a string, a record, or a list."
    }
    if ($instructions | is-empty) {
        fail $"($prefix)empty instructions" "nothing to ask" $spans.instructions "Write the whole question here. The model never sees the question id."
    }

    match $type {
        "noul" => {
            if $criteria == null { return }
            if ($criteria | type-of) != "record" {
                fail $"($prefix)invalid criteria" $"criteria is ($criteria | type-of)" $spans.criteria "Noul criteria is a record with a `true` and a `false` description."
            }
            for side in ($criteria | columns) {
                if $side not-in ["true" "false"] {
                    fail $"($prefix)invalid criteria" $"($side) is not a side of a noul" $spans.criteria "The sides are named `true` and `false`. The API ignores any other key."
                }
                if ($criteria | get $side | type-of) not-in $ENTRY_TYPES {
                    fail $"($prefix)invalid criteria" $"($side) is ($criteria | get $side | type-of)" $spans.criteria "Describe a side with a string, a record, or a list."
                }
            }
        }
        "choice" => {
            if ($criteria | type-of) != "record" {
                fail $"($prefix)invalid options" $"criteria is ($criteria | type-of)" $spans.criteria "Choice criteria is a record of option -> description."
            }
            let count = $criteria | columns | length
            if $count < 2 {
                fail $"($prefix)too few options" $"($count) of the 2 options a choice needs" $spans.criteria "The API picks a lone option with full confidence, which tells you nothing. For a yes/no judgment use `jev noul`."
            }
            if $count > $MAX_OPTIONS {
                fail $"($prefix)too many options" $"($count) options" $spans.criteria $"A choice takes up to ($MAX_OPTIONS) options."
            }
            for option in ($criteria | columns) {
                if ($criteria | get $option | type-of) not-in [...$ENTRY_TYPES nothing] {
                    fail $"($prefix)invalid option" $"($option) is ($criteria | get $option | type-of)" $spans.criteria "Describe an option with a string, a record, or a list. Use null when the name says enough."
                }
            }
        }
        "score" => {
            if ($criteria | type-of) != "list" {
                fail $"($prefix)invalid levels" $"criteria is ($criteria | type-of)" $spans.criteria "Score criteria is a list of level descriptions, lowest first."
            }
            let count = $criteria | length
            if $count < 2 {
                fail $"($prefix)too few levels" $"($count) of the 2 levels a score needs" $spans.criteria "The API scores a lone level 0 with full confidence, which tells you nothing. For a yes/no judgment use `jev noul`."
            }
            if $count > $MAX_LEVELS {
                fail $"($prefix)too many levels" $"($count) levels" $spans.criteria $"A score takes up to ($MAX_LEVELS) levels. Use only as many as you can describe distinctly."
            }
            for level in ($criteria | enumerate) {
                if ($level.item | type-of) not-in $ENTRY_TYPES {
                    fail $"($prefix)invalid level" $"level ($level.index) is ($level.item | type-of)" $spans.criteria "Describe a level with a string, a record, or a list. The description is all the model sees of it."
                }
            }
        }
    }
}

# Build a yes/no question
#
# The answer is the probability of yes, from 0 to 1. Near 0.5 means the model
# splits its bet, not that the truth is in the middle: for a position on a
# spectrum use `jev score`. Phrase the question so that a high value means yes.
@search-terms typesafe question boolean probability
@example "a yes/no question" {
    jev noul "Does the message report a bug?"
} --result { type: noul, instructions: "Does the message report a bug?" }
@example "pin down what each side means" {
    jev noul "Does this convey urgency?" --yes "Explicitly time-sensitive" --no "No urgency expressed"
} --result {
    type: noul
    instructions: "Does this convey urgency?"
    criteria: { "true": "Explicitly time-sensitive", "false": "No urgency expressed" }
}
export def noul [
    instructions: any       # The question, or a statement to judge: a string, record, or list
    --yes: any              # What a yes (near 1) means
    --no: any               # What a no (near 0) means
]: nothing -> record {
    let criteria = [
        (if $yes != null { { "true": $yes } })
        (if $no != null { { "false": $no } })
    ] | compact | into record

    let question = { type: "noul", instructions: $instructions }
        | if ($criteria | is-empty) { } else { insert criteria $criteria }

    let span = (metadata $instructions).span
    check-question $question { instructions: $span, criteria: $span }
    $question
}

# Build a pick-one question
#
# The answer carries the winning option, the probability of every option, and a
# confidence derived from that distribution. Give the full list of options, and
# an `other` when the list might not cover every input.
@search-terms typesafe question classify route category
@example "route a ticket" {
    jev choice "Which team should handle this?" {
        billing: "Payments, invoicing, refunds"
        technical: "Bugs, outages, integrations"
        sales: null
    }
} --result {
    type: choice
    instructions: "Which team should handle this?"
    criteria: { billing: "Payments, invoicing, refunds", technical: "Bugs, outages, integrations", sales: null }
}
@example "say what an option is not for, when two options blur" {
    jev choice "Which team should handle this?" {
        billing: { what: "Charges and refunds", not_for: "Order tracking" }
        orders: { what: "Delivery and returns", not_for: "Charges" }
    }
} --result {
    type: choice
    instructions: "Which team should handle this?"
    criteria: {
        billing: { what: "Charges and refunds", not_for: "Order tracking" }
        orders: { what: "Delivery and returns", not_for: "Charges" }
    }
}
export def choice [
    instructions: any       # What to decide: a string, record, or list
    options: record         # Option -> description, or null when the name says enough
]: nothing -> record {
    let question = { type: "choice", instructions: $instructions, criteria: $options }
    check-question $question {
        instructions: (metadata $instructions).span
        criteria: (metadata $options).span
    }
    $question
}

# Build a rate-it-on-a-scale question
#
# The answer is a probability-weighted position along the levels. It can land
# between two of them, so threshold it as a number. The model matches the state
# against each description on its own, so describe situations ("workaround
# exists"), not degrees ("moderate").
@search-terms typesafe question rate scale severity rubric
@example "rate customer frustration" {
    jev score "How frustrated is the customer?" ["Calm" "Frustrated" "Very angry"]
} --result {
    type: score
    instructions: "How frustrated is the customer?"
    criteria: ["Calm", "Frustrated", "Very angry"]
}
export def score [
    instructions: any       # What to rate: a string, record, or list
    levels: list            # Level descriptions, lowest first, 2 to 10 of them
]: nothing -> record {
    let question = { type: "score", instructions: $instructions, criteria: $levels }
    check-question $question {
        instructions: (metadata $instructions).span
        criteria: (metadata $levels).span
    }
    $question
}

def auth-headers []: nothing -> record {
    let key = $env.TYPESAFE_API_KEY? | default ""
    if ($key | is-empty) {
        error make --unspanned {
            msg: "no TypeSafe API key"
            help: "Set $env.TYPESAFE_API_KEY. Keys are issued at https://console.typesafe.ai/keys"
        }
    }
    { Authorization: $"Bearer ($key)" }
}

def header [name: string]: record -> any {
    $in.headers.response | where name == $name | get value.0?
}

# How long to wait before retry number `attempt`, counted from 0.
#
# The server's retry-after wins, up to a cap: a pipeline that sleeps for an hour
# on the server's say-so looks hung.
def retry-wait [response: record, attempt: int]: nothing -> duration {
    let seconds = try { $response | header retry-after | into float }
    if $seconds != null { return ([($seconds * 1sec) $MAX_RETRY_WAIT] | math min) }

    # 1s, 2s, 4s, with jitter so a fleet of callers does not retry in lockstep.
    (2 ** $attempt) * 1sec + (random float 0.0..0.5) * 1sec
}

def api-error [response: record] {
    let body = $response.body
    let detail = if ($body | type-of) == "record" { $body.detail? | default $body } else { $body }

    # Reporting an error must not raise one of its own, whatever the body holds.
    let message = try {
        match ($detail | type-of) {
            # A 422 lists each field that failed.
            "list" => ($detail | each {|d| $"($d.loc | skip 1 | str join '.'): ($d.msg)" } | str join "\n")
            "record" => ($detail.message? | default ($detail | to nuon))
            _ => ($detail | into string)
        }
    } catch {
        $detail | to nuon
    }

    let help = match $response.status {
        400 => "The request was rejected. Check the model name."
        401 => "Check $env.TYPESAFE_API_KEY. Keys are issued at https://console.typesafe.ai/keys"
        422 => "The request body failed validation. `jev ask --dry-run` shows what is sent."
        429 => "Rate limited. Raise --max-retries, or send fewer, larger requests."
        529 => "TypeSafe is overloaded. Retry in a moment."
        _ => "See https://docs.typesafe.ai/api for the error reference."
    }

    error make --unspanned {
        msg: $"typesafe ($response.status): ($message)"
        help: $"($help)\nrequest id: ($response | header x-typesafe-request-id | default unknown)"
    }
}

# Call the API and return the response body. A body makes it a POST.
#
# Every pass through the loop returns, fails, or sleeps and goes again, which
# the type checker cannot see. Hence `any` for what is always a record.
def request [
    path: string
    body?: record
    --max-retries: int = 3
    --timeout: duration = 2min
]: nothing -> any {
    let url = ($env.JEV_BASE_URL? | default $BASE_URL) + $path
    let headers = auth-headers

    for attempt in 0..$max_retries {
        let response = if $body == null {
            http get --full --allow-errors --max-time $timeout --headers $headers $url
        } else {
            (http post --full --allow-errors --max-time $timeout --headers $headers
                --content-type application/json $url $body)
        }

        if $response.status == 200 { return $response.body }
        if $response.status not-in $RETRY_STATUS or $attempt == $max_retries {
            api-error $response
        }
        sleep (retry-wait $response $attempt)
    }
}

def "nu-complete jev models" []: nothing -> list<string> {
    $MODEL_ALIASES
}

# Put questions to a state and get the answers
#
# The state comes from the pipeline: a string, or a record or list when the
# decision needs several pieces of context. Answers come back under the ids you
# gave the questions. Every question sees the same state and is answered on its
# own, in parallel, and only input tokens are billed. So ask everything the code
# might need in one call, and ignore the answers it does not need.
@search-terms typesafe systemone evaluate classify decide confidence
@example "ask two questions and read one answer" {
    "Help! My payouts have been failing for 3 days." | jev ask {
        team: (jev choice "Which team should handle this?" {billing: null, technical: null})
        urgent: (jev noul "Does this convey urgency?")
    } | get team.choice
}
@example "add the answers to each row of a table" {
    open tickets.json | insert jev { jev ask { urgent: (jev noul "Is this urgent?") } }
}
@example "see the request without sending it" {
    "a ticket" | jev ask --dry-run { urgent: (jev noul "Is this urgent?") }
} --result {
    state: "a ticket"
    model: "jev-latest"
    questions: { urgent: { type: noul, instructions: "Is this urgent?" } }
}
export def ask [
    questions: record                               # Question id -> question
    --model (-m): string@"nu-complete jev models"   # Model or alias. Default: $env.JEV_MODEL
    --full (-f)                                     # Return the whole response: model, answers, usage
    --dry-run                                       # Return the request body and send nothing
    --max-retries: int = 3                          # Retries on 429 and 529, honoring retry-after
    --timeout: duration = 2min                      # Per attempt
]: [string -> record, record -> record, list -> record] {
    let state = $in
    let span = (metadata $questions).span

    if ($questions | is-empty) {
        fail "no questions" "empty record" $span "Pass a record of question id -> question, built with `jev noul`, `jev choice`, or `jev score`."
    }
    for question in ($questions | transpose id value) {
        if ($question.value | type-of) != "record" {
            fail $"question ($question.id): not a question" $"($question.id) is ($question.value | type-of)" $span "Build each question with `jev noul`, `jev choice`, or `jev score`."
        }
        check-question $question.value { instructions: $span, criteria: $span } --id $question.id
    }

    let body = {
        state: $state
        model: ($model | default $env.JEV_MODEL? | default $DEFAULT_MODEL)
        questions: $questions
    }
    if $dry_run { return $body }

    let response = request /systemone $body --max-retries $max_retries --timeout $timeout
    if $full { $response } else { $response.answers }
}

# List the models this account can use
#
# The list holds aliases. A versioned id such as `jev-1.13.0` is accepted by
# `jev ask --model` whether or not it appears here.
@search-terms typesafe jev version alias
@example "see what is available" { jev models }
export def models []: nothing -> table {
    request /models
    | get models
    | each {|m| {
        name: $m.name
        released: ($m.release_date | into datetime)
        description: $m.description
    } }
}

# Typed decisions from the TypeSafe System One API
export def main []: nothing -> table {
    scope commands
    | where name starts-with "jev "
    | select name description
}
