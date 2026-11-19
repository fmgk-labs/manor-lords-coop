# Known issues and limitations

Manor Lords Co-op **0.2.1** (v1, beta for testing with friends). Game version **0.8.117** only.

Checked against the project's test records on 2026-11-17. Every number here comes from a recorded test run.
Where nothing was run, this page says "never tested".

**0.2.1 was tested by the lead:** one full session (every pause equal) and two installs from the release zip (join, 5 resyncs, a rejoin; no crash). The speed change in 0.2.1 (item C1) did not come up in those runs, so it is not yet seen working in a game.

## How to read this page

Each item has four lines:

- **You see**: what a player notices.
- **Numbers**: how often, how far, how long.
- **Basis**: where the numbers come from (see the table).
- **Workaround**: what you can do.

| Basis | Meaning |
|---|---|
| Owner's live play | The mod's owner played with a friend on two PCs over Steam, with real clicks. |
| Lead's run | The project lead ran it on **test copies**: two or more copies of the game on **one PC**, started by scripts. |
| Helper's run | A helper ran it on test copies and wrote a report. The lead read the report. |
| Never tested | Nobody has run it. |
| Code reading | Found by reading the code. Not run. |

Words used below:

- **Host**: the player whose save is the town. **Friend**: a player who joined.
- **Copy**: one running game.
- **Resync**: a copy loads the host's state again. A banner says "Syncing with the host".
- **Pause check**: the lead pauses both copies and compares the numbers one by one.

## What has been done for real

- **Done by the owner in live play** (two PCs, over Steam, with a friend, real clicks): the title menu's **Co-op** button, **Host From Save**, and a friend **joining over Steam**.
- **Measured on test copies:** everything else on this page. The measured numbers below come from two copies on one PC.

---

## A. What was never tested

### A1. Three or more players

- **You see:** unknown.
- **Numbers:** never with 3 or more real players. 5 copies on one PC ran 40 minutes with nobody acting, on an older build. The lobby takes 8 players; 6 to 8 never ran.
- **Basis:** never tested with real players. Lead's run with 5 copies.
- **Workaround:** start with one friend. Add more friends one at a time.

### A2. Long sessions and late-game towns

- **You see:** unknown.
- **Numbers:** never a session of hours. Never a late-game town. The lead's checks are about 18 minutes of play each. The test town has about 55 to 60 people.
- **Basis:** never tested.
- **Workaround:** the host saves often. Report anything odd with the time it happened.

### A3. The long tail

- **You see:** unknown.
- **Numbers:** never run: a grain harvest; a save with two rival towns; two players clicking at the same instant; maps other than the test map; 9 player actions never clicked with a real mouse (section E).
- **Basis:** never tested.
- **Workaround:** none. Reports from these cases help most.

---

## B. Small differences the owner accepted ("soft bars")

The owner's bar: a friend sees the **host's value within about 3 seconds**, and never a value the host never had.
For squads and villagers the owner set softer bars on 2026-11-16. These items pass them.

### B1. Squads a few metres off

- **You see:** a squad on a friend's screen stands a few metres from the host's, for a few seconds. In a squad's first second (a call-up, a new bandit camp) up to about 12 m.
- **Numbers:** the bar: 99 % within about 3 m, no stretch over 3 m longer than about 5 s. Final tests: 3 of 5 passed in full; the other two had 11.7 m in a squad's first half second and 6.1 m for 1 s.
- **Basis:** lead's runs and helper's runs.
- **Workaround:** none needed. **Report** a squad off for many seconds, missing men, a wrong head count, or a rout that differs.

### B2. Villagers a few seconds out of step

- **You see:** a villager on a friend's screen starts, ends or carries a few seconds before or after the host's. Mostly gatherers and carriers.
- **Numbers:** out of step per test session: about 46 s at speed 4 (206 s before the fix), about 62 s at speed 8 (121 s before). Stock, totals, population and goods in hands: equal at 15 of 15 pause checks.
- **Basis:** helper's runs and the lead's last five sessions.
- **Workaround:** none needed. **Report** a number that differs (stock, treasury, population), not a villager's step.

### B3. Free merchants a few metres off

- **You see:** a travelling merchant (one man who walks between regions) a few metres from his place on the host's screen.
- **Numbers:** 99 % within 2.4 to 2.7 m in 10 of 12 test windows. Right after a rejoin: up to 4.5 m (99 %), largest 5.2 m.
- **Basis:** helper's runs. Not measured: during a friend's resync.
- **Workaround:** none needed.

### B4. Numbers arrive a moment late on a friend

- **You see:** a number on a friend's screen (stock, a total) changes shortly after the host's.
- **Numbers:** longest delay 1.66 to 1.86 s in the lead's last five sessions. 0 values the host never had.
- **Basis:** lead's runs.
- **Workaround:** none needed.

---

## C. Game speed

### C1. The game slows to speed 1 when an enemy is spotted

- **You see:** the game drops to speed 1 for everybody when bandits or raiders appear.
- **Numbers:** the plain game does this too; speed is shared, so the host's drop reaches everyone. Since 0.2.1 a friend's own drop is no longer sent to the others.
- **Basis:** plain game measured without the mod; lead's runs. The 0.2.1 change did not come up in the 0.2.1 runs.
- **Workaround:** any player presses the speed button again.

### C2. Drops to speed 1 with no known cause

- **You see:** the game goes to speed 1 by itself, with no enemy in sight.
- **Numbers:** 7 drops with no explained cause, in the lead's study of one test session.
- **Basis:** lead's run.
- **Workaround:** press the speed button again. Report it with the time.

---

## D. Hidden values that differ

### D1. The region's squad count after a resync

- **You see:** nothing. No screen shows this count. The game's "enemies present" and "under attack" flags were equal everywhere.
- **Numbers:** after a rejoin, a hidden per-region squad count differs in 5 to 7 regions, by at most 2 to 4. Every differing entry was a free merchant (264 of 264).
- **Basis:** helper's runs. Left as it is on purpose.
- **Workaround:** none needed.

### D2. The job board's villager names

- **You see:** possibly a friend's villager doing a task the host gave to another villager.
- **Numbers:** in one test session, 2 of 58 of the board's villager names pointed at another family on the friend's copy.
- **Basis:** helper's run, read by hand. Open, not a v1 blocker.
- **Workaround:** none.

---

## E. Player actions never clicked with a real mouse

The mod carries these, but nobody clicked them in the game on two copies. The owner moved them to the beta on 2026-11-15.

| Action | What is known |
|---|---|
| Attack a building or a gate, raid a region, loot a bandit camp | A click on a camp with bandits in it attacks the bandits instead. The building order was never clicked. |
| Extend a house plot | No control in 0.8.117 starts it. Tested from the console only. |
| Draw a bailey plot | Tested from the console only. Needs clicks on the ground. |
| Pack train destination | Tested from the console only. |
| Trade partner limit | No control in 0.8.117. Tested from the console only. |
| Cancel a livestock order | Never run. The control was not found. |
| Declare war directly | War by letter was clicked. The direct control was not found. |
| Declare peace | Clicked host to friend. Friend to host never clicked. |
| Settle a new region | Tested from the console only. Ends in a resync of every copy, by design. |
| Unit editor | **Not carried.** It changes only your own copy. |

- **Numbers:** of 140 player actions: 83 proven both ways, 32 carried but not proven both ways, 1 not carried, 24 need nothing (2026-11-16).
- **Basis:** the project's coverage table.
- **Workaround:** let the host do these actions. The host's copy is the one that is saved.

---

## F. Crashes and freezes not explained

### F1. A friend's crash in the first live session (2026-11-11)

- **You see:** the friend's game closed.
- **Numbers:** once, on a private build before 0.2.x. The friend's crash report was never received.
- **Basis:** owner's live play.
- **Workaround:** none. If your game closes, start it again, press **Make Bug Report** in the Co-op menu and send the zip (see [REPORTING_BUGS.md](REPORTING_BUGS.md)).

### F2. One friend close in a test build

- **You see:** the friend's game closed about 80 s after a resync.
- **Numbers:** once, in a test build. Not seen again in 6 test runs after the next fix, nor in 4 of 4 runs of the player zip.
- **Basis:** helper's runs.
- **Workaround:** none.

### F3. A friend's game stood still for 9 s

- **You see:** the friend's game freezes for several seconds. The host may show "left the game" by mistake.
- **Numbers:** seen once (9 s), and 5.9 s once before. Not seen again in 17 sessions. Cause unknown.
- **Basis:** helper's runs.
- **Workaround:** none. Send the logs if it happens.

### F4. The host's autosave stops the game for a few seconds

- **You see:** when the host's game autosaves, it stands still for a few seconds. Friends wait too.
- **Numbers:** 4.77 s measured once, at the game's 600 s autosave timer.
- **Basis:** helper's run. This is the plain game's autosave.
- **Workaround:** none needed.

### F5. A called-up militia squad missing on a friend

- **You see:** after a call-up, the militia squad is missing on a friend's screen.
- **Numbers:** seen twice, for 43 s. Since a fix (a call-up is tried again after 2 s): 20 call-ups and 20 send-homes, none lost.
- **Basis:** helper's runs.
- **Workaround:** none needed now. Report it if you see it.

---

## G. Smaller open items

### G1. Region grant into storage, and livestock goods

- **You see:** nothing in normal play.
- **Numbers:** both were fixed in the fall-back rule, which runs only when the mod's native part is off. In normal play that rule did not run once.
- **Basis:** helper's runs. Not checked again since.
- **Workaround:** none needed.

### G2. List positions handed to the game's own functions

- **You see:** nothing seen so far.
- **Numbers:** five game functions (`SetFamilyHome`, `assignFamily`, `unassignFamily`, `reassignFamily`, `removeWorkerFamilyAt`) get a list position from the mod without a length check. What the game does with a wrong one is not known.
- **Basis:** code reading.
- **Workaround:** none.

### G3. A region that changes hands

- **You see:** three neutral buildings of the region change owner a day late on a friend's copy. After a region is won, a friend's copy may load the host's state once (about 11 s).
- **Numbers:** the reload was seen in 3 of 3 runs on an older build.
- **Basis:** helper's runs. Not tested again since.
- **Workaround:** none needed.

### G4. Game warnings on a friend's copy

- **You see:** a friend may not get the game's own warning messages for approval under 20, or for low food or fuel.
- **Numbers:** not seen in a run.
- **Basis:** code reading. A friend's region numbers come from the host, so the game's own check does not run there.
- **Workaround:** the host watches these warnings.

### G5. Host New Game: friends resynced again and again (0.2.2; changed in 0.2.3)

- **You see (0.2.2):** after **Host New Game**, each friend sees "Syncing with the host" every minute or two. The host's game saves each time.
- **Numbers:** first public new game (host and two friends): 6 resyncs of one friend at a time in 6 minutes, none helped. After every copy loaded the save once, 0 resyncs in the next 6 minutes. The cause: a world the game has just made differs from the same world loaded from its save. Five buildings near the start camp had no owner on the host and the player as owner on each friend.
- **0.2.3:** about 10 s after a new game is up, the host's game says "Preparing the new game for co-op..." and saves and loads it once (a few seconds). A friend who joins in that time waits and comes in with that load. A game loaded from a save is never prepared. A friend whose load alone did not help now goes straight to a load of every copy (in 0.2.2 it could take six loads).
- **Basis:** owner's live play (0.2.2). 0.2.3: lane 63's runs on test copies (one PC): 6 of 6 new games prepared (a load of about 6 to 7 s), the friend who said hello meanwhile came in with that load, 20 of 20 days equal and 0 resyncs at speed 4 in 3 runs. A control run without the preparing showed the same kind of difference (14 region settings 0 on the host, 359 on the friend, every day). The five unowned buildings of the live game did not show up on the test map.
- **Workaround (0.2.2):** host a new game, save it, and load that save with **Host From Save** before you invite friends.

### G6. A difference a resync cannot fix

- **You see:** once: "The games differ in a way a resync cannot fix (buildings). Play goes on. Please send a bug report: Co-op > Make Bug Report."
- **Numbers:** 0.2.3 shows it when the same difference is still there after every copy loaded the host's save. Then no resync for that kind of difference for 15 minutes, and after that at most one per hour. On test copies with a made-up lasting difference: 3 of 3 runs went one load alone, one load of every copy, then the notice once and 0 saves or loads in the next 5 minutes.
- **Basis:** lane 63's runs on test copies (the difference was made by a test switch, not a real one).
- **Workaround:** play on. Every player presses **Co-op > Make Bug Report** and sends the zip. The host's zip has the difference as the friend saw it.

### G7. A rival lord's new marketplace is on the host only

- **You see:** a marketplace a rival lord builds after your friend joined is on the host's map and not on the friend's. It comes to the friend with the next load of the host's save.
- **Numbers:** seen once in the first public new game (one marketplace of one rival lord). The mod makes a rival's other new buildings on a friend's copy, but not marketplaces, fields and pastures (drawn plots).
- **Basis:** owner's live play (seen in a friend's log); the reason by code reading. It never causes a resync: the daily comparison looks at the player's own town only.
- **Workaround:** none needed.

### G8. A notice shows twice on a friend for a few seconds (0.2.4; fixed in 0.2.5)

- **You see:** on a friend, "Another Ruler's Army was sighted." or "Enemy Unit has been spotted!" shows as two lines for 2 to 6 seconds, then one. The host shows one.
- **Numbers:** 0.2.4: on test copies with real clicks, 3 cases in 8 minutes at speed 4. In 0.2.3 the second line stayed. Every other kind of notice shows once, with the host's words and building.
- **Basis:** lane 63's real-click run on the 0.2.4 zip; lane 66's runs. The friend's own line leaves the notice list at once but stays drawn for a few seconds.
- **Workaround:** none needed.

### G9. A game event window on a friend only (fixed in 0.2.5)

- **You see:** a friend may get the game's "Cold!" or "Hunger!" window while the host does not. It stays until **Close** is clicked.
- **Numbers:** seen in 3 test runs on one friend copy. Each copy decides these windows from its own fuel and food numbers, once per 180 days.
- **Basis:** lane 66's reading of the game file; lane 63's real-click runs.
- **Workaround:** click **Close**. The host's numbers are the true ones.

### G10. The building panel's "Yield" line differs (fixed in 0.2.5)

- **You see:** a building's "Yield" can read "None" on a friend and "Modest" on the host, or "Excellent" against "Average".
- **Numbers:** seen on a Logging Camp, a quarry and a sawpit on test copies. Productivity, maintenance and stock are equal; only the yield word differs.
- **Basis:** lane 67's runs: the line reads each copy's own 30-day production log, which is not carried yet (being built).
- **Workaround:** read the host's panel.

### G11. An open panel and another player's change

- **You see (0.2.2 and 0.2.3):** another player changes a value in a panel you have open (a field's priority, a trade rule, a worker count). The value is right at once, but your panel shows the old one until you close it and open it again.
- **0.2.5:** the open panel redraws itself within a moment of the change, with the game's own redraw. It waits while you hold a button or a slider, have a drop-down open, type in a box, or for half a second after your own click.
  - **Redraws:** building panels and every tab (the building's own settings, and the region's trade rules, limits, taxes and workers); the region panel and the lord panel (taxes, policies, perks, region name, war and peace); the development tree (perk and policy cards, region name, trade summary); claims; the army panel and the mercenary panel (a friend's orders on the host, a player's behaviour stance on every copy, squad names, the retinue).
  - **Left to the game's own redraw (not checked):** on a friend, the host's push stance and skills (the game's own functions ask for the redraw themselves).
  - **As in the plain game:** the approval breakdown redraws once a day.
  - **Not carried at all:** joining two castle walls in the castle planner.
  - **If you both change one value:** the host's order of arrival decides, as before. Your panel shows the final value after you let go.
- **Basis:** helper's runs on test copies (two copies, one PC, scripts only): a field's priority 9 of 9 (the friend's panel redrawn 40 to 70 ms after the host's line), workers 2 of 2, the chosen tab kept 3 of 3, region and lord panels 3 of 3, development tree 6 of 6, behaviour stance 6 of 6, mercenary panel redrawn with the army panel; with nobody acting 0 redraws over 9 game days, 3 times. Never tested: a held button, a dragged slider, an open drop-down and typing with a real mouse; a scrolled list.
- **Fixed with it:** with a field's panel open on two copies, the field's fertilization setting went back and forth between them and could swallow the host's own field priority click.
- **Workaround (0.2.2 and 0.2.3):** close the panel and open it again.

### G12. Some host notices missing on a friend (0.2.4 and 0.2.5)

- **You see:** the host's notice list shows "Storage is full (Storehouse)" or "No storage space left for production (Sawpit)"; a friend's list shows fewer lines, or "No recent events.".
- **Numbers:** on two test saves the friend lacked 1 and 3 of the host's notices.
- **Basis:** the release panel check on 0.2.4 and 0.2.5 (two copies, one PC). Cause found: a friend's own list clean-up removed the notices copied from the host. Fix being built for 0.2.6.
- **Workaround:** read the host's list.

### G13. Another lord's army count late on a friend

- **You see:** another lord's army can show more soldiers on a friend than on the host for up to about 4.5 seconds, for example 36 against 0 after a fight.
- **Numbers:** 27 of 43,335 readings in one test session were outside 3 seconds.
- **Basis:** helper's runs on test copies. Fix being built for 0.2.6.
- **Workaround:** none needed; it settles by itself.

### G14. An animal that starves

- **You see:** when a sheep or cow starves, the notice reaches a friend, but the animal stays alive there about 30 seconds longer and its body is not shown.
- **Basis:** helper's runs on test copies. Fix being built for 0.2.6.

### G15. Mourning and new villagers after a friend's reload

- **You see:** right after a friend reloads, a home's mourning days can read wrong for a short time, and a new villager can appear on the friend several seconds after the host.
- **Basis:** helper's runs on test copies. Fix being built for 0.2.6.

### G16. A friend can keep extra free merchants

- **You see:** after a reload a friend can show more free merchants than the host. They are not removed, to keep the merchants the host also has safe.
- **Basis:** helper's runs: with removal on, a friend could delete a merchant the host still had; 0.2.5 keeps them all (3 of 3 reloads equal at 21 merchants). A safe removal is planned for 0.2.6.

### G17. A rare resync after a demolition (0.2.4 and 0.2.5)

- **You see:** once in a test session, a demolition made a friend resync (a short reload).
- **Basis:** helper's run on test copies: the building's name was lost before the line was sent. The same code is in 0.2.4. Fix being built for 0.2.6.
- **Workaround:** none needed; the resync repairs it.

### G18. Hand carts for gatherers on a friend

- **You see:** on a friend, a gatherer may carry by hand where the host's uses a hand cart; the carts drawn are the host's.
- **Basis:** helper's runs: task given 15 of 15, the cart back at the host's stand 12 of 13. Being built for 0.2.6.

### G19. A trade limit changed by another player, with the Trade tab open (0.2.5)

- **You see:** another player changes a trade limit while you have the same building's Trade tab open. The value is right in the game, but your open panel keeps showing the old number.
- **Numbers:** 1 of 1 try with real clicks on the 0.2.5 zip (10 to 11; the open panel still showed 10 minutes later). Worker counts in an open panel did redraw (2 of 2).
- **Basis:** the real-click check on test copies. Fix being built for 0.2.6.
- **Workaround:** close the panel and open it again.

---

## H. Other limits

### H1. Game version 0.8.117 only

- **You see:** after a game update the mod may stop working.
- **Numbers:** the native part checks 77 code patterns at start. If one does not match, that part switches itself off and writes nothing.
- **Basis:** design (`native/coop_patch/README.md`).
- **Workaround:** wait for a mod update. Every player needs the same game version and the same mod version. A different mod version is refused at the join.

### H2. Windows and Steam only

- **You see:** the mod does not work with Game Pass or other stores.
- **Numbers:** tested only with the Steam version on Windows.
- **Basis:** design. The link uses the game's own Steam library.
- **Workaround:** start the game through Steam. A double-click on the `.exe` breaks invites.

### H3. The bundled mod loader

- **You see:** the download replaces three files of a loader you already have: `dwmapi.dll`, `ue4ss\UE4SS.dll` and `ue4ss\UE4SS-settings.ini`.
- **Numbers:** the older loader build on the loader's Nexus page closes the game with this mod. Over an older loader, one other (dummy) mod still started.
- **Basis:** lead's runs. Loader release 4.0.0 ran once on test copies.
- **Workaround:** back up `dwmapi.dll` and the `ue4ss` folder before you unzip.

### H4. Only the host saves

- **You see:** a friend's own save button does not save the co-op town.
- **Numbers:** by design.
- **Basis:** design.
- **Workaround:** a friend uses **Esc > Co-op > Keep a Copy of This Save**. The copy shows under Load Game.

### H5. When the host leaves, everybody leaves

- **You see:** "The host left the game. Returning to the main menu."
- **Numbers:** a friend decides on the host's goodbye, or after 30 s of silence, or 30 s after Steam says the host is out of the lobby. In the first public game the host's **Main Menu** button (right above the Co-op button) ended the game for both friends by a likely mis-click. Since 0.2.3, while friends are in, the host's **Main Menu** and **Quit Game** ask first: the first click changes the button to "Ends co-op: click again", and a second click (0.7 to 6 s later) leaves. A fast double click only asks. Tried with real clicks on test copies: 3 of 3 left on the second click, and the friend was told at once.
- **Basis:** lead's run; owner's live play; the 0.2.3 question: lane 63's run with real clicks on test copies.
- **Workaround:** the host starts again and invites the friends again.

### H5a. A short connection drop: proven in mock tests only

- **You see:** when the host's Steam connection drops for a moment (internet, Steam, a VPN switched on): the host reads "Your Steam connection dropped. Trying to reconnect (30 s)...", a friend reads "Connection to the host lost. Waiting up to 30 s..." and its game is held. Back within 30 s: "Reconnected." and the game goes on. Not back: the friends go to the main menu and the host invites again.
- **Numbers:** 30 s on both sides. In the first public session (2026-11-17, two PCs, before this change) a VPN switched on by the host ended the game for the friend at once, and the host's invites went to a lobby that no longer existed.
- **Basis:** the mod's mock tests (a simulated Steam: a 5 s drop with two friends, a drop with no return, a goodbye inside the 30 s, the lobby's ownership moving to a friend and back) and a desk test of the mod's own part. **Never run on real Steam.** Not known: whether Steam lets a host back into an invite-only lobby by its number, whether it hands the lobby's ownership back, what a host's Steam answers about its lobby right after a drop, and whether the notice texts fit on screen. Until the owner repeats the VPN test on two PCs this is unproven.
- **Workaround:** if it does not hold, it ends as before: "The host left the game" for the friends; the host presses **Invite Friends** (a new lobby) and the friends accept the new invite.
- A drop on a **friend's** side is not covered: that friend leaves at once and joins again by invite.

### H6. Tutorials pause everybody

- **You see:** a tutorial window on anyone's screen pauses the game for everyone until it is closed.
- **Numbers:** by the game's design. A tutorial the game opens by itself on a friend was never seen in a test.
- **Basis:** helper's runs.
- **Workaround:** tick "Skip all future tutorials".

### H7. Frame rate

- **You see:** the game may run slower, most on a friend's copy and at speed 8.
- **Numbers:** not a target (the owner's decision, 2026-11-15). Last measure, older build: a friend lost 15 to 16 % of frames at speed 4 and 27 to 38 % at speed 8.
- **Basis:** helper's run on an older build. Not measured on 0.2.1.
- **Workaround:** if it feels too slow, play at speed 4 instead of 8 (the loss was largest at speed 8).

### H8. The message files

- **You see:** nothing, if all goes well.
- **Numbers:** each player's message file starts a new file at 4 MB, and old ones are deleted. This ran in the game with a smaller limit (300 KB) on one PC.
- **Basis:** lead's run.
- **Workaround:** every player installs the same zip.

### H9. Antivirus

- **You see:** no Co-op button.
- **Numbers:** some antivirus programs remove `dwmapi.dll`.
- **Basis:** install notes.
- **Workaround:** check that `dwmapi.dll` is still next to the game's `.exe`.
