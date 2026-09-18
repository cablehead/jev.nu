#!/usr/bin/env nu
#
# The jev test suite. Nothing here reaches api.typesafe.ai.
#
# Every @example in the module that records a result runs as a test. The checks
# below cover what an example cannot show: the errors, and `jev ask` on the
# wire, against tests/stub.nu served by http-nu. Without http-nu on the PATH
# those are skipped.

use std/assert

const tests = path self | path dirname
const module = $tests | path dirname | path join jev

use $module

# The message of the error a closure raises, or null when it raises none.
def error-of [code: closure]: nothing -> any {
    try { do $code | ignore; null } catch {|e| $e.msg }
}

# Checks that need no server.
def offline-checks []: nothing -> list<record> {
    [
        [name check];
        ["choice: one option is an error" {
            assert equal (error-of { jev choice "Which?" { a: null } }) "too few options"
        }]
        ["choice: 256 options is an error" {
            let options = 0..255 | each { { $"o($in)": null } } | into record
            assert equal (error-of { jev choice "Which?" $options }) "too many options"
        }]
        ["choice: a description is text, structure, or null" {
            assert equal (error-of { jev choice "Which?" { a: 1, b: null } }) "invalid option"
        }]
        ["score: one level is an error" {
            assert equal (error-of { jev score "How?" ["only"] }) "too few levels"
        }]
        ["score: 11 levels is an error" {
            assert equal (error-of { jev score "How?" (0..10 | each { $"level ($in)" }) }) "too many levels"
        }]
        ["score: a level needs a description" {
            assert equal (error-of { jev score "How?" ["low" null "high"] }) "invalid level"
        }]
        ["score: a level can be structured" {
            let levels = [{ summary: "One change" } { summary: "Several changes" }]
            assert equal (jev score "How focused?" $levels | get criteria) $levels
        }]
        ["noul: instructions cannot be empty" {
            assert equal (error-of { jev noul "" }) "empty instructions"
        }]
        ["noul: instructions are text or structure" {
            assert equal (error-of { jev noul 5 }) "invalid instructions"
        }]
        ["noul: one side can be described alone" {
            assert equal (jev noul "Urgent?" --no "No deadline" | get criteria) { "false": "No deadline" }
        }]
        ["ask: no questions is an error" {
            assert equal (error-of { "x" | jev ask {} }) "no questions"
        }]
        ["ask: a raw question gets the same checks" {
            assert equal (error-of { "x" | jev ask { u: { type: score, instructions: "How?", criteria: ["only"] } } }) "question u: too few levels"
            assert equal (error-of { "x" | jev ask { u: { type: maybe, instructions: "How?" } } }) "question u: unknown type"
            assert equal (error-of { "x" | jev ask { u: "Urgent?" } }) "question u: not a question"
        }]
        ["ask: noul sides named yes and no are caught" {
            let question = { type: noul, instructions: "Urgent?", criteria: { yes: "a", no: "b" } }
            assert equal (error-of { "x" | jev ask { u: $question } }) "question u: invalid criteria"
        }]
        ["ask: --model beats $env.JEV_MODEL beats jev-latest" {
            let questions = { u: (jev noul "Urgent?") }
            with-env { JEV_MODEL: null } {
                assert equal ("x" | jev ask --dry-run $questions | get model) "jev-latest"
            }
            with-env { JEV_MODEL: "jev-preview" } {
                assert equal ("x" | jev ask --dry-run $questions | get model) "jev-preview"
                assert equal ("x" | jev ask --dry-run -m jev-1.13.0 $questions | get model) "jev-1.13.0"
            }
        }]
        ["ask: no key is an error before anything is sent" {
            with-env { TYPESAFE_API_KEY: null } {
                assert equal (error-of { "x" | jev ask { u: (jev noul "Urgent?") } }) "no TypeSafe API key"
            }
        }]
    ]
}

# Checks against the stub. `posts` counts the requests the stub has seen since
# the check began.
def stub-checks [log: path]: nothing -> list<record> {
    let posts = {|| open --raw $log | lines | where $it == "POST /systemone" | length }
    let questions = {
        team: (jev choice "Which team?" { billing: null, technical: null })
        urgent: (jev noul "Urgent?")
        anger: (jev score "How angry?" ["Calm" "Furious"])
    }

    [
        [name check];
        ["ask: answers come back under the question ids" {
            let answers = "Payouts are failing" | jev ask $questions
            assert equal ($answers | columns) [team urgent anger]
            assert equal $answers.team.choice "billing"
            assert equal $answers.urgent.noul 0.9
            assert equal $answers.anger.legend { "0": "Calm", "1": "Furious" }
        }]
        ["ask: --full returns the model and the usage too" {
            let response = "Payouts are failing" | jev ask --full $questions
            assert equal ($response | columns) [model answers usage]
            assert equal $response.model "jev-stub.0"
        }]
        ["ask: state can be a record or a list" {
            assert equal ({ body: "x" } | jev ask $questions | get urgent.noul) 0.9
            assert equal (["hi" "x"] | jev ask $questions | get urgent.noul) 0.9
        }]
        ["ask: `insert` adds the answers to each row of a table" {
            let rows = [[id body]; [1 "a"] [2 "b"]] | insert jev { get body | jev ask $questions }
            assert equal ($rows | get jev.team.choice) [billing billing]
            assert equal ($rows | columns) [id body jev]
        }]
        ["ask: a 429 is retried, honoring retry-after" {
            assert equal ("x" | jev ask -m busy $questions | get urgent.noul) 0.9
            assert equal (do $posts) 2
        }]
        ["ask: retries stop at --max-retries" {
            assert equal (error-of { "x" | jev ask -m overloaded --max-retries 2 $questions }) "typesafe 529: Overloaded."
            assert equal (do $posts) 3
        }]
        ["ask: --max-retries 0 sends once" {
            assert equal (error-of { "x" | jev ask -m busy --max-retries 0 $questions }) "typesafe 429: Slow down."
            assert equal (do $posts) 1
        }]
        ["ask: a 422 names the field that failed" {
            assert equal (error-of { "x" | jev ask -m invalid $questions }) "typesafe 422: questions.severity.score.criteria.1.str: Input should be a valid string"
        }]
        ["ask: an error body that is not JSON still reports" {
            assert equal (error-of { "x" | jev ask -m broken $questions }) "typesafe 500: upstream exploded"
        }]
        ["ask: a bad key is a 401" {
            with-env { TYPESAFE_API_KEY: "wrong" } {
                assert equal (error-of { "x" | jev ask $questions }) "typesafe 401: Cannot authenticate with the server."
            }
        }]
        ["models: a table with a release date" {
            assert equal (jev models | select name released) [[name released]; [jev-latest 2026-09-10]]
        }]
    ]
}

# Run each @example that records a result, in a fresh nu, as the docs show it.
def example-results []: nothing -> list<record> {
    scope commands
    | where name starts-with "jev "
    | each {|command| $command.examples | insert command $command.name }
    | flatten
    | where result? != null
    | each {|example|
        let run = ^$nu.current-exe --no-config-file -c $"hide-env -i JEV_MODEL; use ($module); ($example.example) | to nuon" | complete
        let actual = try { $run.stdout | from nuon } catch { $run.stderr }
        {
            name: $"($example.command): ($example.description)"
            ok: ($run.exit_code == 0 and $actual == $example.result)
            error: (if $run.exit_code != 0 { $run.stderr | str trim })
        }
    }
}

def check-results [checks: list<record>, before: closure]: nothing -> list<record> {
    $checks | each {|c|
        do $before
        let error = try { do $c.check; null } catch {|e| $e.msg }
        { name: $c.name, ok: ($error == null), error: $error }
    }
}

# Serve the stub on a free port and wait for it to answer.
def start-stub [log: path]: nothing -> any {
    let port = port
    let job = job spawn {
        with-env { JEV_STUB_LOG: $log } { ^http-nu $"127.0.0.1:($port)" ($tests | path join stub.nu) | ignore }
    }
    let url = $"http://127.0.0.1:($port)"

    for _ in 1..50 {
        if (try { http get --allow-errors $"($url)/models" | ignore; true } catch { false }) {
            return { job: $job, url: $url }
        }
        sleep 100ms
    }
    job kill $job
    error make --unspanned { msg: "the stub did not start" }
}

def main []: nothing -> nothing {
    # A key or an endpoint in the caller's environment must not leak in.
    $env.TYPESAFE_API_KEY = "stub-key"
    $env.JEV_BASE_URL = "http://127.0.0.1:1"

    mut results = (example-results) ++ (check-results (offline-checks) {|| })

    if (which http-nu | is-empty) {
        print "http-nu is not on the PATH: skipping the checks that need the stub"
    } else {
        let log = mktemp --tmpdir jev-stub.XXXXXX
        let stub = start-stub $log
        $env.JEV_BASE_URL = $stub.url
        $results ++= check-results (stub-checks $log) {|| "" | save --force $log }
        job kill $stub.job
        rm $log
    }

    print ($results | select name ok)
    for failed in ($results | where not ok) {
        print $"(char newline)FAILED ($failed.name)(char newline)  ($failed.error)"
    }

    let failures = $results | where not ok | length
    print $"($results | length) checks, ($failures) failed"
    if $failures > 0 { exit 1 }
}
