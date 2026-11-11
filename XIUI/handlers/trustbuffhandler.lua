-- XIUI Trust Buff Handler
-- The server never sends status effects for Trusts: packet 0x076 (party buffs) only covers
-- the other players in the party, and the client keeps no buff list for Trust entities.
-- This rebuilds them from the combat messages the client does receive:
--   0x028 action packets: "<trust> gains the effect of X", "<trust> is paralyzed", ...
--   0x029 message packets: "<trust>'s X effect wears off", death, ...
-- Durations are not in those packets, so icons have no timers (the same as other players
-- in the party list). An effect is removed when the server says it wore off, was removed,
-- or the Trust died, left the party or you zoned. MAX_AGE drops effects whose wear-off
-- message was missed (out of range).

require('common');
local buffTable = require('libs.bufftable');

local trustBuffHandler = {};

-- [serverId] = { [effectId] = appliedAt (os.time) }
local trustEffects = {};
-- Reused per call so the party list doesn't allocate a table per Trust per frame.
local listCache = {};

local MAX_AGE = 1800;          -- seconds; covers Protect/Shell, the longest common Trust buffs
local TRUST_INDEX_MIN = 0x700; -- Trusts (like pets) use target indexes from 0x700 up
local PARTY_REFRESH = 1.0;     -- seconds between rescans of which party members are Trusts

-- "<target> gains / receives / is <status>": param is the status id.
-- Union of the lists in petbuffhandler (ally buffs) and debuffhandler (status landing).
local statusOnMes = {
    [29]=true, [84]=true, [127]=true, [160]=true, [164]=true, [166]=true, [186]=true,
    [194]=true, [203]=true, [205]=true, [230]=true, [236]=true, [237]=true, [242]=true,
    [243]=true, [266]=true, [267]=true, [268]=true, [269]=true, [271]=true, [272]=true,
    [277]=true, [278]=true, [279]=true, [280]=true, [319]=true, [320]=true, [374]=true,
    [375]=true, [412]=true, [420]=true, [421]=true, [645]=true, [754]=true, [755]=true,
    [804]=true,
};
-- "<target>'s <status> wears off / is removed / disappears": param is the status id.
local statusOffMes = {
    [64]=true, [83]=true, [159]=true, [168]=true, [204]=true, [206]=true, [321]=true,
    [322]=true, [341]=true, [342]=true, [343]=true, [344]=true, [350]=true, [378]=true,
    [426]=true, [427]=true, [531]=true, [647]=true, [805]=true, [806]=true,
};
local deathMes = {
    [6]=true, [20]=true, [97]=true, [113]=true, [406]=true, [605]=true, [646]=true,
};

-- Server ids of the Trusts currently in your party, refreshed at most once a second.
local trustIds = {};
local lastPartyScan = 0;

local function RefreshTrustIds()
    local now = os.clock();
    if (now - lastPartyScan) < PARTY_REFRESH then
        return;
    end
    lastPartyScan = now;

    local party = AshitaCore:GetMemoryManager():GetParty();
    local current = {};
    if party then
        for i = 1, 5 do
            if party:GetMemberIsActive(i) ~= 0 then
                local index = party:GetMemberTargetIndex(i);
                local serverId = party:GetMemberServerId(i);
                if serverId ~= 0 and index >= TRUST_INDEX_MIN then
                    current[serverId] = true;
                end
            end
        end
    end
    trustIds = current;

    -- Forget Trusts that left the party (released, dismissed, or the party disbanded).
    for serverId in pairs(trustEffects) do
        if not current[serverId] then
            trustEffects[serverId] = nil;
        end
    end
end

local function IsTrust(serverId)
    RefreshTrustIds();
    return serverId ~= nil and trustIds[serverId] == true;
end

local function Apply(serverId, effectId)
    if not effectId or effectId <= 0 or effectId >= 1000 or effectId == 255 then
        return;
    end
    local effects = trustEffects[serverId];
    if not effects then
        effects = {};
        trustEffects[serverId] = effects;
    end
    effects[effectId] = os.time();
end

local function Remove(serverId, effectId)
    local effects = trustEffects[serverId];
    if effects and effectId then
        effects[effectId] = nil;
    end
end

local function HandleResult(serverId, actionType, spellId, message, param)
    if not message then
        return;
    end
    if statusOnMes[message] then
        local effectId = param;
        -- Some spell lands carry no status id; derive it from the spell.
        if (not effectId or effectId == 0) and actionType == 4 then
            effectId = buffTable.GetBuffIdBySpellId(spellId);
        end
        Apply(serverId, effectId);
    elseif statusOffMes[message] then
        Remove(serverId, param);
    end
end

trustBuffHandler.HandleActionPacket = function(actionPacket)
    if not actionPacket or not actionPacket.Targets then
        return;
    end
    for _, target in pairs(actionPacket.Targets) do
        if IsTrust(target.Id) then
            for _, action in pairs(target.Actions or {}) do
                HandleResult(target.Id, actionPacket.Type, actionPacket.Param, action.Message, action.Param);
                local extra = action.AdditionalEffect;
                if extra and extra.Message then
                    HandleResult(target.Id, actionPacket.Type, actionPacket.Param, extra.Message, extra.Param);
                end
            end
        end
    end
end

trustBuffHandler.HandleMessagePacket = function(messagePacket)
    if not messagePacket then
        return;
    end
    local message = messagePacket.message;
    -- Wear-off (206) names the affected entity as the sender; most others use the target.
    local serverId = messagePacket.target;
    if not IsTrust(serverId) then
        if message == 206 and IsTrust(messagePacket.sender) then
            serverId = messagePacket.sender;
        else
            return;
        end
    end

    if deathMes[message] then
        trustEffects[serverId] = nil;
    elseif statusOnMes[message] then
        Apply(serverId, messagePacket.param);
    elseif statusOffMes[message] then
        Remove(serverId, messagePacket.param);
    end
end

trustBuffHandler.HandleZonePacket = function()
    trustEffects = {};
    listCache = {};
    trustIds = {};
    lastPartyScan = 0;
end

-- Returns a list of status ids for a Trust in your party, or nil if it has none tracked
-- (or the server id isn't a Trust). Same shape the party list and target bar already use.
trustBuffHandler.GetBuffs = function(serverId)
    if not IsTrust(serverId) then
        return nil;
    end
    local effects = trustEffects[serverId];
    if not effects then
        return nil;
    end

    local list = listCache[serverId];
    if not list then
        list = {};
        listCache[serverId] = list;
    end
    for i = #list, 1, -1 do
        list[i] = nil;
    end

    local now = os.time();
    local count = 0;
    for effectId, appliedAt in pairs(effects) do
        if (now - appliedAt) > MAX_AGE then
            effects[effectId] = nil;
        else
            count = count + 1;
            list[count] = effectId;
        end
    end
    if count == 0 then
        return nil;
    end
    table.sort(list);
    return list;
end

trustBuffHandler.ClearAll = function()
    trustEffects = {};
end

return trustBuffHandler;
