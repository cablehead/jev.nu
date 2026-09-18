#!/usr/bin/env nu
#
# Run every @example in the jev module that records an expected result.
#
# The builders are pure, so their examples double as the test suite. Examples
# that reach the API carry no --result and are skipped: they cost money and
# their answers move with the model.

const module = path self | path dirname | path dirname | path join jev

use $module

def main [
    --verbose (-v)   # Show the examples that were skipped
]: nothing -> nothing {
    let cases = scope commands
        | where name starts-with "jev "
        | each {|command|
            $command.examples | each {|example| {
                name: $command.name
                description: $example.description
                example: $example.example
                result: ($example.result? | default null)
            } }
        }
        | flatten

    let checkable = $cases | where result != null
    let skipped = $cases | where result == null

    let results = $checkable | each {|case|
        let run = (
            ^$nu.current-exe --no-config-file -c $"use ($module); ($case.example) | to nuon"
            | complete
        )

        let actual = if $run.exit_code == 0 {
            try { $run.stdout | str trim | from nuon } catch { $run.stdout | str trim }
        } else {
            $run.stderr | str trim
        }

        {
            name: $case.name
            example: $case.description
            ok: ($run.exit_code == 0 and $actual == $case.result)
            expected: $case.result
            actual: $actual
        }
    }

    let failed = $results | where not ok

    print ($results | select name example ok)

    if $verbose and ($skipped | is-not-empty) {
        print $"skipped ($skipped | length) examples with no recorded result:"
        print ($skipped | select name description)
    }

    if ($failed | is-not-empty) {
        for f in $failed {
            print $"(char newline)FAILED ($f.name): ($f.example)"
            print $"  expected: ($f.expected | to nuon)"
            print $"  actual:   ($f.actual | to nuon)"
        }
        exit 1
    }

    print $"($results | length) passed, ($skipped | length) skipped"
}
