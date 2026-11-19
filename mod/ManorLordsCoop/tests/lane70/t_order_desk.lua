-- Lane 70 desk test: order answers (G139) in coop_x_army.lua under Lua 5.1. A friend's order leaves (C.orderSent),
-- the host answers (C.orderAnswer -> "A ACK"), the friend reads the answer (the module's onMessage): ok, changed,
-- refused, and an answer that never comes (3 s). Squad numbers: the friend's 59 / 60 are the host's 60 / 61.
--   py -3 -I luacheck.py run t_order_desk.lua
local pass, fail = 0, 0
local function check(c, what) if c then pass = pass + 1; print("  PASS  " .. what) else fail = fail + 1; print("  FAIL  " .. what) end end
local logs, sent, notes, mod = {}, {}, {}, nil
local h2l = { [60] = 59, [61] = 60 }; local l2h = { [59] = 60, [60] = 61 }
local function fmt(f, ...) local ok, s = pcall(string.format, f, ...); return ok and s or f end
_G.Coop = {
  register = function(name, m) if name == "army" then mod = m end end,
  api = { valid = function(o) return o ~= nil end, log = function(f, ...) logs[#logs + 1] = fmt(f, ...) end,
          send = function(l) sent[#sent + 1] = l end, far = function() return false end, un = function(x) return x end,
          toHost = function(h) return l2h[h] or h end, toLocal = function(h) return h2l[h] end, helper = function() end,
          now = function() return 1000 + os.clock() end },
  armyApi = { sqValid = function(h) return h == 59 or h == 60 end },
  notify = function(kind, text) notes[#notes + 1] = text end,
}
local chunk, e = loadfile(HERE .. "../../Scripts/coop_x_army.lua"); if not chunk then error(e) end
chunk()
local C = Coop; local M = C.army
-- squad names on the friend's copy (nameOf reads S.sc:GetSquad(...).Name:ToString())
local names = { [59] = "Spearmen", [60] = "Infantry" }
local function words(l) local w = {}; for x in l:gmatch("%S+") do w[#w + 1] = x end; return w end
local friend = { role = "friend", name = "friend2", seq = 0, stats = {}, localOrderT = {}, mine = { [59] = true, [60] = true },
                 sc = { GetSquad = function(_, t) return { Name = { ToString = function() return names[t.Value] end } } end } }
local host = { role = "host", name = "host", stats = {}, curPeer = "friend2" }
local function lastLog(pat) for i = #logs, 1, -1 do if logs[i]:find(pat) then return logs[i] end end end

-- a friend's order through the core's send: its sequence number and line
local function friendSends(line) friend.seq = friend.seq + 1; C.s = friend; C.orderSent(friend.seq, line); return friend.seq, tostring(friend.seq) .. " 999.000 " .. line end
-- the host applies it and answers (as hostInbox does after its APPLIED line)
local function hostAnswers(wireLine, ok, r)
  C.s = host; sent = {}
  C.orderAnswer(host, "friend2", words(wireLine), ok, r)
  return sent[1]
end
local function friendReads(ackLine)
  C.s = friend
  local w = words("77 1234.500 " .. ackLine)
  return mod.onMessage(friend, "host", "A", w, ackLine)
end

print("1. ok")
local s1, l1 = friendSends("O MOVE 60 100 200 0")
check(lastLog("ORDER " .. s1 .. " sent: MOVE host squad 60 %(here 59%)") ~= nil, "sent line: kind, host squad 60, here 59, its sequence number")
check(C.orderPending(59) == true, "squad 59 holds this player's order until the answer")
local a1 = hostAnswers(l1, true, "ok")
check(a1 and a1:find("^A ACK friend2 " .. s1 .. " MOVE ok ") ~= nil, "the host answers ok too: " .. tostring(a1))
friendReads(a1)
check(lastLog("ORDER " .. s1 .. " answered: MOVE ok") ~= nil and lastLog("round trip %d+ ms") ~= nil, "answer line with the round trip")
check(not C.orderPending(59) and C.orderAckWall(59) == 1234.5, "released at the answer; the host's clock of the answer kept")
check(#notes == 0, "no notice for ok")

print("2. changed (a line in a fight)")
local s2, l2 = friendSends("O LINE 61 1 2 3 4 0")
local a2 = hostAnswers(l2, true, "ok (in a fight: a plain move)")
check(a2:find(" LINE changed ") ~= nil, "classified changed")
friendReads(a2)
check(#notes == 1 and notes[1]:find("Infantry") and notes[1]:find("changed by the host") and notes[1]:find("in a fight"), "notice: " .. tostring(notes[1]))

print("3. refused (the camp fell)")
local s3, l3 = friendSends("O BLD 60,61 12@3,4 1 2 3")
check(C.orderPending(59) and C.orderPending(60), "both squads of a BLD hold")
local a3 = hostAnswers(l3, true, "building not found")
friendReads(a3)
check(#notes == 2 and notes[2]:find("not carried out") and notes[2]:find("no longer there") and notes[2]:find("Spearmen, Infantry"), "notice: " .. tostring(notes[2]))
check(not C.orderPending(59) and not C.orderPending(60), "both released")
local a3b = hostAnswers(l3, true, "false"); check(a3b:find(" refused ") ~= nil, "a skill the host's game did not take: refused")
local a3c = hostAnswers(l3, false, "boom"); check(a3c:find(" refused ") ~= nil, "an error: refused")
check(hostAnswers(l3, true, "ok (31 men, 9 files x 4 ranks)"):find(" ok ") ~= nil, "a shape answer is ok")
check(hostAnswers("5 1.0 O PING 0 12.5", true, "ok") == nil, "the round-trip probe gets no ACK (it has its PONG)")

print("4. no answer")
local s4 = friendSends("O ATTACK 60 77")
check(C.orderPending(59), "pending")
M.orderTick(friend, os.clock() + 3.1)
check(not C.orderPending(59) and lastLog("ORDER " .. s4 .. " %(ATTACK 60%): no answer from the host in 3 s") ~= nil, "after 3 s: logged, the mirror follows the host again")

print("5. an answer for another friend, an older order")
local s5 = friendSends("O SKILL 61 2 on")
friendReads(string.format("A ACK friend1 %d SKILL ok ok", s5))
check(C.orderPending(60), "another friend's answer does not release this one's order")
local s6 = friendSends("O SKILL 61 2 off")
local w5 = string.format("%d 999.000 O SKILL 61 2 on", s5)
friendReads(hostAnswers(w5, true, "true"))
check(C.orderPending(60), "the answer to the older order (seq " .. s5 .. ") leaves the newer one (" .. s6 .. ") pending")

print(string.format("t_order_desk: %d passed, %d failed", pass, fail))
if fail > 0 then error("t_order_desk failed") end
