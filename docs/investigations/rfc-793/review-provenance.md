# RFC #794 review provenance

This file sits outside the RFC on purpose. It records what each review
actually read, so that findings are attributed to the right document. The RFC
never states its own hash. Hashes are SHA-256 of `RFC-EVENT-DRIVEN-ANIMATION.md`
as committed (`git show <commit>:RFC-EVENT-DRIVEN-ANIMATION.md | shasum -a 256`)
or of the job artifact (`sha256sum`, read inside the pipeline container).

| Review job | Committed RFC (PR head) | Document the reviewers read | Same document? |
| --- | --- | --- | --- |
| `labelle-toolkit-labelle-engine-794-2513e3f5-be0991ea` ([comment](https://github.com/labelle-toolkit/labelle-engine/issues/794#issuecomment-6713999997)) | `2513e3f593015526cc832d247fdbf6f8bdc2f0f6`, 1215 lines, `7640f06ac93bb2e73633e0e1635ab28c2a0cc400bbaf43af7553120ef502d35d` | the author rewrite `current-rfc.md`, 1402 lines, `26b73c7bd8d00959f9afd09dae426fe39f42e000cf9b03f71143ede9c940674f` (hash as reported by the job) | No |
| `labelle-toolkit-labelle-engine-794-a5dd7f8b-be0991ea` ([comment](https://github.com/labelle-toolkit/labelle-engine/issues/794#issuecomment-6714741823)) | `a5dd7f8b0301e47d6b69c186a01a04fb7465a631`, 1561 lines, `9c2ae0369f1c9f9f0f1ff6738b80ecb5ab1c0a7130f4436956f4c3f9eb6c57ba` (equals the job's `inputs/pr-source` copy and the author's starting `current-rfc.md`) | the author rewrite `proposal.md` (also every reviewer's `current-rfc.md`), 1611 lines, `c43fc6e5d5c690a11ca42009e76910537adf34c53f76cbd5673ede3b6cf3fc77` | No |

## What the `a5dd7f8b` rewrite added

`diff <committed a5dd7f8> <proposal.md>` gives 80 changed lines. Everything the
rewrite added or changed is listed below. Findings that rest only on these
lines are findings against the rewrite, not against PR #793:

- A status paragraph saying three product questions remain undecided.
- A provenance paragraph claiming the reviewed copy "matches the committed file
  in section headings and line positions" and stating the hash `9c2ae036…`.
  That is the committed file's hash, not the copy's, so the claim is false.
  The paragraph also added a note on a Codex thread and the job.
- A third undecided item, `code-level-identity-forging`, with options and an
  author recommendation, plus a cross-reference to it from section 4.
- Stable identifiers on the two committed ambiguity items.
- A readiness item "Owner decides the three open product questions" and a
  job-specific pipeline readiness item.
- Two small textual edits: a citation `:79-85` changed to `:79-84`, and a
  "(it still has no `animation/` directory)" note.

Review findings caused by the rewrite:

- `rfc-provenance-mismatch` (claude), `astra-document-provenance`,
  `provenance-mismatch-with-pr-head-a5dd7f8` (gemini) and
  `reviewed-copy-not-pr-head` (deepseek);
- `uncommitted-third-owner-decision` (deepseek);
- the `code-level-identity-forging` entries under "Decisões pendentes";
- the "three" count in `open-owner-decisions-block-approval` (claude). The
  committed file had two undecided items.

All other findings in that review apply to the committed file. The November 8
second-pass corrections address them.

## Independent single-agent review of `395e90a`

This was not a pipeline job and not one of the four reviewers. A fresh agent
reviewed the committed file at `395e90a3cd8dece5c07a71ea2f2017701784aa93`
(read with `git show`) against `be0991e`, without the author's reasoning. Its
verdict was changes requested. Blocking: decision 16 had no normative text.
Suggestions covered the stopped playback id, `play` composition,
frame-zero deferring states, script set against parked removal, the saveable
sibling's authorable identity fields, the decision 13 citation basis, and
`start` placement. It verified 36 citations. The next commit applies its
findings, except nit N2, which was incorrect: the author option list does
label 13(c) as revising the independent pause.
