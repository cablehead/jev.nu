# The stub: a fake TypeSafe API, served by http-nu for tests/run.nu.
#
# The `model` of a request picks the behavior:
#
#   busy        429 with `retry-after: 0` on the first call, an answer on the next
#   overloaded  529 every time
#   invalid     422, in the shape the API uses to report a bad field
#   broken      500 with a body that is not JSON, as a proxy would send
#   otherwise   an answer to every question, the first option or level winning
#
# Each request adds a line to $env.JEV_STUB_LOG. The runner counts attempts from
# that file.

def respond [status: int, headers: record = {}]: any -> any {
    to json | metadata set { merge { "http.response": {
        status: $status
        headers: ({ "content-type": "application/json", "x-typesafe-request-id": "req_stub" } | merge $headers)
    } } }
}

def answer [question: record]: nothing -> record {
    match $question.type {
        "noul" => { type: noul, noul: 0.9 }
        "choice" => {
            let options = $question.criteria | columns
            {
                type: choice
                choice: ($options | first)
                confidence: 1.0
                probabilities: ($options | enumerate | each {|o| { $o.item: (if $o.index == 0 { 1.0 } else { 0.0 }) } } | into record)
            }
        }
        "score" => {
            let levels = $question.criteria | enumerate
            {
                type: score
                score: 0.0
                confidence: 1.0
                legend: ($levels | each {|l| { ($l.index | into string): $l.item } } | into record)
                probabilities: ($levels | each {|l| { ($l.index | into string): (if $l.index == 0 { 1.0 } else { 0.0 }) } } | into record)
            }
        }
    }
}

# One expression, no early `return`: a returned value loses the metadata that
# carries the status.
{|req|
    let body = $in
    $"($req.method) ($req.path)\n" | save --append $env.JEV_STUB_LOG
    let attempts = open --raw $env.JEV_STUB_LOG | lines | where $it == "POST /systemone" | length

    if $req.headers.authorization? != "Bearer stub-key" {
        { detail: { error_type: authentication_error, message: "Cannot authenticate with the server." } } | respond 401
    } else if $req.path == "/models" {
        { models: [{ name: jev-latest, release_date: "2026-09-10", description: "The stub" }] } | respond 200
    } else {
        let request = $body | from json
        match $request.model {
            "busy" if $attempts == 1 => ({ detail: { message: "Slow down." } } | respond 429 { "retry-after": "0" })
            "overloaded" => ({ detail: { message: "Overloaded." } } | respond 529 { "retry-after": "0" })
            "invalid" => ({ detail: [{
                type: string_type
                loc: [body questions severity score criteria 1 str]
                msg: "Input should be a valid string"
                input: null
            }] } | respond 422)
            "broken" => ("upstream exploded" | metadata set { merge { "http.response": { status: 500 } } })
            _ => ({
                model: "jev-stub.0"
                answers: ($request.questions | items {|id, question| { $id: (answer $question) } } | into record)
                usage: { input_tokens: 100, output_tokens: 10 }
            } | respond 200)
        }
    }
}
