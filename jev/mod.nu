# Typed decisions from the TypeSafe System One API
#
# Build questions with `jev noul`, `jev choice`, and `jev score`, then send them
# together against one state with `jev ask`. Every question in a request is
# evaluated against the state in parallel and priced only on input tokens, so
# batching is both cheaper and faster than one call per question.
#
# Reads the API key from $env.TYPESAFE_API_KEY and the default model from
# $env.JEV_MODEL.

const DEFAULT_BASE_URL = "https://api.typesafe.ai/v1"
const DEFAULT_MODEL = "jev-latest"
const FALLBACK_MODELS = [jev-latest jev-preview]
const RETRY_STATUS = [429 529]
const RETURN_MODES = [answers full merged]
const QUESTION_TYPES = [noul choice score]

export-env {
    $env.JEV_MODEL = $env.JEV_MODEL? | default $DEFAULT_MODEL
    $env.JEV_BASE_URL = $env.JEV_BASE_URL? | default $DEFAULT_BASE_URL
}

def fail [msg: string, text: string, span: record, help: string] {
    error make {
        msg: $msg
        label: { text: $text, span: $span }
        help: $help
    }
}

def base-url [] {
    $env.JEV_BASE_URL? | default $DEFAULT_BASE_URL
}

def auth-headers [] {
    let key = $env.TYPESAFE_API_KEY? | default ""
    if ($key | is-empty) {
        error make --unspanned {
            msg: "no TypeSafe API key"
            help: "Set $env.TYPESAFE_API_KEY. Keys are issued at https://console.typesafe.ai/keys"
        }
    }
    { Authorization: $"Bearer ($key)" }
}

# Instructions accept a string, a record, or a list. Anything else is a mistake
# worth catching before it costs a round trip.
def check-instructions [instructions: any, span: record] {
    let type = $instructions | describe -d | get type
    if $type not-in [string record list] {
        (fail "invalid instructions" $"instructions is a ($type)" $span "Instructions must be a string, a record, or a list.")
    }
    if ($instructions | is-empty) {
        (fail "empty instructions" "nothing to ask" $span "Write the whole question here. The question id is never sent to the model.")
    }
}

# Build a yes/no question
#
# The answer is the probability that the answer is yes, from 0 to 1. Near 0.5
# means the model splits its bet, not that the truth is somewhere in the middle.
# Reach for `jev score` when you want a position on a spectrum.
@search-terms typesafe question boolean probability
@example "a bare yes/no question" {
    jev noul "The message reports a bug"
} --result { type: noul, instructions: "The message reports a bug" }
@example "spell out what each side means" {
    jev noul "Does this convey urgency?" --yes "Explicitly time-sensitive" --no "No urgency expressed"
} --result {
    type: noul
    instructions: "Does this convey urgency?"
    criteria: { "true": "Explicitly time-sensitive", "false": "No urgency expressed" }
}
export def noul [
    instructions: any       # The yes/no question: a string, record, or list
    --yes: string           # What a yes (near 1) means
    --no: string            # What a no (near 0) means
]: nothing -> record {
    check-instructions $instructions (metadata $instructions).span

    mut criteria = {}
    if ($yes | is-not-empty) { $criteria = ($criteria | insert "true" $yes) }
    if ($no | is-not-empty) { $criteria = ($criteria | insert "false" $no) }

    if ($criteria | is-empty) {
        { type: "noul", instructions: $instructions }
    } else {
        { type: "noul", instructions: $instructions, criteria: $criteria }
    }
}

# Build a pick-one question
#
# Criteria maps each option to a description of it, or to null when the option
# name says enough. The answer carries the winning option, the probability of
# every option, and a confidence derived from that distribution. Add an `other`
# option when the list might not cover every input.
@search-terms typesafe question classify route category
@example "route a ticket, describing two of three options" {
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
export def choice [
    instructions: any       # What to decide: a string, record, or list
    criteria: record        # Option name -> description, or null for no description
]: nothing -> record {
    let span = (metadata $criteria).span
    check-instructions $instructions (metadata $instructions).span

    if ($criteria | columns | length) < 2 {
        (fail "too few options" $"($criteria | columns | length) of the 2 options a choice needs" $span "A choice needs at least two options. For a yes/no judgment use `jev noul`.")
    }

    for option in ($criteria | columns) {
        let type = $criteria | get $option | describe -d | get type
        if $type not-in [string nothing] {
            (fail "invalid option description" $"($option) is a ($type)" $span "Each option maps to a description string, or to null for no description.")
        }
    }

    { type: "choice", instructions: $instructions, criteria: $criteria }
}

# Build a rate-it-on-a-scale question
#
# Criteria is the ordered list of levels, lowest first. The answer is a
# probability-weighted position along them and can land between two levels, so
# read it as a number rather than an index.
@search-terms typesafe question rate scale severity rubric
@example "rate customer frustration on three levels" {
    jev score "How frustrated is the customer?" ["Calm" "Frustrated" "Very angry"]
} --result {
    type: score
    instructions: "How frustrated is the customer?"
    criteria: ["Calm", "Frustrated", "Very angry"]
}
export def score [
    instructions: any       # What to rate: a string, record, or list
    criteria: list          # Ordered level descriptions, lowest first
]: nothing -> record {
    let span = (metadata $criteria).span
    check-instructions $instructions (metadata $instructions).span

    if ($criteria | length) < 2 {
        (fail "too few levels" $"($criteria | length) of the 2 levels a score needs" $span "A score needs at least two levels. The API accepts one and always answers 0 with full confidence, which tells you nothing.")
    }

    for level in $criteria {
        if ($level | describe -d | get type) != "string" {
            (fail "invalid level" $"($level | to nuon) is not a string" $span "Each level is a description string. Order them lowest to highest.")
        }
    }

    { type: "score", instructions: $instructions, criteria: $criteria }
}

def check-questions [questions: record, span: record] {
    if ($questions | is-empty) {
        (fail "no questions" "empty record" $span "Pass a record of question id -> question, built with `jev noul`, `jev choice`, or `jev score`.")
    }

    for id in ($questions | columns) {
        let q = $questions | get $id
        if ($q | describe -d | get type) != "record" {
            (fail $"invalid question ($id)" $"($id) is not a record" $span "Each entry is a question record. Build one with `jev noul`, `jev choice`, or `jev score`.")
        }
        let type = $q.type? | default ""
        if $type not-in $QUESTION_TYPES {
            (fail $"invalid question ($id)" $"($id) has type ($type | to nuon)" $span $"Question type must be one of: ($QUESTION_TYPES | str join ', ').")
        }
        if ($q.instructions? | default "" | is-empty) {
            (fail $"invalid question ($id)" $"($id) has no instructions" $span "Every question needs instructions. The id is not sent to the model.")
        }
    }
}

def retry-wait [response: record, attempt: int]: nothing -> duration {
    let header = $response.headers.response
        | where name == "retry-after"
        | get value
        | first
        | default null

    if $header != null {
        try { return (($header | into float) * 1sec) }
    }

    # 1s, 2s, 4s, with jitter so a fleet of callers does not retry in lockstep.
    (2 ** $attempt) * 1sec + ((random float 0.0..0.5) * 1sec)
}

def request-id [response: record]: nothing -> string {
    $response.headers.response
        | where name == "x-typesafe-request-id"
        | get value
        | first
        | default "unknown"
}

def http-fail [response: record] {
    let detail = $response.body.detail? | default $response.body
    let message = if ($detail | describe -d | get type) == "record" {
        $detail.message? | default ($detail | to nuon)
    } else {
        $detail | to nuon
    }

    let help = match $response.status {
        400 => "The request was rejected. Check the model name and the question shapes."
        401 => "Check $env.TYPESAFE_API_KEY. Keys are issued at https://console.typesafe.ai/keys"
        422 => "The request body failed validation. Run `jev ask --payload` to see what would be sent."
        429 => "Rate limited. Raise --max-retries, or send fewer, larger requests."
        529 => "TypeSafe is overloaded. Retry in a moment."
        _ => "See https://docs.typesafe.ai/api for the error reference."
    }

    error make --unspanned {
        msg: $"typesafe ($response.status): ($message)"
        help: $"($help)\nrequest id: (request-id $response)"
    }
}

def post-systemone [body: record, max_retries: int, timeout: duration] {
    let url = $"(base-url)/systemone"
    let headers = auth-headers

    mut attempt = 0
    loop {
        let response = (
            http post --full --allow-errors --content-type application/json
                --max-time $timeout --headers $headers $url $body
        )

        if $response.status == 200 {
            return $response.body
        }

        if ($response.status in $RETRY_STATUS) and $attempt < $max_retries {
            sleep (retry-wait $response $attempt)
            $attempt += 1
            continue
        }

        http-fail $response
    }
}

# Ask a batch of questions about one state
#
# The state comes from the pipeline: a string, or a record or list for
# structured input. Answers come back under the ids you gave the questions.
# Ask everything the code might need in one call, including questions whose
# answer only matters for some inputs, then branch on the answers in code.
@search-terms typesafe systemone evaluate classify confidence
@example "route a support ticket and read one answer" {
    "Help! My payouts have been failing for 3 days." | jev ask {
        dept: (jev choice "Which team should handle this?" {billing: null, technical: null})
        urgent: (jev noul "Does this convey urgency?")
    } | get dept.choice
}
@example "review the request without sending it" {
    "a ticket" | jev ask --payload { urgent: (jev noul "Is this urgent?") }
} --result {
    state: "a ticket"
    model: "jev-latest"
    questions: { urgent: { type: noul, instructions: "Is this urgent?" } }
}
@example "keep the row and add its answers as a column" {
    open tickets.json | each {|t| $t | jev ask --return merged {
        urgent: (jev noul "Is this urgent?")
    } }
}
export def ask [
    questions: record                       # Question id -> question record
    --model (-m): string@"nu-complete models"  # Model or alias, default $env.JEV_MODEL
    --return (-r): string = "answers"       # answers, full, or merged
    --payload                               # Return the request body instead of sending it
    --max-retries: int = 3                  # Retries on 429 and 529, with backoff
    --timeout: duration = 2min              # Per-attempt timeout
]: [string -> any, record -> any, list -> any] {
    let state = $in
    # `metadata $in` points at the caller's pipeline input; the local does not.
    let state_span = (metadata $in).span

    if $return not-in $RETURN_MODES {
        (fail "invalid --return" $"($return) is not a return mode" (metadata $return).span $"Use one of: ($RETURN_MODES | str join ', ').")
    }

    if $state == null {
        (fail "no state" "nothing came down the pipeline" $state_span "Pipe the content to evaluate into `jev ask`, as a string, record, or list.")
    }

    if $return == "merged" and ($state | describe -d | get type) != "record" {
        (fail "cannot merge" $"state is a ($state | describe -d | get type)" $state_span "--return merged adds an `answers` column to a record state. Use --return answers for anything else.")
    }

    check-questions $questions (metadata $questions).span

    let body = {
        state: $state
        model: ($model | default $env.JEV_MODEL? | default $DEFAULT_MODEL)
        questions: $questions
    }

    if $payload { return $body }

    let response = post-systemone $body $max_retries $timeout

    match $return {
        "answers" => $response.answers
        "full" => $response
        "merged" => ($state | insert answers $response.answers)
    }
}

# List the models this account can send
@search-terms typesafe jev version alias
@example "see what is available" { jev models }
export def models []: nothing -> table {
    http get --headers (auth-headers) $"(base-url)/models"
    | get models
    | each {|m| {
        name: $m.name
        released: ($m.release_date | into datetime)
        description: $m.description
    } }
}

# Model names, cached for a day so tab completion does not wait on the network.
def model-names []: nothing -> list<string> {
    let cache = $nu.cache-dir | path join "jev-models.nuon"
    mkdir $nu.cache-dir

    let fresh = if ($cache | path exists) {
        ((date now) - (ls $cache | get 0.modified)) < 1day
    } else {
        false
    }

    if $fresh {
        open $cache
    } else {
        let names = models | get name
        $names | save --force $cache
        $names
    }
}

def "nu-complete models" []: nothing -> list<string> {
    try { model-names } catch { $FALLBACK_MODELS }
}

# Typed decisions from the TypeSafe System One API
export def main []: nothing -> table {
    scope commands
    | where name starts-with "jev "
    | select name description
}
