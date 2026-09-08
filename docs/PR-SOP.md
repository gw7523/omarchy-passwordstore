# From a change to an upstream PR: the standing procedure

Upstream maintainers (hegjon for this plugin; the omamail maintainer has
made it a hard gate) increasingly refuse to review a UI change without
**clearly labelled before-and-after screenshots** in the PR description:
synthetic or redacted data, GitHub-hosted, the same view, interaction
state, window size, theme and scale on both sides, the visible differences
explained, every changed surface covered, and the images refreshed after
any further UI change. This is how a change goes from an idea to a PR
that meets that bar.

## 1. Implement

- One feature per branch, cut from `personal`, in its own worktree
  (`git worktree add ../omarchy-passwordstore-<name> -b feat/<name> personal`).
  Stack a second branch on the first only when it edits the same code.
- Helpers first (bash, JSON out, secrets on pipes), then the card (QML),
  then `manifest.json` (defaults and schema for any setting), then the
  README section and key table. `CLAUDE.md` gets a line when something bit.
- File the issue first if it is not already there; the commit message and
  PR body say which issue they close.

## 2. Test

Run all of these on the branch before anything else; the cheap lane
(`runner` subagent, or `tl-run`) keeps the output out of the way.

```
unset -f grep find      # Claude Code's shell shadows both; see CLAUDE.md
test/lint               # qmllint on every .qml
test/test-manifest
test/test-list
test/test-action
test/test-setup
test/test-pinentry
omarchy-plugin-validate .
npx -y shellcheck --severity=warning passwordstore-* test/test-*
```

Then the headless instantiation (the scratch harness: `qs -p` on a config
directory with `Commons`/`Ui` symlinked to the shell's and a stub `shell`
object; it catches QML errors qmllint cannot) and, for anything the tests
cannot reach, a live run with someone standing by the seat, every
keystroke gated on the layer set being exactly background, bar and card.

Then the adversarial review: a `grok-build:grok-delegate` read-only run
over `git diff personal..feat/<name>`, told what the change is and what
must hold (secrets never on argv or in logs, nothing typed into the wrong
window, and so on). Fix what it finds as the branch's second commit; one
re-review if the fixes were large. The PR body says this happened.

## 3. Capture

`test/capture` produces the evidence the maintainer asks for, the same
way every time:

```
test/capture --list                                   # the scenes
test/capture --scene search --label before --branch personal
test/capture --scene search --label after  --branch feat/<name>
test/capture --join docs/pr search                    # search.png, side by side
```

What it does, so the images are comparable:

- A **synthetic vault** (empty `*.gpg` files, or three real entries under a
  throwaway key whose passphrase the tool knows, for scenes that decrypt),
  fixed names, fixed recent list, and only that vault on the bar entry for
  the run: no real entry, path, backend or vault name is on screen. The
  tool refuses to send a key until the helper confirms the card is on the
  synthetic store, and stops at the first failed step.
- The **same window**: the card, cropped to the box it publishes itself
  (`writeCardGeometry`, switched on for the run), so nothing behind it is
  in the image and the size is the card's.
- The **same theme and scale**: whatever the seat has; run `before` and
  `after` in one sitting, and say which theme it was in the PR.
- The **same interaction state**: a scene file is a fixed key script
  (`test/capture.d/<scene>`), so both sides reach the identical state.
- **Labelled**: each image carries BEFORE or AFTER across its top;
  `--join` puts them side by side.
- **Safe**: `--branch` detaches the checkout the plugins symlink points
  at (not the worktree the tool runs from) at the branch and restarts the
  shell, then puts everything back, on Ctrl+C as well; the tool aborts
  before any keystroke if another layer (a menu, a prompt) is up, and the
  `pin` step only answers a prompt when the card's own pinentry is the sole
  layer up.

The crop needs the card's box, which the card writes only from the commit
that added `writeCardGeometry`: a "before" older than that cannot be
captured by the tool; describe it, or capture it by hand with a fixed
crop as `CLAUDE.md` explains.

Not capturable this way: the GPG keys page lists the seat's real keyring
(names, fingerprints); take that one by hand on a seat with a throwaway
keyring, or describe it in words.

One scene per changed surface: the search card, the row menu, the editor,
the share card, the setup hub, the GPG page. Add a scene file when a
feature adds a surface; a scene is five lines. Re-capture after any
further UI change, and say so in the PR.

Someone must be at the seat and not using the keyboard while it runs; the
tool prints the same guard abort the live tests do.

## 4. Submit

- Commit the images under `docs/pr/<scene>*.png` on the PR branch, then
  attach them to the PR description in the browser (drag and drop): that
  is what "GitHub-hosted" means to a maintainer, and it survives a
  rebuilt or force-pushed branch. A `raw.githubusercontent.com` link to
  the branch works as a stopgap while the branch exists.
- The PR body, in this order: what changed and why (two paragraphs); a
  **Before / After** section, one joined image per scene with a sentence
  under each saying what differs and why; the security note (what never
  leaves the machine, what the review found and what was fixed); tests
  run with counts; "Builds on #N" when stacked (GitHub cannot stack across
  forks, so each PR carries the earlier commits and says which commit is
  new).
- Open against upstream `master` from the fork's `upstream/<name>` branch,
  which is `personal`'s tree at the feature's merge commit rebranded to
  upstream's plugin id (the `rebrand` recipe in the session notes), never
  the fork-identity branch itself.
- After a review: fix on the branch, re-run step 2, re-capture any changed
  surface, push, and answer the thread with what changed per finding, the
  way the omamail threads do ("Rebased on `<sha>`, the three findings
  addressed: 1. … 2. …").

## Checklist for the PR body

```
- [ ] Issue linked; one feature
- [ ] Lint, manifest, list, action, setup, pinentry, validate, shellcheck: counts in the body
- [ ] Headless instantiation and, where it matters, a live run
- [ ] Adversarial review run; fixes are the second commit
- [ ] Before/After image per changed surface, labelled, same theme/scale, synthetic data
- [ ] Each image has a sentence on the visible difference
- [ ] Images refreshed after the last UI change
- [ ] Security note: what never leaves the machine
- [ ] "Builds on #N" and which commit is new, if stacked
```
