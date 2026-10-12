# Public behavioural specifications

This directory holds the behavioural specifications that describe what Prism
should do. They are the only behavioural reference contributors may rely on
(see the clean-room rule in [CONTRIBUTING.md](../../CONTRIBUTING.md)).

## Publication boundary

Prism is developed under a clean-room process that separates material which
may be published from material which must stay private.

**Public — committed to this repository**

- the implementation (all Swift sources, scripts and build configuration);
- the tests, including the golden test corpus and the generators that produce
  it from our own synthetic inputs;
- scrubbed behavioural specifications in this directory, written from scratch
  in our own words, describing features in terms of user-observable behaviour.
  They name no internal classes or methods of any other product and contain no
  screenshots or other images.

**Private — never committed**

- reference screenshots and screen recordings of other applications;
- menu and keyboard-shortcut dumps captured from other applications;
- raw observation notes and measurements taken while studying them;
- the evidence-bearing working specifications those notes support;
- reference material gathered while building throw-away prototypes.

Private material is kept outside the repository. The CI clean-room guard
(`scripts/ci/check-cleanroom.sh`) rejects paths under `reference/` or
`docs/spec/`, files named like private notes, any image file anywhere in the
repository (the app icon is drawn at build time), and identifiers that look
like they were taken from another product.

## Writing a specification

- Describe behaviour from the user's point of view: inputs, what appears on
  screen, and the resulting state.
- Use your own words and Prism's own terminology; do not quote user-interface
  text from other applications.
- Do not include images. If a layout needs explaining, describe it in prose or
  with a simple text diagram.
- Name files after the feature area, for example `text-compare.md` or
  `folder-compare.md`.
