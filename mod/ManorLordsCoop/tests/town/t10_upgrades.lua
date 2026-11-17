-- t10_upgrades.lua  (town module: UPGRADE / EXT / ARTISAN; ONE copy; needs real clicks to see; replay is irreversible)
-- Run 1 (WATCH): switches the three actions on, registers their hooks (PawnCPP:add*Request), starts capturing, and lists up
--   to 8 lord buildings with their possible upgrades (getAllPossibleUpgrades, canUpgrade) - read-only.
--   Then the operator clicks, in the game, one house-level upgrade, one backyard extension and one artisan change.
-- Run 2 (same file again): prints the captured lines (expect "UPGRADE <building> <id>", "EXT <building> <slot> <type>",
--   "ARTISAN <building> <type>") and the lord's pending request flags. FINISH = true stops capturing and restores the flags.
-- DO_APPLY = true (coop_test_1 only, reload afterwards): feeds "UPGRADE <first candidate> <id>" as if a friend sent it; the
--   host checks canUpgrade and calls BeginUpgrade on the building (lane_t1 T8a). Prints silver / regional wealth / upgradesDone
--   before and after. NOT reversible: reload the save after it.
-- CONFIRMED = each click gives exactly one line naming the clicked building and id; DO_APPLY gives "ok", upgradesDone grows,
--   the lord's silver drops by the upgrade's treasury cost and the region's wealth by its wealth cost.
-- RISK: watch = none; apply = changes the world (and BeginUpgrade skips its own checks: the host's canUpgrade is the only one).
local FINISH = false
local DO_APPLY = false
local T = Coop and Coop.town
if not (T and Coop.s and Coop.s.on) then return "start Coop and load coop_town.lua first" end
_G.__tt = _G.__tt or {}
local st = _G.__tt.upg
if not st then
  st = { flags = T.test.flags() }; _G.__tt.upg = st
  for _, a in ipairs({ "UPGRADE", "EXT", "ARTISAN" }) do T.enable(a, true) end
  out(T.test.hooksNow()); T.test.cap()
end
local cands, listed = {}, 0
for i = 1, #eng.buildingArr do
  local b = un(eng.buildingArr[i])
  if b:IsValid() and nm(b.ownerPawn) == nm(p1) and listed < 8 then
    local ok, ups = pcall(function() return b:getAllPossibleUpgrades(true) end)
    if ok and ups and #ups > 0 then
      listed = listed + 1
      local parts = {}
      for j = 1, #ups do
        local id = un(ups[j]); local can = false
        pcall(function() can = b:canUpgrade(id, {}) end)
        parts[#parts + 1] = tostring(id) .. (can and "+" or "-")
        if can then cands[#cands + 1] = { b = b, id = id } end
      end
      local l = b:K2_GetActorLocation()
      out(string.format("building %d,%.0f,%.0f,%.0f upgrades (+ = can): %s", b:GetType(), l.X, l.Y, l.Z, table.concat(parts, " ")))
    end
  end
end
for _, l in ipairs(T.test.lines()) do out("SENT", l) end
out("lord requests pending: upgrade", tostring(p1.upgradeRequestPending), "artisan", tostring(p1.artisanChangeRequestPending), "extension", tostring(p1.extensionChangeRequestPending))
if DO_APPLY and cands[1] then
  local c = cands[1]; local b = c.b; local l = b:K2_GetActorLocation()
  local function state() return string.format("silver %d wealth %d upgradesDone %d", p1.silver, b.Region.regionalWealth, #b.upgradesDone) end
  out("APPLY UPGRADE", c.id, "before:", state())
  local _, r = T.inject("UPGRADE", string.format("%d,%.0f,%.0f,%.0f %d", b:GetType(), l.X, l.Y, l.Z, c.id))
  out("  ->", r, "after:", state())
end
if FINISH then T.test.uncap(); T.test.restoreFlags(st.flags); _G.__tt.upg = nil; return "finished" end
return "watching: click upgrades in the game, then run again (FINISH = true to stop)"
