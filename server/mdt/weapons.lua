---@type table sd-phone config root (configs/config.lua); read for the shared paging bounds.
local config           = require 'configs.config'
---@type table Shared server helpers (server.util): envelopes, clamping, TINYINT reads.
local util             = require 'server.util'
---@type table MDT permissions (server.mdt.access): the read gate and the audited write wrapper.
local access           = require 'server.mdt.access'
---@type table MDT persistence (server.mdt.store): display-name hydration for owners and officers.
local store            = require 'server.mdt.store'
---@type table Framework record bridge (bridge.server.records): the citizen an owner resolves to.
local frameworkRecords = require 'bridge.server.records'

---@type table Weapons module; the table returned at end of file. The firearms registry is MDT-owned
---end to end: nothing outside this terminal writes phone_mdt_weapons, so the serial on the frame is
---the only key a lookup ever runs on.
local weapons = {}

---@type table MDT config (configs/mdt.lua).
local MDT = config.Mdt

---@type integer Rows returned per page.
local PAGE_SIZE = math.floor(tonumber((MDT.Paging or {}).PageSize) or 25)

---@type integer Highest page a client may ask for.
local MAX_PAGE = math.floor(tonumber((MDT.Paging or {}).MaxPage) or 400)

---@type integer Byte cap on a search term.
local MAX_QUERY = 64

---@type integer Byte cap on a serial number.
local MAX_SERIAL = 32

---@type integer Byte cap on the firearm's display name.
local MAX_NAME = 96

---@type integer Byte cap on a citizenid.
local MAX_CID = 64

---@type integer Byte cap on an officer's free-text notes.
local MAX_NOTES = 2000

---@type integer Shortest search term that reaches the database. A single character matches most of
---the registry, so it is answered as the unfiltered page instead.
local MIN_QUERY = 2

---@type table<string, boolean> Registry states a record accepts; mirrors the WeaponStatus union in
---web/src/apps/mdt/data.ts.
local STATUSES = {
    registered = true,
    stolen     = true,
    seized     = true,
    destroyed  = true,
}

---@type table<string, boolean> Classes the registry files a firearm under; mirrors the WeaponClass
---union in web/src/apps/mdt/data.ts.
local CLASSES = {
    pistol  = true,
    smg     = true,
    rifle   = true,
    shotgun = true,
    sniper  = true,
    melee   = true,
    other   = true,
}

---Coerces a client page number to a whole page inside the served range.
---@param v any client-supplied page
---@return integer page 1..MAX_PAGE
local function pageOf(v)
    local n = tonumber(v)
    if type(n) ~= 'number' or not util.finite(n) then return 1 end
    local page = math.floor(n)
    if page ~= n or page < 1 then return 1 end
    return page > MAX_PAGE and MAX_PAGE or page
end

---Escapes the LIKE wildcards in a search term.
---@param term string
---@return string
local function likeSafe(term)
    return (term:gsub('([%%_\\])', '\\%1'))
end

---Normalises a client-supplied serial to the one shape the registry stores: upper case, no
---whitespace. Two officers typing the same frame stamp differently must land on the same row.
---@param v any client-supplied serial
---@return string|nil serial nil when nothing usable was sent
local function serialOf(v)
    local s = util.limitedString(v, MAX_SERIAL)
    if not s then return nil end
    s = (s:upper():gsub('%s+', ''))
    return s ~= '' and s or nil
end

---Display names for every citizenid a set of rows mentions, in one lookup.
---@param rows table[] raw registry rows
---@return table<string, string> names
local function namesIn(rows)
    local cids = {}

    ---Appends one identifier when it is worth resolving. A nil column is common here (an
    ---unregistered firearm, a record nobody has edited yet), so this cannot be an ipairs walk over
    ---the three columns: the first nil would end it and drop the rest.
    ---@param cid any
    local function want(cid)
        if type(cid) == 'string' and cid ~= '' then cids[#cids + 1] = cid end
    end

    for i = 1, #rows do
        want(rows[i].owner)
        want(rows[i].registered_by)
        want(rows[i].updated_by)
    end
    return store.namesFor(cids)
end

---A stored name that is still worth showing, or nil. Blank columns are dropped rather than sent as
---empty strings, so the UI's "not on file" fallback is what renders.
---@param value any
---@return string|nil
local function textOrNil(value)
    return (type(value) == 'string' and value ~= '') and value or nil
end

---The wire shape for one registry row in a list.
---@param row table raw DB row
---@param names table<string, string> citizenid -> display name
---@return table weapon
local function rowOf(row, names)
    local owner = textOrNil(row.owner)
    return {
        serial       = row.serial,
        name         = row.name or '',
        class        = CLASSES[row.class] and row.class or 'other',
        owner        = owner,
        ownerName    = owner and (names[owner] or textOrNil(row.owner_name) or owner) or nil,
        status       = STATUSES[row.status] and row.status or 'registered',
        bolo         = util.truthy(row.bolo),
        registeredAt = tonumber(row.registered_at) or 0,
    }
end

---The wire shape for one registry row in full.
---@param row table raw DB row
---@param names table<string, string> citizenid -> display name
---@return table weapon
local function detailOf(row, names)
    local weapon = rowOf(row, names)
    local filedBy = textOrNil(row.registered_by)
    local editedBy = textOrNil(row.updated_by)

    weapon.notes        = row.notes or ''
    weapon.ballistics   = util.truthy(row.ballistics)
    weapon.registeredBy = filedBy and (names[filedBy] or filedBy) or nil
    weapon.updatedBy    = editedBy and (names[editedBy] or editedBy) or nil
    weapon.updatedAt    = tonumber(row.updated_at)
    return weapon
end

---One registry row by serial, already shaped for the wire.
---@param serial string normalised serial
---@return table|nil weapon
local function readOne(serial)
    local row = MySQL.single.await('SELECT * FROM phone_mdt_weapons WHERE serial = ? LIMIT 1', { serial })
    if not row then return nil end
    return detailOf(row, namesIn({ row }))
end

---Resolves an owner a client named, refusing an identifier that belongs to nobody. An empty owner
---is allowed and means the firearm is on the registry with nobody attached to it, which is what a
---recovery with a filed-off frame looks like.
---@param value any client-supplied citizenid
---@return string|nil citizenid nil when the field was left empty
---@return string|nil name display name, nil when the field was left empty
---@return string|nil refusal set when the identifier belongs to nobody
local function ownerFrom(value)
    local cid = util.limitedString(value, MAX_CID)
    if not cid then return nil, nil, nil end

    local citizen = frameworkRecords.getCitizen(cid)
    if not citizen then return nil, nil, 'No citizen holds that ID' end
    return cid, citizen.name or cid, nil
end

---The registry page, filtered by status and searched across serial, firearm and owner. A term
---shorter than MIN_QUERY is treated as no term at all rather than as a match on everything.
weapons.search = access.gated('weapons.view', function(_, payload)
    local where, params = {}, {}

    local status = util.limitedString(payload.status, 16)
    if status and status ~= 'all' then
        if not STATUSES[status] then return util.fail('Pick a valid registry status') end
        where[#where + 1] = 'status = ?'
        params[#params + 1] = status
    end

    local query = util.limitedString(payload.query, MAX_QUERY)
    if query and #query >= MIN_QUERY then
        where[#where + 1] = '(serial LIKE ? OR `name` LIKE ? OR owner_name LIKE ? OR owner LIKE ?)'
        local like = '%' .. likeSafe(query) .. '%'
        for _ = 1, 4 do params[#params + 1] = like end
    end

    local clauses = #where > 0 and table.concat(where, ' AND ') or '1'
    local total = tonumber(MySQL.scalar.await(
        ('SELECT COUNT(*) FROM phone_mdt_weapons WHERE %s'):format(clauses), params)) or 0

    local page = pageOf(payload.page)
    local rows = MySQL.query.await(([[
        SELECT * FROM phone_mdt_weapons WHERE %s
        ORDER BY registered_at DESC, serial ASC LIMIT %d OFFSET %d
    ]]):format(clauses, PAGE_SIZE, (page - 1) * PAGE_SIZE), params) or {}

    local names = namesIn(rows)
    local out = {}
    for i = 1, #rows do out[i] = rowOf(rows[i], names) end

    return util.ok({ rows = out, total = total, page = page, pageSize = PAGE_SIZE })
end)

---One firearm in full.
weapons.get = access.gated('weapons.view', function(_, payload)
    local serial = serialOf(payload.serial)
    if not serial then return util.fail('No serial number given') end

    local weapon = readOne(serial)
    if not weapon then return util.fail('No firearm registered on that serial') end
    return util.ok({ weapon = weapon })
end)

---Files a new firearm. The serial is the primary key, so a duplicate is refused rather than
---silently overwriting whatever the registry already holds against it.
weapons.create = access.audited('weapons.edit', function(_, payload, me)
    local serial = serialOf(payload.serial)
    if not serial then return util.fail('A serial number is required') end

    local name = util.limitedString(payload.name, MAX_NAME)
    if not name then return util.fail('Name the firearm') end

    local class = util.limitedString(payload.class, 16) or 'other'
    if not CLASSES[class] then return util.fail('Pick a valid firearm class') end

    local owner, ownerName, refusal = ownerFrom(payload.owner)
    if refusal then return util.fail(refusal) end

    local notes = util.limitedString(payload.notes, MAX_NOTES) or ''

    local taken = MySQL.scalar.await('SELECT 1 FROM phone_mdt_weapons WHERE serial = ? LIMIT 1', { serial })
    if taken then return util.fail('That serial is already on the registry') end

    local now = os.time()
    MySQL.query.await([[
        INSERT INTO phone_mdt_weapons
            (serial, `name`, class, owner, owner_name, status, bolo, ballistics, notes,
             registered_by, registered_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'registered', 0, 0, ?, ?, ?, ?)
    ]], { serial, name, class, owner, ownerName, notes, me.citizenid, now, now })

    local weapon = readOne(serial)
    if not weapon then return util.fail('That could not be registered') end

    return util.ok({ weapon = weapon }), {
        entityType = 'weapon',
        entityId   = serial,
        details    = { name = name, class = class, owner = owner },
    }
end)

---Updates the registry record on a firearm already on file. Every field is optional; an absent key
---leaves the stored value alone, and an empty owner clears the registration rather than failing.
weapons.update = access.audited('weapons.edit', function(_, payload, me)
    local serial = serialOf(payload.serial)
    if not serial then return util.fail('No serial number given') end

    local current = MySQL.single.await('SELECT * FROM phone_mdt_weapons WHERE serial = ? LIMIT 1', { serial })
    if not current then return util.fail('No firearm registered on that serial') end

    local status = STATUSES[current.status] and current.status or 'registered'
    if payload.status ~= nil then
        local wanted = util.limitedString(payload.status, 16)
        if not wanted or not STATUSES[wanted] then return util.fail('Pick a valid registry status') end
        status = wanted
    end

    local owner, ownerName = textOrNil(current.owner), textOrNil(current.owner_name)
    if payload.owner ~= nil then
        local refusal
        owner, ownerName, refusal = ownerFrom(payload.owner)
        if refusal then return util.fail(refusal) end
    end

    local notes = current.notes or ''
    if payload.notes ~= nil then notes = util.limitedString(payload.notes, MAX_NOTES) or '' end

    local bolo = util.truthy(current.bolo)
    if payload.bolo ~= nil then bolo = payload.bolo == true end

    local ballistics = util.truthy(current.ballistics)
    if payload.ballistics ~= nil then ballistics = payload.ballistics == true end

    MySQL.query.await([[
        UPDATE phone_mdt_weapons
        SET status = ?, owner = ?, owner_name = ?, bolo = ?, ballistics = ?, notes = ?,
            updated_by = ?, updated_at = ?
        WHERE serial = ?
    ]], {
        status, owner, ownerName, bolo and 1 or 0, ballistics and 1 or 0, notes,
        me.citizenid, os.time(), serial,
    })

    local weapon = readOne(serial)
    if not weapon then return util.fail('No firearm registered on that serial') end

    return util.ok({ weapon = weapon }), {
        entityType = 'weapon',
        entityId   = serial,
        details    = { status = status, owner = owner, bolo = bolo, ballistics = ballistics },
    }
end)

return weapons
