## What changed

<!-- One or two sentences. Which files and why. -->

Fixes #

## How it was tested

<!-- Tick what you did. Give the numbers from your runs below. -->

Where:

- [ ] two copies of the game on one PC (host and friend)
- [ ] two PCs over Steam
- [ ] native tests: `native\coop_patch\build.cmd test "<path to the game exe>"` and/or `native\coop_steam\build.cmd test`

How:

- [ ] real click (mouse in the game)
- [ ] press (the game's own button handler)
- [ ] console (the game function called from a console)

Cases:

- [ ] host to friend
- [ ] friend to host
- [ ] after a resync
- [ ] a short run at speed 4 with a demolish: no resync, no error, no crash

## Results

<!-- Numbers: what you compared, how many differed, the longest delay, crash records before and after. -->

## The host rule

- [ ] **A friend never shows a value the host never had.** I checked this for the values my change touches.

## Checklist

- [ ] No read past the end of a game array (`#arr` checked first).
- [ ] Every game object is checked alive in the frame it is used. Nothing kept across a load.
- [ ] Nothing ships switched off. No test-only code in the player zip.
- [ ] No Windows user names, local paths, Steam names or crash records in the commit.
- [ ] `C.version` changed in `coop.lua` if players must update.
- [ ] `docs/KNOWN_ISSUES.md` updated if a known issue changed.
