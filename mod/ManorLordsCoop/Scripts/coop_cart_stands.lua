-- Physical hand carts on a friend (cfg.cartPut). The host's snapshot is the truth: every parked cart (id, root,
-- rotation, building, good) and the villagers that carry a hand cart, in one line. A friend's villager never takes or
-- parks a cart by itself: the board turns the host's pickup and return lines into a walk to the place (P.intent), and
-- the cart changes hands ON THE HOST'S WORD, in the scan that follows each snapshot, with the game's own calls and
-- always in pairs that keep the town's count:
--   take   the host's villager carries now: one cart that no host stand holds is retired, the villager gets the item
--   park   the host's villager carries no more: it drops (SMUnit:unequip makes one registered cart) and that cart is
--          put at the stand the host named, or at the nearest stand the host has and this copy lacks
--   move   a host stand without a cart here gets a cart no host stand holds
-- What a snapshot cannot pair is a correction, made after cfg.cartGrace seconds: mint (a cart short), shed and
-- retire (a cart too many). Resource:removeResource is never called on a cart without this world's game master
-- (that call closed the game in lane 5). unequip empties a villager's goods, so the host's load is written after it.
local C = Coop
local A, P = C.api, {}
C.cartStands = P
local world, epoch, nonce, requested, sequence, lastScan, serial
local stands, hostCarriers, dirty, open
local hostDrops = {}
local haltedWorld
local pick, park, word, lag, blocked = {}, {}, {}, {}, {}
local known, swept, legsEnded, needFull, waitSince = {}, nil, nil, nil, nil
local since, had, heldAt, again, watch = {}, {}, nil, {}, {}
local VILLAGER = '^%d+%.%d+%.%d+$'
-- (lane 74, timber carts) The same rules cover the timber cart (class Resource_TimberCart_C, good 345) that an OX
-- pulls: lane 5 probe big_b, one call a step: removeResource retired it, equip(345) gave it to the ox (isWagonEquipped),
-- unequip made exactly one registered cart, and the game's own ox took that cart again. cfg.cartTimber=false leaves
-- them to the game as before. A carrier is named by its board key: a villager "r.f.n", an ox "o<type>,<x>,<y>#<n>".
local OX = '^o%d+,%-?%d+,%-?%d+#%d+$'
local CLASS = {[218]='Resource_Handcart_C', [345]='Resource_TimberCart_C'}
local function covered(good)
    if good==218 then return true end
    return good==345 and C.jobs.cfg.cartTimber~=false
end
local function goods() return covered(345) and {218,345} or {218} end
local function carrierOf(key) return key:match(VILLAGER) and 218 or (key:match(OX) and covered(345) and 345) or nil end
local function carries(u) for _,g in ipairs(goods()) do if u:isEquipped(g) then return g end end end
P.stats = {own=0, total345=0, hostTotal345=0, take=0, park=0, move=0, ended=0, lost=0, held=0, mint=0, shed=0, retire=0, equip=0, odd=0, blocked=0, halted=0, transfers=0,
    rollbacks=0, rollbackFailures=0, ambiguous=0, total=0, hostTotal=0, scans=0, scanMs=0, scanMaxMs=0, walks=0, ownleg=0}
local function note(kind,who,what)
    P.stats[kind]=P.stats[kind]+1
    if P.onForce then pcall(P.onForce,kind,tostring(who),tostring(what)) end
end
local function live(o) return A.valid(o) and not o:IsActorBeingDestroyed() end
local function addr(o) return A.valid(o) and o:GetAddress() or nil end
-- (lane 64, task 64d) the address of a handle kept from an earlier tick, read without looking at the object
local function keptAddr(o) if o == nil then return nil end; local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end
local function rnd(x) return math.floor(x + 0.5) end
local function distance(a,b) return (a.X-b.X)^2 + (a.Y-b.Y)^2 + (a.Z-b.Z)^2 end
local function active(S, clock)
    local J = C.jobs
    local heard = S.heard and S.heard.host
    return S == C.s and S.worlds ~= haltedWorld and S.role == 'friend' and J and J.cfg.on and J.cfg.cartPut and J.gateOn
        and not (C.hold or S.linkHold or S.linkWait or (C.session and C.session.leaving))
        and (not heard or clock - heard < J.cfg.quiet) and live(S.eng)
end
function P.reset(S)
    world, epoch, nonce, requested, sequence, lastScan = S.worlds, nil, nil, nil, 0, nil
    stands, hostCarriers, dirty, open = {}, nil, nil, nil
    hostDrops = {}
    pick, park, word, lag, blocked = {}, {}, {}, {}, {}
    known, swept, legsEnded, needFull, waitSince = {}, nil, nil, nil, nil
    since, had, heldAt, again, watch = {}, {}, nil, {}, {}
    if C.scene then C.scene.byCart = {} end
end
local function parse(word)
    if not word then return end
    local id,x,y,z,yaw,pitch,roll,home,good = word:match(
        '^(%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):([^:]+):(%d+)$')
    if not id or (home ~= '-' and not home:match('^%d+@%-?%d+,%-?%d+$')) then return end
    local pos = {X=tonumber(x), Y=tonumber(y), Z=tonumber(z)}
    return {id=tonumber(id), home=home, good=tonumber(good), pos=pos,
        rot={Yaw=tonumber(yaw), Pitch=tonumber(pitch), Roll=tonumber(roll)}}
end
function P.snapshot(S, body, seq, gen)
    seq=tonumber(seq)
    if not body or not seq or world ~= S.worlds or not epoch or tonumber(gen) ~= epoch or seq <= sequence then return end
    local standsPart,carriersPart = body:match('^([^|]*)|(.*)$')
    if not standsPart then return end
    local nextStands,nextCarriers = {},{}
    local men,oxen = carriersPart:match('^([^|]*)|?(.*)$')
    for key in men:gmatch('[^,]+') do
        if key ~= '-' then
            if not key:match(VILLAGER) then return end
            nextCarriers[key] = 218
        end
    end
    for key in oxen:gmatch('[^;]+') do
        if key ~= '-' then
            if not key:match(OX) then return end
            if covered(345) then nextCarriers[key] = 345 end
        end
    end
    for token in standsPart:gmatch('[^;]+') do
        if token ~= '-' then
            local h = parse(token)
            if not h or nextStands[h.id] then return end
            nextStands[h.id] = h
        end
    end
    sequence, stands, hostCarriers, dirty = seq, nextStands, nextCarriers, true
end
-- Q CA requests a current-world snapshot. Only the matching reply opens this
-- generation. A held order from before a reload cannot open it.
function P.receive(S,w)
    if S.role == 'host' and w[4] == 'CA' then
        if w[5] and w[5]:match('^%d+%.%d+$') and C.scene and C.scene.world == S.worlds and C.scene.standsSaid then
            A.send('Q CS '..w[5]..' '..S.worlds..' '..C.scene.standsSaid)
        end
    elseif w[4]=='CR' and epoch and tonumber(w[5])==epoch and world==S.worlds and active(S,os.clock()) then
        -- the host's villager w[6] parked at this stand
        local dest=parse(w[8])
        if dest and dest.good==218 and w[6] and w[6]:match(VILLAGER) then word[w[6]]={h=dest,at=os.clock()} end
    elseif w[4] == 'CS' and nonce and w[5] == nonce and active(S,os.clock()) and world == S.worlds then
        epoch, nonce = tonumber(w[6]), nil
        P.snapshot(S,w[7],w[1],epoch)
    end
end
-- The board's word for a host pickup or return line: where the villager walks. The cart itself follows the snapshot.
function P.intent(S,e,kind,standWord,pos,clock)
    if world ~= S.worlds then return end
    local h=parse(standWord)
    local at={X=pos.X,Y=pos.Y,Z=pos.Z}
    if kind=='pickup' then pick[e.key]={pos=h and h.pos or at,at=clock}; park[e.key]=nil
    else park[e.key]={pos=at,at=clock}; pick[e.key]=nil end
    P.stats.walks=P.stats.walks+1
end
local function homeOf(b)
    local p = b:K2_GetActorLocation()
    return string.format('%d@%d,%d', A.btype(b), rnd(p.X/10), rnd(p.Y/10))
end
-- Every hand cart of this world that stands (not carried, not the spare at the origin) and has this world's game
-- master. Usable: its owner lists it once and their regions agree (or it is loose with a region). The others are
-- "odd". Read from the carts' side: only the buildings that own a cart are looked at (the walk over every building
-- of the town was most of the scan's 15 ms in sitting word_a2).
local timberAddr = {}   -- (round 8) every timber cart of this world that stands, by address, as of the last scan
local function pool(S)
    local eng, carts, odd, byHome, owners = S.eng, {}, {}, {}, {}
    local engine, map = addr(eng), addr(eng:GetWorld())
    local n={[218]=0,[345]=0}
    timberAddr = {}
    for _,kind in ipairs(goods()) do
    for _,c in ipairs(FindAllOf(CLASS[kind]) or {}) do
        if live(c) and addr(c:GetWorld())==map and addr(c:getMaster())==engine and not A.valid(c:GetAttachParentActor()) then
            if kind==345 then timberAddr[addr(c)]=true end
            local loc = c:K2_GetActorLocation()
            if math.abs(loc.X) + math.abs(loc.Y) >= 100 then
                n[kind]=n[kind]+1
                local a,reg,owner = addr(c),addr(c.Region),c.belongsTo
                local good,info
                if live(owner) then
                    local oa=addr(owner)
                    info=owners[oa]
                    if not info then
                        info={b=owner,home=homeOf(owner),count={},region=addr(owner.Region)}
                        local arr=owner.Carts
                        for k=1,#arr do
                            local x=addr(A.un(arr[k]))
                            if x then info.count[x]=(info.count[x] or 0)+1 end
                        end
                        owners[oa]=info
                        if byHome[info.home]==nil then byHome[info.home]=owner else byHome[info.home]=false end
                    end
                    good=reg and info.count[a]==1 and info.region==reg
                    if not good then info=nil end
                elseif A.valid(owner) then good=false
                else good=reg~=nil end
                local item={c=c, a=a, name=c:GetFName():ToString(), good=tonumber(c.Type), home=info and info.home or '-',
                    building=info and info.b or nil, region=reg, pos={X=loc.X,Y=loc.Y,Z=loc.Z}}
                if good and item.good==kind then carts[a]=item else item.good=kind; odd[#odd+1]=item end
            end
        end
    end
    end
    return carts,byHome,n,odd,owners
end
-- A building that owns no cart yet, by its host name (type@x,y): looked for only when a stand needs it.
local function findHome(S,home)
    local ty=tonumber(home:match('^(%d+)@'))
    local found
    local arr=S.eng.buildingArr
    for i=1,#arr do
        local b=A.un(arr[i])
        if live(b) and A.btype(b)==ty and homeOf(b)==home then
            if found then return false end
            found=b
        end
    end
    return found or false
end
-- Capture both complete lists before writing. Array reads are always bounded.
local function members(b)
    local list,seen={},{}
    local arr=b.Carts
    for i=1,#arr do
        local c=A.un(arr[i])
        if not live(c) or seen[addr(c)] then return end
        list[#list+1]=c; seen[addr(c)]=true
    end
    return list,seen
end
local function replaceMembers(b,list,omit)
    assert(live(b))
    local arr=b.Carts
    arr:Empty()
    for _,c in ipairs(list) do
        if addr(c)~=omit then assert(live(c)); arr[#arr+1]=c end
    end
end
local function matches(b,list,omit,extra)
    if not live(b) then return false end
    local arr,expected=b.Carts,{}
    for _,c in ipairs(list) do if addr(c)~=omit then expected[#expected+1]=addr(c) end end
    if extra then expected[#expected+1]=extra end
    if #arr~=#expected then return false end
    for i=1,#arr do if addr(A.un(arr[i]))~=expected[i] then return false end end
    return true
end
-- A cart a task names is not retired: the units whose tasks (or whose board records) name it, by unit address.
-- (round 4) The villager a take is for may name it itself: the board's copy of the host's pickup names the cart that
-- villager walks to (sitting word_t3: 8.4.2's take waited 6.4 s for the host's next task, 3.5 s past the bar).
local namedSet
local function named(S,c,taker)
    if not namedSet then
        namedSet={}
        local function put(a,who) if a then local t=namedSet[a] or {}; namedSet[a]=t; t[who or 0]=true end end
        local us=S.eng.unitArr
        for i=1,#us do
            local u=A.un(us[i])
            if live(u) and not u.dead then
                local ts=u.Tasks
                for j=1,#ts do put(addr(ts[j].Resource),addr(u)) end
            end
        end
        -- (lane 64, task 64d) a board record's resource is a handle kept past its tick, of no native table (the cart
        -- may have been retired and freed since the record came): its address is read without touching it (no valid(),
        -- which would look at the object; GetAddress reads the handle's own number). Only addresses go into the set,
        -- matched against the carts of this scan by address, as before.
        for _,e in pairs(C.jobs.byKey or {}) do
            put(e.host and keptAddr(e.host.rec.Resource),e.addr)
            put(e.q and keptAddr(e.q.rec.Resource),e.addr)
        end
    end
    local t=namedSet[addr(c)]
    if not t then return false end
    for who in pairs(t) do if who~=taker then return true end end
    return false
end
-- A cart task this copy's villager still has from the save or from before the switch (take a hand cart, park one)
-- ends: the game's own setTask, standing where it is. From then on the host's word moves the carts.
local function endOwnLeg(e,kind,what)
    local u=e.u
    local ts=u.Tasks
    if #ts==0 then return end
    local t=ts[1]
    local ty=tonumber(t.Type)
    local cart=ty==23 and live(t.Resource) and P.isCart(C.s,t.Resource)
    local rt=tonumber(t.resourceType)
    -- an ox is never touched by the hand cart rules (its return may carry good 218: not read in the game)
    local ox=e.key:match(OX)~=nil
    if not cart and not (ty==47 and ((rt==218 and not ox) or (covered(345) and (rt==345 or ox)))) then return end
    local p=u:K2_GetActorLocation()
    local function at() return {Pos={X=p.X,Y=p.Y,Z=p.Z},floor=tonumber(u.floor) or 0,Rotation={Pitch=0.0,Yaw=0.0,Roll=0.0}} end
    u:setTask({Type=17,TargetLocation=at(),finalLocation=at(),targetEntityLocation={X=p.X,Y=p.Y,Z=p.Z},
        resourceType=0,resourceAmt=0,executed=false,ID=-1,bPaidInAdvance=false})
    e.given=nil
    note(kind or 'ended',e.key,what or ty)
end
local function slotOf(u,good)
    for _,carrying in ipairs({true,false}) do
        local slot=u:GetItemEquipmentSlot(good,carrying)
        if tonumber(u:GetEquippedID(slot))==good then return slot end
    end
end
local function standing(S,good)
    local r,map,eng = {},addr(S.eng:GetWorld()),addr(S.eng)
    for _,c in ipairs(FindAllOf(CLASS[good]) or {}) do
        if live(c) and addr(c:GetWorld())==map and addr(c:getMaster())==eng and not A.valid(c:GetAttachParentActor()) then
            local p=c:K2_GetActorLocation()
            if math.abs(p.X)+math.abs(p.Y)>=100 then r[c:GetFName():ToString()]=c end
        end
    end
    return r
end
-- (round 8) noted again after 5 s while it lasts: noted only once a world, a block that came back later was silent
-- (lane 64's l64pin21: a take for the host's ox came 5.8 s late with no note at all; not proven to be this)
local function hold(e,why)
    local k=e.key..'/'..why
    local now=os.clock()
    if not blocked[k] or now-blocked[k]>=5.0 then blocked[k]=now; note('blocked',e.key,why) end
end
-- unequip empties the villager's goods (lane 5 probe): only with the host's load known, which is written after it.
local function canDrop(e)
    if #e.u.Inventory>0 and not e.hl then hold(e,'loaded'); return false end
    return true
end
-- The game's own drop. Exactly one new registered cart must appear.
local function drop(S,e,good)
    local u=e.u
    local slot=slotOf(u,good)
    if not slot then return end
    local loaded=#u.Inventory>0
    local before=standing(S,good)
    u:unequip(slot)
    if not live(u) or u:isEquipped(good) then return end
    if (loaded or (e.hl and e.hl~='0')) and C.jobs.setHands then
        pcall(C.jobs.setHands,u,e.hl or '0')
        if P.onForce then pcall(P.onForce,'load',e.key,tostring(e.hl)) end
    end
    local new,n=nil,0
    for name,c in pairs(standing(S,good)) do if not before[name] then new=c; n=n+1 end end
    if n~=1 then
        haltedWorld=S.worlds
        P.stats.halted=P.stats.halted+1
        A.log('cart drop made '..n..' carts; cart settling stopped in this world')
        return
    end
    return new
end
local function retire(S,c,taker)
    if not live(c) or addr(c:getMaster())~=addr(S.eng) or named(S,c,taker) then return false end
    c:removeResource()
    return true
end
local function give(u,good)
    local id=tonumber(u:GetEquippedID(u:GetItemEquipmentSlot(good,true)))
    if id==nil or id>0 then return false end
    u:equip(good,true,true)
    return u:isEquipped(good)
end
-- Put a registered cart at a host stand: list entries, owner, region, then the root.
local function relocate(S,cart,h,dest)
    if not live(cart) or addr(cart:getMaster())~=addr(S.eng) then return false end
    local src=cart.belongsTo
    if not live(src) then src=nil end
    if h.home=='-' then if src then return false end
    elseif not live(dest) then return false end
    local a,region=addr(cart),cart.Region
    local same=src and dest and addr(src)==addr(dest)
    local from,atSource,into,atDest
    if src then
        from,atSource=members(src)
        if not from or not atSource[a] then return false end
    end
    if dest and not same then
        into,atDest=members(dest)
        if not into or atDest[a] then return false end
    end
    local loc,rot=cart:K2_GetActorLocation(),cart:K2_GetActorRotation()
    local old={X=loc.X,Y=loc.Y,Z=loc.Z}
    local oldRot={Pitch=rot.Pitch,Yaw=rot.Yaw,Roll=rot.Roll}
    local ok=pcall(function()
        if dest and not same then
            if src then replaceMembers(src,from,a) end
            if addr(cart.Region)~=addr(dest.Region) then cart.Region=dest.Region end
            cart.belongsTo=dest
            local arr=dest.Carts
            arr[#arr+1]=cart
        end
        assert(cart:K2_SetActorLocationAndRotation(h.pos,h.rot,false,{},true))
        assert(live(cart) and addr(cart:getMaster())==addr(S.eng) and distance(cart:K2_GetActorLocation(),h.pos)<=9)
        if dest then
            assert(addr(cart.belongsTo)==addr(dest) and addr(cart.Region)==addr(dest.Region))
            if not same then assert(matches(dest,into,nil,a) and (not src or matches(src,from,a))) end
        end
    end)
    if ok then
        P.stats.transfers=P.stats.transfers+1
        if C.jobs.cartMoved then C.jobs.cartMoved(cart,old,h.pos) end
        return {c=cart,a=a,name=cart:GetFName():ToString(),good=h.good,home=h.home,building=dest,
            region=addr(cart.Region),pos=h.pos,since=os.clock()}
    end
    local restored=pcall(function()
        assert(live(cart))
        if dest and not same then
            replaceMembers(dest,into)
            if src then replaceMembers(src,from); cart.belongsTo=src end
            if addr(cart.Region)~=addr(region) then cart.Region=region end
        end
        assert(cart:K2_SetActorLocationAndRotation(old,oldRot,false,{},true))
        -- A cart that was loose keeps its game master; the next scan retires it as surplus.
        assert(addr(cart:getMaster())==addr(S.eng))
    end)
    P.stats.rollbacks=P.stats.rollbacks+1
    if not restored then
        haltedWorld=S.worlds
        P.stats.rollbackFailures=P.stats.rollbackFailures+1
        A.log('cart relocation rollback failed; parking stopped in this world')
    end
    return false
end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function scan(S,clock)
    local J=C.jobs
    namedSet=nil
    local carts,buildings,parked,odd,owners = pool(S)
    local bound,used = {},{}
    local order={}
    for id,h in pairs(stands) do if CLASS[h.good] and covered(h.good) then order[#order+1]=id end end
    table.sort(order)
    -- a cart that stands right (same building, 3 cm) is that stand's
    for _,id in ipairs(order) do
        local h,best,bd = stands[id],nil,nil
        local dest=h.home~='-' and buildings[h.home] or nil
        for a,c in pairs(carts) do
            if not used[a] and c.good==h.good and c.home==h.home and (h.home=='-' or (dest and addr(dest)==addr(c.building))) then
                local d=distance(c.pos,h.pos)
                if d<=9 and (not bd or d<bd) then best,bd=c,d end
            end
        end
        if best then bound[id]=best; used[best.a]=id end
    end
    -- who carries here: every villager at the first scan of a world and every cfg.cartSweep seconds (the first also
    -- ends cart tasks of this copy's own); between them only those the host names and those that carried here
    local carriers,cgood,nCarry={},{},{[218]=0,[345]=0}
    local function look(key,e)
        if e and not carriers[key] and live(e.u) and not e.u.dead then
            local g=carrierOf(key)
            if g and e.u:isEquipped(g) then carriers[key]=e; cgood[key]=g; nCarry[g]=nCarry[g]+1 end
        end
    end
    local full=not swept or needFull or clock-swept>=(J.cfg.cartSweep or 5.0)
    if full then
        for key,e in pairs(J.byKey or {}) do
            if carrierOf(key) then
                if not legsEnded and live(e.u) and not e.u.dead then endOwnLeg(e) end
                look(key,e)
            end
        end
        swept,legsEnded=clock,true
    else
        local by=J.byKey or {}
        for key in pairs(known) do look(key,by[key]) end
        for key in pairs(hostCarriers) do look(key,by[key]) end
    end
    known={}
    for key in pairs(carriers) do known[key]=true end
    for key in pairs(hostCarriers) do known[key]=true end   -- one of these may be given the item in this scan
    local total,hostTotal={[218]=0,[345]=0},{[218]=0,[345]=0}
    for _,g in ipairs(goods()) do total[g]=parked[g]+nCarry[g] end
    for _,id in ipairs(order) do local g=stands[id].good; hostTotal[g]=hostTotal[g]+1 end
    for _,g in pairs(hostCarriers) do if covered(g) then hostTotal[g]=hostTotal[g]+1 end end
    local want={}
    local missing,surplus,extra,lacking={},{},{},{}
    for _,id in ipairs(order) do
        local h=stands[id]
        if not bound[id] then
            if h.home~='-' and buildings[h.home]==nil then buildings[h.home]=findHome(S,h.home) end
            if h.home=='-' or buildings[h.home] then missing[#missing+1]=h end
        end
    end
    for a,c in pairs(carts) do if not used[a] then surplus[#surplus+1]=c end end
    for key,e in pairs(carriers) do if not hostCarriers[key] then extra[#extra+1]=e end end
    for key,g in pairs(hostCarriers) do
        local e=J.byKey and J.byKey[key]
        if covered(g) and not carriers[key] and e and live(e.u) and not e.u.dead then lacking[#lacking+1]=e; want[key]=g end
    end
    table.sort(surplus,function(x,y) return x.name<y.name end)
    table.sort(extra,function(x,y) return x.key<y.key end)
    table.sort(lacking,function(x,y) return x.key<y.key end)
    local seen={}
    local function aged(k)
        seen[k]=true; lag[k]=lag[k] or clock
        return clock-lag[k]>=(J.cfg.cartGrace or 0.8)
    end
    local function nearest(list,p,limit,ok)
        local pickI,pd
        for i,x in ipairs(list) do
            if x and (not ok or ok(x)) then
                local d=distance(x.pos,p)
                if (not limit or d<=limit) and (not pd or d<pd) then pickI,pd=i,d end
            end
        end
        return pickI
    end
    local function put(h,cart,kind,who)
        local got=cart and relocate(S,cart,h,h.home~='-' and buildings[h.home] or nil)
        if got then bound[h.id]=got; used[got.a]=h.id; note(kind,who,h.id); return true end
        return false
    end
    local function fits(h) return function(c) return live(c.c) and c.good==h.good and (h.home~='-' or not c.building) end end
    local function of(g) return function(h) return h.good==g end end
    local function halted() return haltedWorld==S.worlds end
    -- A take waits for the host's next task to be given here (see "take" below), at most cfg.cartTakeWait seconds.
    -- All takes go in one scan: two carts the host's villagers took in the same moment were given 0.7 and 0.8 s apart
    -- (sittings word_d1, word_d2: a building count the host did not have, for that long).
    local lackingNow={}
    for _,e in ipairs(lacking) do lackingNow[e.key]=true; since[e.key]=since[e.key] or clock end
    for k in pairs(since) do if not lackingNow[k] then since[k]=nil end end
    local go,oldest=true,0
    for _,e in ipairs(lacking) do
        -- a cart this villager lost by itself is given back at once (see tick): no wait for a task
        local back=again[e.key] and again[e.key].now
        if (e.free or e.q or e.pend) and not back then go=false end
        if clock-since[e.key]>oldest then oldest=clock-since[e.key] end
    end
    if oldest>=(J.cfg.cartTakeWait or 1.2) then go=true end
    -- While a take waits, nothing else of the host's word is applied: the host's changes keep their order. (Sitting
    -- word_e2: the host took a cart from a building and 1.2 s later another villager parked one there; this copy
    -- did the park first and showed 2 carts where the host had 1, 0, 1.) The take and what came after it then run
    -- in one scan, so the count goes from one host value to a later one.
    local hold=#lacking>0 and not go
    if hold then
        if not heldAt and ((#extra>0 and #missing>0) or (#missing>0 and #surplus>0)) then heldAt=clock; note('held',lacking[1].key,#extra..'/'..#missing) end
    else heldAt=nil end
    -- park: the host's villager carries no more. Its own stand first (the host's word, then its return line's place).
    for pass=1,2 do
        for i,e in ipairs(extra) do
            if e and not halted() and not hold then
                local w,r=word[e.key],park[e.key]
                local g=cgood[e.key]
                local m
                if pass==1 then
                    if w then for j,h in ipairs(missing) do if h and h.id==w.h.id and h.good==g then m=j end end end
                    if not m and r then m=nearest(missing,r.pos,300*300,of(g)) end
                else
                    local l=e.u:K2_GetActorLocation()
                    m=nearest(missing,{X=l.X,Y=l.Y,Z=l.Z},nil,of(g))
                end
                if m and canDrop(e) then
                    local h=missing[m]
                    -- (round 7, HANDCART) a hand cart the host never had this villager carry (no return line, no
                    -- park word of the host): its own pickup, undone here
                    local ownCarry=g==218 and not w and not r
                    local c=drop(S,e,g)
                    -- (round 3, OXCART) an ox that took its timber cart by its own pickup gets the stand record here
                    -- (GoToLocation where it stands, through the reflected setTask): the DLL keeps it for that ox and
                    -- gives it instead of the ox's next own pickup (design_oxcart.txt). endOwnLeg acts only on a 23.
                    -- (round 7) The same for a villager whose own pickup of a hand cart is undone here: in word_m1
                    -- 8.17.1 took the cart again 1.0 s after such a park and carried it 1.13 s; with the stand the
                    -- DLL has a record to give instead of that pickup (bystand).
                    if (g==345 or ownCarry) and live(e.u) then endOwnLeg(e) end
                    extra[i]=false; park[e.key]=nil; word[e.key]=nil
                    if c then
                        if put(h,c,'park',e.key) then missing[m]=false
                        else surplus[#surplus+1]={c=c,a=addr(c),name=c:GetFName():ToString(),good=g,pos=h.pos,building=live(c.belongsTo) and c.belongsTo or nil} end
                    end
                end
            end
        end
    end
    -- take: the host's villager carries now. A cart no host stand holds is retired for it, the nearest to its pickup.
    -- Not while the villager is free here (it only walked to the cart; the host's next line is on its way): a free
    -- villager that leads an ox starts a Follow of its own, and that start drops the cart (sitting word_c1: given
    -- at 480.09, own Follow at 480.10, the cart stood loose 0.4 s). The cart is given when the host's next task has
    -- been given here (the board calls afterGive), at the latest cfg.cartTakeWait seconds after the host's take.
    local function free(g) return function(c) return live(c.c) and c.good==g end end
    -- (round 7) A carrier that lost its cart by itself gets it back in this scan even while the takes of others wait
    -- (sitting hc_b2: 8.12.3's own task 30 dropped its cart while 3.2.3 waited for its task; both got carts 1.64 s
    -- later, in one scan, and the dropped cart stood loose that long: a place the host never had). Its give back is
    -- not of the host's order: the cart it had is retired and the item given again.
    local function settled(e) return go or (again[e.key] and again[e.key].now) or false end
    for pass=1,2 do
        for i,e in ipairs(lacking) do
            if e and not halted() and settled(e) then
                local r=pick[e.key]
                local g=want[e.key]
                local s
                if pass==1 then s=r and nearest(surplus,r.pos,300*300,free(g))
                else
                    local l=e.u:K2_GetActorLocation()
                    s=nearest(surplus,{X=l.X,Y=l.Y,Z=l.Z},nil,free(g))
                end
                if s then
                    local id=tonumber(e.u:GetEquippedID(e.u:GetItemEquipmentSlot(g,true)))
                    if id==nil or id>0 then hold(e,'slot'); lacking[i]=false
                    elseif retire(S,surplus[s].c,e.addr) then
                        local name=surplus[s].name
                        surplus[s]=false; lacking[i]=false; pick[e.key]=nil
                        if give(e.u,g) then note('take',e.key,name) else total[g]=total[g]-1 end
                    end
                end
            end
        end
    end
    -- move: a host stand without a cart here gets a cart no host stand holds
    for j,h in ipairs(missing) do
        if h and not halted() and not hold then
            local s=nearest(surplus,h.pos,nil,fits(h))
            if s then
                local c=surplus[s]; surplus[s]=false
                if put(h,c.c,'move',c.name) then missing[j]=false end
            end
        end
    end
    -- a carrier here that the host's is not, and a host carrier that is none here: the cart changes hands
    for i,e in ipairs(lacking) do
        if e and not halted() and settled(e) then
            local x
            local g=want[e.key]
            for k,o in ipairs(extra) do if o and cgood[o.key]==g and canDrop(o) then x=k; break end end
            local id=tonumber(e.u:GetEquippedID(e.u:GetItemEquipmentSlot(g,true)))
            if x and id~=nil and id<=0 then
                local o=extra[x]; extra[x]=false
                local c=drop(S,o,g)
                if c and retire(S,c) then
                    if give(e.u,g) then lacking[i]=false; note('take',e.key,o.key) else total[g]=total[g]-1 end
                end
            end
        end
    end
    -- corrections, after the grace: what one snapshot cannot pair. Only in a scan that counted every villager, so a
    -- carrier the host never named cannot make the town look a cart short.
    local ops=full and 0 or 4
    for _,h in ipairs(missing) do
        local g=h and h.good
        if h and ops<4 and not halted() and total[g]<hostTotal[g] and aged('s'..h.id) then
            local best,bd
            for key,e in pairs(J.byKey or {}) do
                if carrierOf(key)==g and live(e.u) and not e.u.dead and not e.u:isSoldier() and not hostCarriers[key]
                    and not carriers[key] and #e.u.Inventory==0 then
                    local d=distance(e.u:K2_GetActorLocation(),h.pos)
                    if not bd or d<bd then best,bd=e,d end
                end
            end
            if best and give(best.u,g) then
                ops=ops+1; total[g]=total[g]+1
                put(h,drop(S,best,g),'mint',best.key)
            end
        end
    end
    for _,e in ipairs(lacking) do
        local g=e and want[e.key]
        if e and ops<4 and total[g]<hostTotal[g] and aged('l'..e.key) and give(e.u,g) then ops=ops+1; total[g]=total[g]+1; note('equip',e.key,'-') end
    end
    for _,e in ipairs(extra) do
        local g=e and cgood[e.key]
        if e and ops<4 and not halted() and total[g]>hostTotal[g] and aged('x'..e.key) and canDrop(e) then
            ops=ops+1
            local c=drop(S,e,g)
            if c and retire(S,c) then total[g]=total[g]-1; note('shed',e.key,'-') end
        end
    end
    -- A cart too many at a building the host's snapshot names needs no grace: the host's building is as it is here
    -- and has no such cart (sitting word_t1: a storehouse finished its upgrade here 1.2 s after the host's and the
    -- game made one cart more than the host's game had: it stood 1.1 s).
    local hostHome={}
    for _,id in ipairs(order) do hostHome[stands[id].home]=true end
    for _,c in ipairs(surplus) do
        if c and ops<4 and total[c.good]>hostTotal[c.good] and (aged('c'..c.name) or (c.home and c.home~='-' and hostHome[c.home])) and retire(S,c.c) then
            ops=ops+1; total[c.good]=total[c.good]-1; note('retire',c.name,c.home or '-')
        end
    end
    -- a cart whose list, owner and region disagree cannot be parked or taken: retired, the count is made good after
    for _,c in ipairs(odd) do
        if ops<4 and aged('o'..c.name) and retire(S,c.c) then ops=ops+1; total[c.good]=total[c.good]-1; note('odd',c.name,'-') end
    end
    local waiting=false
    for _,list in ipairs({missing,extra,lacking}) do for _,x in ipairs(list) do if x then waiting=true end end end
    if total[218]~=hostTotal[218] or total[345]~=hostTotal[345] or #odd>0 then waiting=true end
    waitSince=waiting and (waitSince or clock) or nil
    local stuck=waitSince and clock-waitSince>10
    needFull=(waiting and not stuck) or nil
    if full then for k in pairs(lag) do if not seen[k] then lag[k]=nil end end end   -- only a full scan dates corrections
    for k,v in pairs(pick) do if clock-v.at>180 then pick[k]=nil end end
    for k,v in pairs(park) do if clock-v.at>180 then park[k]=nil end end
    for k,v in pairs(word) do if clock-v.at>10 then word[k]=nil end end
    P.stats.total,P.stats.hostTotal=total[218],hostTotal[218]
    P.stats.total345,P.stats.hostTotal345=total[345],hostTotal[345]
    C.scene.byCart=used
    -- who carries here at the end of this scan: the 0.2 s look below compares against it
    had={}
    for key in pairs(known) do
        local e=J.byKey and J.byKey[key]
        if e and live(e.u) and not e.u.dead and carrierOf(key) and e.u:isEquipped(carrierOf(key)) then had[key]=true end
    end
    for _,r in pairs(again) do r.now=nil end
    -- the cart lists as this scan leaves them: a list that changes by itself is seen in the next frame (tick)
    watch={}
    local seenB={}
    local function keep(b)
        if live(b) and not seenB[addr(b)] then seenB[addr(b)]=true; watch[#watch+1]={b=b,n=#b.Carts} end
    end
    for _,info in pairs(owners) do keep(info.b) end
    for _,b in pairs(buildings) do if b then keep(b) end end
    return (waiting or next(lag)~=nil) and not stuck
end
-- (round 3, OXCART) the DLL's half of the timber carts (coop_patch README "PICK", round eight): while the board's PICK
-- is on and the host's word rules the timber carts here, the DLL is told the timber cart's class and the board's
-- oxen (the list again when it changes, looked at every 2 s); otherwise the class is unset. A game-made pickup of a
-- timber cart by one of those oxen then gets the stand record this module gave that ox (scan, park). Kept in this
-- module so that the board's own file is not touched for it.
-- A carrier the host still names lost its cart here (see the look in P.tick).
local function lostOne(key,e,clock)
    had[key]=nil; dirty=true
    local r=again[key]
    if not r or clock-r.t>2 then r={n=0,t=clock}; again[key]=r end
    r.n=r.n+1; r.now=r.n<=3 or nil
    local ty='-'
    pcall(function() local ts=e.u.Tasks; if #ts>0 then ty=tostring(ts[1].Type) end end)
    note('lost',key,string.format('task=%s free=%s q=%s pend=%s n=%d', ty, tostring(e.free==true), tostring(e.q~=nil), tostring(e.pend~=nil), r.n))
end
local function runScan(S,clock)
    dirty=nil; lastScan=clock
    local t0=os.clock()
    local ok,er=pcall(scan,S,clock)
    local ms=(os.clock()-t0)*1000
    P.stats.scans=P.stats.scans+1; P.stats.scanMs=P.stats.scanMs+ms
    if ms>P.stats.scanMaxMs then P.stats.scanMaxMs=ms end
    if not ok then
        haltedWorld=S.worlds; P.stats.halted=P.stats.halted+1
        A.log('cart settling stopped in this world: '..tostring(er))
    end
    open=ok and er or nil
    if haltedWorld==S.worlds then C.scene.byCart={} end
end
-- (round 7) The DLL keeps a class and a list only until an ALLOFF (coop.lua sends one at every change of role away from
-- friend); a class that did not change here would not be sent again. While a class is set it is sent again every 5 s
-- (with the oxen list), and a new world sends both at once.
local CLASS_AGAIN = 5.0
local oxCls, oxSent, oxT, oxClsT = 0, nil, nil, nil
local function oxcartStep(S,clock)
    local Pt, J = C.patch, C.jobs
    if not (Pt and Pt.pickOxen and Pt.pickTimber and J) then return end
    local cls = 0
    if J.pkOn and covered(345) and active(S,clock) then
        local c = S.eng.timberCartResourceBP
        cls = A.valid(c) and c:GetAddress() or 0
    end
    if cls ~= oxCls or (cls ~= 0 and clock - (oxClsT or -1e9) >= CLASS_AGAIN) then
        oxCls = cls; oxClsT = clock; oxT = nil; pcall(Pt.pickTimber, cls)
        if cls ~= 0 then oxSent = nil end                -- the oxen list goes again with it
    end
    if cls == 0 then
        if oxSent then oxSent = nil; pcall(Pt.pickOxen, {}) end
        return
    end
    if oxT and clock - oxT < 2.0 then return end
    oxT = clock
    local ox, keys = {}, {}
    for key, e in pairs(J.byKey or {}) do
        if key:match(OX) and live(e.u) then ox[#ox+1] = e.u:GetAddress(); keys[#keys+1] = key end
    end
    table.sort(keys)
    local sig = table.concat(keys, ' ')
    if sig ~= oxSent then oxSent = sig; pcall(Pt.pickOxen, ox) end
end
-- (round 7, HANDCART) A friend's villager takes a hand cart only on the host's word: while the board's PICK is on and
-- the host's word rules the hand carts here (P.ready), the DLL replaces a Gathering of a hand cart that the game sets
-- by itself with the villager's kept or current task (coop_patch README "PICK", design_handcart_pickup.txt). Before
-- the first snapshot (a join, a reload) the class is 0: nothing is touched while the board still gives cart lines.
-- Every frame while the host's word rules: a villager whose task is a Gathering of a hand cart that this copy's game set
-- by itself (the board gives no such record then, P.canGive) and that carries nothing yet stops: the game's own
-- setTask, standing where it is (endOwnLeg). That is what HANDCART leaves to this module ("left": a villager with no task
-- and no stand record; sitting own_a1: 7 such pickups of an idle villager, every 5 s), and the stand given here is the
-- record the DLL then keeps for that villager's next own pickup ("bystand"). Counted as "ownleg". The resource is known
-- for a hand cart by its address alone, in the scene module's table of this copy's hand carts (lane 64's looks keep a
-- freed one out of it): nothing is read from a resource that is not one.
local function endOwnPickups(S)
    local carts=C.scene and C.scene.carts
    if not carts then return end
    local timber=covered(345)
    for key,e in pairs(C.jobs.byKey or {}) do
        local villager=key:match(VILLAGER)
        if (villager or (timber and key:match(OX))) and live(e.u) and not e.u.dead then
            local ts=e.u.Tasks
            if #ts>0 and tonumber(ts[1].Type)==23 then
                local a=keptAddr(ts[1].Resource)
                -- (round 8) an ox the same way, for a timber cart (OXCART leaves a pickup through when it has no stand
                -- record for that ox yet: 1 of 36 in session hc_pin3): the stand given here is that record
                if a and ((villager and carts[a] and not e.u:isEquipped(218)) or (not villager and timberAddr[a] and not e.u:isEquipped(345))) then
                    endOwnLeg(e,'ownleg',string.format('%X',a))
                end
            end
        end
    end
end
local hcCls, hcT = 0, nil
local function handcartStep(S,clock)
    local Pt, J = C.patch, C.jobs
    if not (Pt and Pt.pickHandcart and J) then return end
    local cls = 0
    if J.pkOn and P.ready(S) then
        local c = S.eng.handcartResourceBP
        cls = A.valid(c) and c:GetAddress() or 0
    end
    if cls ~= hcCls or (cls ~= 0 and clock - (hcT or -1e9) >= CLASS_AGAIN) then
        hcCls = cls; hcT = clock; pcall(Pt.pickHandcart, cls)
    end
end
function P.tick(S,clock)
    if world ~= S.worlds then
        P.reset(S); oxSent = nil
        -- (round 8) a new world: the DLL first drops all it kept of the world before (each class set to 0 drops its
        -- kept records, native 0.9.18; the oxen list emptied), then the steps below send this world's. The timber
        -- class alone would have been sent again unchanged (it needs no snapshot), its old records kept.
        local Pt = C.patch
        if Pt then
            if Pt.pickTimber then pcall(Pt.pickTimber, 0) end
            if Pt.pickOxen then pcall(Pt.pickOxen, {}) end
            if Pt.pickHandcart then pcall(Pt.pickHandcart, 0) end
        end
        oxCls = 0; hcCls = 0
    end
    oxcartStep(S,clock)
    handcartStep(S,clock)
    if not active(S,clock) then
        if epoch or nonce then P.reset(S) end
        return
    end
    if not epoch then
        if not requested or clock-requested >= 1 then
            if not nonce then
                serial=(serial or 0)+1
                nonce=string.format('%.0f.%d',A.now()*1000,serial)
            end
            requested=clock; A.send('Q CA '..nonce)
        end
        return
    end
    if not hostCarriers or haltedWorld==S.worlds then return end
    endOwnPickups(S)
    -- Every frame: a villager that carried at the end of the last scan, that the host still names as a carrier, and
    -- that carries no more, lost its cart by itself. Cause (sitting word_d2, villager 8.17.2, and word_c1): the host's
    -- task given here ended at once (a carry with nothing in hands yet), the villager had no task, an ox asked it
    -- for a guide and the game started a Follow (41) of its own; the start of a Follow drops a hand cart. The scan
    -- runs in this same frame and gives the cart back (the dropped cart is the nearest: it is retired, the villager
    -- gets the item), so no frame is drawn with the cart loose. At most three times in 2 s for one villager; after
    -- that the ordinary wait applies.
    for key in pairs(had) do
        local e=C.jobs.byKey and C.jobs.byKey[key]
        if hostCarriers[key] and e and live(e.u) and not e.u.dead and not e.u:isEquipped(hostCarriers[key]) then
            lostOne(key,e,clock)
        end
    end
    -- Every frame: a building's cart list that changed by itself since the last scan (this copy's game made carts for
    -- a building it finished; an ox took its timber cart by its own choice, twice in the 900 s of sitting word_t1,
    -- each mended only at the next look, 0.4 and 0.7 s later). The scan runs in this frame and counts every carrier.
    for _,w in ipairs(watch) do
        if live(w.b) and #w.b.Carts~=w.n then dirty=true; needFull=true; P.stats.own=P.stats.own+1; break end
    end
    -- at once after the host's word; every 0.4 s while a difference waits; else a look every cfg.cartAudit seconds
    -- (2 s: what changes by itself between two words of the host is seen by the two looks above in its own frame;
    -- the audit is the net under them. At 1 s it was most of the 1,540 scans of session l74def, 7.4 ms each.)
    local since=clock-(lastScan or -1e9)
    if not (dirty or (open and since>=0.4) or since>=(C.jobs.cfg.cartAudit or 2.0)) then return end
    runScan(S,clock)
end
-- The host's word rules the hand carts only while this world's snapshot is open here. Before it (a join, a
-- reload, a lost link, a world where settling stopped) the board gives cart lines as it does with the feature off.
function P.ready(S)
    return epoch~=nil and hostCarriers~=nil and world==S.worlds and haltedWorld~=S.worlds and active(S,os.clock())
end
-- The board gave this villager a task of the host: a cart that waited for it is given in the next frame.
-- (round 3) That give may have started a task that drops the hand cart the villager carries (pin1, day 408: task 4;
-- the board ticks after this module in a frame, so the cart stood loose until the next frame's look and the world
-- module's reading saw one standing cart too many). A carrier the host still names that carries no more after the
-- give is handled now, in the same frame: the loss is noted and the scan runs (it gives the cart back).
function P.afterGive(e)
    if not e then return end
    if since[e.key] then dirty=true end
    local g=hostCarriers and hostCarriers[e.key]
    if not (g and had[e.key]) then return end
    local S=C.s
    if not (P.ready(S) and live(e.u)) or e.u.dead or e.u:isEquipped(g) then return end
    local clock=os.clock()
    lostOne(e.key,e,clock)
    P.stats.giveLost=(P.stats.giveLost or 0)+1
    runScan(S,clock)
end
-- An ordinary lookup must not hand a parked hand cart to a villager of this copy while the host's word rules them.
-- Is this resource a cart the host's word rules (a hand cart; a timber cart with cfg.cartTimber)?
function P.isCart(S,resource)
    if not (live(resource) and live(S.eng)) then return false end
    local cls=addr(resource:GetClass())
    if cls==addr(S.eng.handcartResourceBP) then return true end
    return covered(345) and A.valid(S.eng.timberCartResourceBP) and cls==addr(S.eng.timberCartResourceBP)
end
function P.timber() return covered(345) end
function P.canGive(S,rec,e,resource)
    if P.ready(S) and P.isCart(S,resource) then return false end
    return true
end
-- An equipped handcart and a parked resource are exclusive states. Count both
-- immediately before replacing a missing tool. A different carrier or an
-- occupied stand already accounts for that cart, even if it is far away.
function P.stock(S,u,names)
    if not live(S.eng) or not live(u) then return end
    local region=addr(u.currentRegion)
    local eng=S.eng
    local map=addr(eng:GetWorld())
    if not region or not map then return end
    local regionIndex
    local regions=eng.regions
    for i=1,#regions do if addr(A.un(regions[i]))==region then regionIndex=i; break end end
    if not regionIndex then return end
    local total,localCount=0,0
    for _,c in ipairs(FindAllOf('Resource_Handcart_C') or {}) do
        if live(c) and addr(c:GetWorld())==map then
            local p=c:K2_GetActorLocation()
            if math.abs(p.X)+math.abs(p.Y)>100 then
                if addr(c:getMaster())~=addr(eng) or not A.valid(c.Region) then return end
                total=total+1
                if names then names[c:GetFName():ToString()]=true end
                if addr(c.Region)==region then localCount=localCount+1 end
            end
        end
    end
    local units=eng.unitArr
    for i=1,#units do
        local carrier=A.un(units[i])
        if live(carrier) and not carrier.dead and carrier:isEquipped(218) then
            total=total+1
            if addr(carrier.currentRegion)==region then localCount=localCount+1 end
        end
    end
    return total,regionIndex,localCount
end
-- The game gives a returned resource a new actor number. The pickup line
-- already identifies the source. Join it to the observed new occupant after
-- the named carrier loses item 218. Two possible returns remain unresolved.
function P.dropStarted(S,e,t,source)
    local h=parse(source)
    local names={}
    local total,region,count=P.stock(S,e.u,names)
    if total and h and e.u:isEquipped(218) then
        local old=hostDrops[e.key]
        if not old or old.source~=h.id then
            local pos=t.TargetLocation.Pos
            hostDrops[e.key]={source=h.id,names=names,x=pos.X,y=pos.Y,unit=e.addr,at=os.clock()}
        end
    end
    return total,region,count
end
-- Host: the villagers that carry a hand cart now, for the same snapshot as the stands.
function P.hostCarriers()
    local keys={}
    for key,e in pairs((C.jobs and C.jobs.byKey) or {}) do
        if key:match(VILLAGER) and live(e.u) and not e.u.dead and e.u:isEquipped(218) then keys[#keys+1]=key end
    end
    table.sort(keys)
    -- after "|": the oxen that pull a timber cart (their keys hold commas: joined by ";")
    local oxen={}
    for key,e in pairs((C.jobs and C.jobs.byKey) or {}) do
        if key:match(OX) and live(e.u) and not e.u.dead and e.u:isEquipped(345) then oxen[#oxen+1]=key end
    end
    table.sort(oxen)
    return (#keys>0 and table.concat(keys,',') or '-')..'|'..(#oxen>0 and table.concat(oxen,';') or '-')
end
function P.hostReturns(S,physical,listed,clock)
    if not next(hostDrops) then return end
    local candidates,uses,words={},{},{}
    for _,word in ipairs(physical) do
        local h=parse(word)
        if h and h.good==218 then words[h.id]={h=h,word=word} end
    end
    local function observe(a,c)
        local item=words[C.scene.cartId[a]]
        if not item or not live(c) or addr(c:getMaster())~=addr(S.eng) then return end
        local owner=c.belongsTo
        if item.h.home~='-' then
            if not live(owner) or homeOf(owner)~=item.h.home or not A.valid(c.Region) or addr(c.Region)~=addr(owner.Region) then return end
        elseif A.valid(owner) or not A.valid(c.Region) then return end
        item.name=c:GetFName():ToString()
    end
    for a,c in pairs(listed) do observe(a,c) end
    for a,c in pairs(C.scene.carts or {}) do if not listed[a] then observe(a,c) end end
    for key,drop in pairs(hostDrops) do
        local e=C.jobs.byKey and C.jobs.byKey[key]
        if not e or e.addr~=drop.unit or not live(e.u) or e.u.dead or clock-drop.at>180 then
            hostDrops[key]=nil
        elseif not e.u:isEquipped(218) then
            local matches=0
            for id,item in pairs(words) do
                local p=item.h.pos
                if item.name and not drop.names[item.name] and (p.X-drop.x)^2+(p.Y-drop.y)^2<=9 then
                    matches=matches+1
                    candidates[key]=id
                    uses[id]=(uses[id] or 0)+1
                end
            end
            -- Several new actors at this one stand cannot establish which one came back.
            if matches>1 then candidates[key]=nil; hostDrops[key]=nil; P.stats.ambiguous=P.stats.ambiguous+1 end
        end
    end
    for key,id in pairs(candidates) do
        if id and uses[id]==1 and hostDrops[key] then
            A.send(string.format('Q CR %d %s %d %s',S.worlds,key,hostDrops[key].source,words[id].word))
            hostDrops[key]=nil
        elseif id and uses[id]>1 then
            hostDrops[key]=nil; P.stats.ambiguous=P.stats.ambiguous+1
        end
    end
end
return 'registered cart stands loaded'
