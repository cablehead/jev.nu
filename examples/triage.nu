#!/usr/bin/env nu
#
# Triage a repository's open issues: say what each one is, then rank the bugs.
# Reads with `gh` and changes nothing.
#
#   nu examples/triage.nu nushell/nushell

const jev = path self | path dirname | path dirname | path join jev

use $jev

# The judgments, in one place. `repro` and `severity` only matter for a bug, and
# are asked of every issue anyway: a question costs a few tokens, a second
# request costs a round trip.
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
# `insert` alone would do, one request after another. `par-each` sends them
# together: 12 issues in 0.4 seconds rather than 4.
def triage []: table -> table {
    let questions = questions
    # A pasted log can run past the 32k token budget, and adds nothing here.
    $in
    | update body { str substring 0..3000 }
    | par-each --keep-order {|issue| $issue | insert jev { select title body | jev ask $questions } }
}

# The bugs jev is sure about, most pressing first
#
# Severity counts for more than having a repro. The weights are the policy:
# change them here, not in a prompt. `/ 2` puts the three-level score on 0 to 1.
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
