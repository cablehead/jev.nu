#!/usr/bin/env nu
#
# Triage a repository's open issues: say what each one is, then rank the bugs.
# It only reads.
#
#   nu examples/triage.nu nushell/nushell

const jev = path self | path dirname | path dirname | path join jev

use $jev

# The questions asked about each issue. `repro` and `severity` only matter for
# bugs. They are asked about every issue anyway, because that is cheaper than a
# second request for just the bugs.
def questions []: nothing -> record {
    {
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
}

# Add jev's answers to each issue, under `jev`
#
# `insert` alone would work, making the requests one at a time. `par-each` makes
# them all at once, which took 0.4 seconds for 12 issues instead of 4.
def triage []: table -> table {
    let questions = questions
    # Keep a long pasted log from using up the token budget.
    $in
    | update body { str substring 0..3000 }
    | par-each --keep-order {|issue| $issue | insert jev { select title body | jev ask $questions } }
}

# The bugs jev is sure about, most pressing first
#
# Severity is weighted 0.7 and having a repro 0.3. The score runs from 0 to 2,
# so `/ 2` brings it to the same 0 to 1 range as the noul. If the ranking looks
# wrong, change the weights.
def prioritize []: table -> table {
    where jev.kind.choice == bug and jev.kind.confidence > 0.8
    | insert priority {|issue| 0.7 * $issue.jev.severity.score / 2 + 0.3 * $issue.jev.repro.noul }
    | sort-by priority --reverse
}

def main [
    repo: string        # owner/name
    --limit: int = 12   # How many of the newest open issues to read
]: nothing -> table {
    gh issue list --repo $repo --limit $limit --json number,title,body
    | from json
    | triage
    | prioritize
    | select number title priority
}
