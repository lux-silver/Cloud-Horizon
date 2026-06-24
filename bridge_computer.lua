-- bridge_computer.lua v3
-- Fixes:
--   1. bank_deposit: não faz getCfg() extra — usa dados já no response do server
--   2. bank_deposit source=inventory: só faz removeItemFromPlayer se a moeda existe no inv
--   3. bank_withdraw: move direto bank_vault → invmanager sem vault intermediário
--   4. Removido getCfg() redundante em todos os ops mistos (server já retorna _uname + cfg)
--   5. cfgCache TTL aumentado para 600s (era 300s)

local PROTOCOL    = "cloud_ui"
-- SERVER_URL é dinâmico — verificado a cada 60s via GitHub ou URL cacheada
local URL_SRC    = "https://raw.githubusercontent.com/Oorange2/cc-player-radar/main/tunnel_url.txt"
local URL_CACHE  = "/.bridge_url"
local SERVER_URL = ""  -- preenchido no boot por loadServerUrl()

local function loadServerUrl()
    -- 1. Tenta GitHub (fonte de verdade)
    local ok, res = pcall(http.get, URL_SRC)
    if ok and res then
        local u = res.readAll():gsub("%s+",""); res.close()
        if u and #u > 10 then
            SERVER_URL = u
            local f = fs.open(URL_CACHE,"w"); f.write(u); f.close()
            return true
        end
    end
    -- 2. Fallback: cache local
    if fs.exists(URL_CACHE) then
        local f = fs.open(URL_CACHE,"r")
        local u = f.readAll():gsub("%s+",""); f.close()
        if u and #u > 10 then SERVER_URL = u; return true end
    end
    return false
end

-- Carrega URL no boot
if not loadServerUrl() then
    print("ERRO: Não foi possível obter SERVER_URL")
    print("Coloque a URL em "..URL_CACHE.." e reinicie")
    error("No server URL", 0)
end
local API_KEY     = "4bcd38c0c1797434951991004ef5474a"
local BRIDGE_KEY  = "f7c14de40d2da4e12ed1b4334f8b2425"

local BANK_VAULT    = "create:item_vault_30"
local MARKET_VAULTS = {"create:item_vault_37","create:item_vault_71","create:item_vault_50"}
local FOOD_VAULT    = "create:item_vault_63"
local DENOMS = {
    {name="numismatics:sun",      value=4096},
    {name="numismatics:crown",    value=512},
    {name="numismatics:cog",      value=64},
    {name="numismatics:sprocket", value=16},
    {name="numismatics:bevel",    value=8},
    {name="numismatics:spur",     value=1},
}

-- Open all modems (ender modem compatible)
for _, name in ipairs(peripheral.getNames()) do
    pcall(rednet.open, name)
end

-- ── HTTP helpers ──────────────────────────────────────────────────────────────
local apiHeaders = {
    ["Content-Type"] = "application/json",
    ["x-api-key"]    = API_KEY,
}
local brgHeaders = {
    ["Content-Type"] = "application/json",
    ["x-api-key"]    = API_KEY,
    ["x-bridge-key"] = BRIDGE_KEY,
}

local function apiPost(path, body)
    local ok, res = pcall(http.post, SERVER_URL..path,
        textutils.serialiseJSON(body or {}), apiHeaders)
    if not ok or not res then return nil end
    local d = textutils.unserialiseJSON(res.readAll()); res.close()
    return d
end

local function brgPost(path, body)
    local ok, res = pcall(http.post, SERVER_URL..path,
        textutils.serialiseJSON(body or {}), brgHeaders)
    if not ok or not res then return nil end
    local d = textutils.unserialiseJSON(res.readAll()); res.close()
    return d
end

local function brgGet(path)
    local ok, res = pcall(http.get, SERVER_URL..path, brgHeaders)
    if not ok or not res then return nil end
    local d = textutils.unserialiseJSON(res.readAll()); res.close()
    return d
end

-- ── Config cache (10 min TTL) ─────────────────────────────────────────────────
local cfgCache = {}
local function getCfg(uname)
    local now = os.epoch("utc") / 1000
    local c = cfgCache[uname]
    if c and (now - c.ts) < 600 then return c.cfg end
    local r = brgGet("/bridge/user_config?username="..uname)
    if r and r.ok then cfgCache[uname] = {cfg=r, ts=now}; return r end
    return nil
end

-- ── Physical helpers ──────────────────────────────────────────────────────────
local function moveItem(fromV, toV, name, count)
    if not peripheral.isPresent(fromV) then return 0 end
    local from = peripheral.wrap(fromV)
    local ok, items = pcall(function() return from.list() end)
    if not ok or type(items) ~= "table" then return 0 end
    local moved = 0
    for slot, item in pairs(items) do
        if item.name == name and moved < count then
            local ok2, n = pcall(function()
                return from.pushItems(toV, slot, count - moved)
            end)
            if ok2 and n then moved = moved + n end
        end
        if moved >= count then break end
    end
    return moved
end

local function listPeriphItems(vname)
    if not peripheral.isPresent(vname) then return nil, "Not found: "..vname end
    local v = peripheral.wrap(vname)
    local ok, raw = pcall(function() return v.list() end)
    if not ok or type(raw) ~= "table" then
        ok, raw = pcall(function() return v.getItems() end)
    end
    if not ok or type(raw) ~= "table" then return nil, "list() failed" end
    local merged = {}
    local firstSlot = {}
    for slot, item in pairs(raw) do
        if item and item.name then
            if not merged[item.name] then
                merged[item.name] = {name=item.name, displayName=item.name, count=0}
                firstSlot[item.name] = slot
            end
            merged[item.name].count = merged[item.name].count + (item.count or 1)
        end
    end
    if v.getItemDetail then
        -- Batch in chunks of 8 to avoid overloading CC's parallel limit
        local tasks = {}
        for iname, slot in pairs(firstSlot) do
            local n, s = iname, slot
            table.insert(tasks, function()
                local ok2, detail = pcall(v.getItemDetail, s)
                if ok2 and detail and detail.displayName then
                    merged[n].displayName = detail.displayName
                end
            end)
        end
        local CHUNK = 8
        for i = 1, #tasks, CHUNK do
            local batch = {}
            for j = i, math.min(i + CHUNK - 1, #tasks) do
                table.insert(batch, tasks[j])
            end
            parallel.waitForAll(table.unpack(batch))
        end
    end
    local out = {}
    for _, e in pairs(merged) do table.insert(out, e) end
    table.sort(out, function(a,b) return a.displayName < b.displayName end)
    return out, nil
end

local function moveToMarket(fromV, name, count)
    local moved = 0
    for _, v in ipairs(MARKET_VAULTS) do
        if moved >= count then break end
        moved = moved + moveItem(fromV, v, name, count - moved)
    end
    return moved
end

local function moveFromMarket(toV, name, count)
    local moved = 0
    for _, v in ipairs(MARKET_VAULTS) do
        if moved >= count then break end
        moved = moved + moveItem(v, toV, name, count - moved)
    end
    return moved
end

local function completeBridgeOp(id, phyOk, result)
    return brgPost("/bridge/complete", {id=id, ok=phyOk, result=result})
end

-- ── Monitor event emitter ─────────────────────────────────────────────────────
-- Definido cedo para estar disponível em todos os loops abaixo.
local MON_PROTO = "cloud_monitor"
local MON_ID    = nil  -- nil = usa os.queueEvent local; number = envia via rednet

local function monEmit(data)
    pcall(os.queueEvent, "cloud_monitor", data)
    if MON_ID then pcall(rednet.send, MON_ID, data, MON_PROTO) end
end

local function monLog(level, msg)
    monEmit({type="log", level=level, msg=msg})
end


-- ── Reply helper ──────────────────────────────────────────────────────────────
local function reply(cid, data, seq)
    if seq then data._seq = seq end
    rednet.send(cid, data, PROTOCOL)
end

-- ── Message handler ───────────────────────────────────────────────────────────
local PROXY = {
    login                = "/login",
    get_log              = "/get_log",
    bank_info            = "/bank_info",
    bank_get_loan        = "/bank_get_loan",
    bank_pay_loan        = "/bank_pay_loan",
    bank_get_log         = "/bank_get_log",
    bank_transfer        = "/bank_transfer",
    get_notif_count      = "/get_notif_count",
    get_notifications    = "/get_notifications",
    market_public_list   = "/market_public_list",
    market_list          = "/market_list",
    market_create_listing= "/market_create_listing",
    market_edit_listing  = "/market_edit_listing",
    market_boost_listing = "/market_boost_listing",
    market_my_listings   = "/market_my_listings",
    coinflip_create      = "/coinflip_create",
    coinflip_list        = "/coinflip_list",
    coinflip_join        = "/coinflip_join",
    coinflip_cancel      = "/coinflip_cancel",
    coinflip_my_bets     = "/coinflip_my_bets",
    slots_spin           = "/slots_spin",
    mines_start          = "/mines_start",
    mines_reveal         = "/mines_reveal",
    mines_cashout        = "/mines_cashout",
    get_leaderboard      = "/get_leaderboard",
    admin_list_users     = "/admin_list_users",
    admin_create_user    = "/admin_create_user",
    admin_delete_user    = "/admin_delete_user",
    admin_bank_overview  = "/admin_bank_overview",
    subscription_food_items = "/subscription_food_items",
    subscription_status     = "/subscription_status",
    subscription_create     = "/subscription_create",
    subscription_cancel     = "/subscription_cancel",
}

local function handle(cid, msg)
    local t   = msg.type
    local seq = msg._seq

    -- ── Pure proxy ─────────────────────────────────────────────────────────────
    if PROXY[t] then
        local r = apiPost(PROXY[t], msg)
        reply(cid, r or {ok=false, err="Server error"}, seq)
        return
    end

    -- ── Debug ──────────────────────────────────────────────────────────────────
    if t == "debug_peripherals" then
        reply(cid, {names=peripheral.getNames()}, seq)
        return
    end

    -- ── Local-only vault/inventory ops ─────────────────────────────────────────
    if t == "list_vault" then
        local r = apiPost("/bank_info", msg)
        if not r or r.err then reply(cid, {items={}, err=r and r.err or "Session error"}, seq); return end
        if not r.vault then reply(cid, {items={}, err="No vault configured"}, seq); return end
        local items, err = listPeriphItems(r.vault)
        reply(cid, {items=items or {}, err=err}, seq)
        return
    end

    if t == "list_inventory" then
        local sessR = brgPost("/get_session_uname", msg)
        if not sessR or not sessR.uname then reply(cid, {items={}, err="Session error"}, seq); return end
        local cfg = getCfg(sessR.uname)
        if not cfg or not cfg.invmanager then reply(cid, {items={}, err="No inventory manager"}, seq); return end
        local items, err = listPeriphItems(cfg.invmanager)
        reply(cid, {items=items or {}, err=err}, seq)
        return
    end

    if t == "list_bank_vault" then
        local denoms = {}
        if peripheral.isPresent(BANK_VAULT) then
            local ok2, items = pcall(function() return peripheral.wrap(BANK_VAULT).list() end)
            if ok2 and type(items) == "table" then
                for _, item in pairs(items) do
                    if item and item.name then
                        denoms[item.name] = (denoms[item.name] or 0) + (item.count or 1)
                    end
                end
            end
        end
        reply(cid, {ok=true, denoms=denoms}, seq)
        return
    end

    -- ── Admin ops que precisam de sessão ────────────────────────────────────────
    if t == "withdraw" or t == "deposit" or
       t == "admin_view_vault" or t == "admin_view_inventory" or
       t == "admin_withdraw"   or t == "admin_deposit" then

        local sessR = brgPost("/get_session_uname", msg)
        local uname = sessR and sessR.uname
        if not uname then reply(cid, {ok=false, err="Session error"}, seq); return end
        local isAdmin = sessR and sessR.isAdmin

        if t == "withdraw" then
            local cfg = getCfg(uname)
            if not cfg or not cfg.vault then reply(cid, {ok=false, err="No vault"}, seq); return end
            if not cfg.invmanager then reply(cid, {ok=false, err="No inventory manager"}, seq); return end
            local n = peripheral.call(cfg.invmanager, "addItemToPlayer",
                cfg.vaultDir or "back", {name=msg.name, count=msg.count or 1})
            reply(cid, {ok=(n and n>0), err=(not n or n==0) and "Transfer failed" or nil}, seq)

        elseif t == "deposit" then
            local cfg = getCfg(uname)
            if not cfg or not cfg.vault or not cfg.invmanager then
                reply(cid, {ok=false, err="Account not configured"}, seq); return
            end
            local n = peripheral.call(cfg.invmanager, "removeItemFromPlayer",
                cfg.vaultDir or "back", {name=msg.name, count=msg.count or 1})
            reply(cid, {ok=(n and n>0), err=(not n or n==0) and "Transfer failed" or nil}, seq)

        elseif t == "admin_view_vault" then
            if not isAdmin then reply(cid, {err="Not authorized"}, seq); return end
            local cfg2 = getCfg(msg.username)
            if not cfg2 or not cfg2.vault then reply(cid, {items={}, err="No vault"}, seq); return end
            local items, err = listPeriphItems(cfg2.vault)
            reply(cid, {items=items or {}, err=err}, seq)

        elseif t == "admin_view_inventory" then
            if not isAdmin then reply(cid, {err="Not authorized"}, seq); return end
            local cfg2 = getCfg(msg.username)
            if not cfg2 or not cfg2.invmanager then reply(cid, {items={}, err="No inv manager"}, seq); return end
            local items, err = listPeriphItems(cfg2.invmanager)
            reply(cid, {items=items or {}, err=err}, seq)

        elseif t == "admin_withdraw" then
            if not isAdmin then reply(cid, {ok=false, err="Not authorized"}, seq); return end
            local cfg2 = getCfg(msg.username)
            if not cfg2 or not cfg2.vault or not cfg2.invmanager then
                reply(cid, {ok=false, err="Account not configured"}, seq); return
            end
            local ok2, n = pcall(function()
                return peripheral.call(cfg2.invmanager, "addItemToPlayer",
                    cfg2.vaultDir or "back", {name=msg.name, count=msg.count or 1})
            end)
            reply(cid, {ok=ok2 and n and n>0}, seq)

        elseif t == "admin_deposit" then
            if not isAdmin then reply(cid, {ok=false, err="Not authorized"}, seq); return end
            local cfg2 = getCfg(msg.username)
            if not cfg2 or not cfg2.vault or not cfg2.invmanager then
                reply(cid, {ok=false, err="Account not configured"}, seq); return
            end
            local ok2, n = pcall(function()
                return peripheral.call(cfg2.invmanager, "removeItemFromPlayer",
                    cfg2.vaultDir or "back", {name=msg.name, count=msg.count or 1})
            end)
            reply(cid, {ok=ok2 and n and n>0}, seq)
        end
        return
    end

    -- ── bank_deposit ──────────────────────────────────────────────────────────
    -- FIX: O server já retorna vault/invmanager/vaultDir no response.
    -- Não precisa de getCfg() separado (eliminado 1 roundtrip HTTP).
    -- FIX: source=inventory — conta moedas no invmanager ANTES de tentar mover,
    --      evita travar o invmanager com removeItemFromPlayer de itens inexistentes.
    if t == "bank_deposit" then
        local r = apiPost("/bank_deposit", msg)
        if not r or not r.ok then
            reply(cid, {ok=false, err=(r and r.err) or "Server error"}, seq); return
        end

        -- O server injeta vault/invmanager/vaultDir diretamente no response
        local vault      = r.vault      or (r._cfg and r._cfg.vault)
        local invmanager = r.invmanager or (r._cfg and r._cfg.invmanager)
        local vaultDir   = r.vaultDir   or (r._cfg and r._cfg.vaultDir) or "back"

        -- Fallback: busca config se o server não retornou (compatibilidade)
        if not vault and r._uname then
            local cfg = getCfg(r._uname)
            if cfg then vault = cfg.vault; invmanager = cfg.invmanager; vaultDir = cfg.vaultDir or "back" end
        end

        if not vault then
            reply(cid, {ok=false, err="No vault configured"}, seq); return
        end

        local coins = msg.coins or {}
        local total_sp = 0

        -- Se depositar da inventory: conta o que realmente está lá primeiro
        if msg.source == "inventory" and invmanager and peripheral.isPresent(invmanager) then
            -- Lista o que está no invmanager para não pedir mais do que existe
            local ok2, invItems = pcall(function()
                return peripheral.wrap(invmanager).list()
            end)
            local invCounts = {}
            if ok2 and type(invItems) == "table" then
                for _, it in pairs(invItems) do
                    if it and it.name then
                        invCounts[it.name] = (invCounts[it.name] or 0) + (it.count or 1)
                    end
                end
            end
            for _, d in ipairs(DENOMS) do
                local want = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
                local have = invCounts[d.name] or 0
                local cnt  = math.min(want, have)
                if cnt > 0 then
                    -- Remove do inventário para o vault
                    local ok3, n = pcall(function()
                        return peripheral.call(invmanager, "removeItemFromPlayer",
                            vaultDir, {name=d.name, count=cnt})
                    end)
                    -- Só conta o que realmente saiu
                    coins[d.name] = (ok3 and n and n > 0) and n or 0
                else
                    coins[d.name] = 0
                end
            end
        end

        -- Move do vault do player → bank vault
        for _, d in ipairs(DENOMS) do
            local cnt = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
            if cnt > 0 then
                local actual = moveItem(vault, BANK_VAULT, d.name, cnt)
                total_sp = total_sp + actual * d.value
            end
        end

        local cr = completeBridgeOp(r.bridge_op_id, total_sp > 0, {total_sp=total_sp})
        reply(cid, {
            ok      = total_sp > 0,
            moved   = total_sp,
            balance = (cr and cr.new_balance) or r.balance or 0,
            err     = total_sp == 0 and "No coins moved" or nil,
        }, seq)
        return
    end

    -- ── bank_withdraw ─────────────────────────────────────────────────────────
    -- FIX: Move direto bank_vault → player vault.
    -- Depois tenta addItemToPlayer (vault → inv). Se falhar, item fica no vault — OK.
    -- Não trava o invmanager nem desfaz o saque.
    if t == "bank_withdraw" then
        local r = apiPost("/bank_withdraw", msg)
        if not r or not r.ok then
            reply(cid, {ok=false, err=(r and r.err) or "Server error"}, seq); return
        end

        local vault      = r.vault      or nil
        local invmanager = r.invmanager or nil
        local vaultDir   = r.vaultDir   or "back"

        if not vault and r._uname then
            local cfg = getCfg(r._uname)
            if cfg then vault = cfg.vault; invmanager = cfg.invmanager; vaultDir = cfg.vaultDir or "back" end
        end

        if not vault then
            reply(cid, {ok=false, err="No vault configured"}, seq); return
        end

        local coins    = msg.coins or {}
        local moved_sp = 0

        for _, d in ipairs(DENOMS) do
            local cnt = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
            if cnt > 0 then
                -- 1. Bank vault → player vault
                local actual = moveItem(BANK_VAULT, vault, d.name, cnt)
                if actual > 0 then
                    moved_sp = moved_sp + actual * d.value
                    -- 2. Player vault → player inventory (falha silenciosa — fica no vault)
                    if invmanager then
                        pcall(function()
                            peripheral.call(invmanager, "addItemToPlayer",
                                vaultDir, {name=d.name, count=actual})
                        end)
                    end
                end
            end
        end

        completeBridgeOp(r.bridge_op_id, true, {ok=true, moved=moved_sp})
        reply(cid, {ok=true, moved=moved_sp, balance=r.balance}, seq)
        return
    end

    -- ── market_sell ───────────────────────────────────────────────────────────
    if t == "market_sell" then
        local r = apiPost("/market_sell", msg)
        if not r or not r.ok then
            reply(cid, {ok=false, err=(r and r.err) or "Server error"}, seq); return
        end
        local cfg = r._uname and getCfg(r._uname)
        if not cfg or not cfg.vault then
            reply(cid, {ok=false, err="No vault configured"}, seq); return
        end
        local lot_size   = r.lot_size or msg.lot_size or 1
        local total      = (r.lots or msg.lots or 1) * lot_size
        local moved      = moveToMarket(cfg.vault, r.item_name or msg.item_name, total)
        local actual_lots = math.floor(moved / lot_size)
        local rem = moved - actual_lots * lot_size
        if rem > 0 then moveFromMarket(cfg.vault, r.item_name or msg.item_name, rem) end
        local cr = completeBridgeOp(r.bridge_op_id, actual_lots > 0, {lots=actual_lots})
        reply(cid, {
            ok     = actual_lots > 0,
            lots   = actual_lots,
            stock  = (cr and cr.stock) or actual_lots,
            id     = (cr and cr.id) or msg.listing_id,
            merged = false,
            err    = actual_lots == 0 and "No items moved" or nil,
        }, seq)
        return
    end

    -- ── market_add_stock ──────────────────────────────────────────────────────
    if t == "market_add_stock" then
        local r = apiPost("/market_add_stock", msg)
        if not r or not r.ok then
            reply(cid, {ok=false, err=(r and r.err) or "Server error"}, seq); return
        end
        local cfg = r._uname and getCfg(r._uname)
        if not cfg or not cfg.vault then
            reply(cid, {ok=false, err="No vault configured"}, seq); return
        end
        local lot_size = r.lot_size or 1
        local total    = (r.lots or 1) * lot_size
        local itemName = r.item_name or msg.item_name
        if msg.source == "inventory" then
            if not cfg.invmanager then
                reply(cid, {ok=false, err="No inventory manager configured"}, seq); return
            end
            pcall(function()
                peripheral.call(cfg.invmanager, "removeItemFromPlayer",
                    cfg.vaultDir or "back", {name=itemName, count=total})
            end)
        end
        local moved      = moveToMarket(cfg.vault, itemName, total)
        local actual_lots = math.floor(moved / lot_size)
        local rem = moved - actual_lots * lot_size
        if rem > 0 then moveFromMarket(cfg.vault, itemName, rem) end
        local cr = completeBridgeOp(r.bridge_op_id, actual_lots > 0, {lots=actual_lots})
        reply(cid, {ok=actual_lots>0, added=actual_lots, stock=(cr and cr.stock) or 0,
                    err=actual_lots==0 and "No items moved" or nil}, seq)
        return
    end

    -- ── market_buy ────────────────────────────────────────────────────────────
    if t == "market_buy" then
        local r = apiPost("/market_buy", msg)
        if not r or not r.ok then
            reply(cid, {ok=false, err=(r and r.err) or "Server error"}, seq); return
        end
        local cfg = r._uname and getCfg(r._uname)
        if not cfg or not cfg.vault then
            reply(cid, {ok=false, err="No vault configured"}, seq); return
        end
        local itemName = r.item_name or msg.item_name
        local moved    = moveFromMarket(cfg.vault, itemName, r.count or 1)
        local inInv    = false
        if moved > 0 and cfg.invmanager then
            local ok2, n = pcall(function()
                return peripheral.call(cfg.invmanager, "addItemToPlayer",
                    cfg.vaultDir or "back", {name=itemName, count=moved})
            end)
            inInv = ok2 and n and n > 0
        end
        completeBridgeOp(r.bridge_op_id, true, {ok=true, moved=moved})
        reply(cid, {
            ok          = true,
            item        = r.item,
            count       = r.count,
            price       = r.price,
            tax         = r.tax,
            seller_got  = r.seller_got,
            new_balance = r.balance,
            inVault     = not inInv,
        }, seq)
        return
    end

    -- ── market_cancel ─────────────────────────────────────────────────────────
    if t == "market_cancel" then
        local r = apiPost("/market_cancel", msg)
        if not r or not r.ok then
            reply(cid, {ok=false, err=(r and r.err) or "Server error"}, seq); return
        end
        if r.bridge_op_id then
            local cfg = r._uname and getCfg(r._uname)
            if cfg and cfg.vault then
                local returned = moveFromMarket(cfg.vault, r.item_name, r.count or 0)
                completeBridgeOp(r.bridge_op_id, true, {ok=true, moved=returned})
                reply(cid, {ok=true, returned=returned}, seq)
                return
            end
        end
        reply(cid, {ok=true, returned=r.returned or 0}, seq)
        return
    end

    -- ── auto_food_deliver ─────────────────────────────────────────────────────
    if t == "auto_food_deliver" then
        local sessR = brgPost("/get_session_uname", msg)
        if not sessR or not sessR.uname then
            reply(cid, {ok=false, err="Session error"}, seq); return
        end
        local uname = sessR.uname
        local cfg = getCfg(uname)
        if not cfg or not cfg.vault or not cfg.invmanager then
            reply(cid, {ok=false, err="No vault or inv manager configured"}, seq); return
        end
        local item_name = msg.item or "createfood:breakfast_plate"
        local inv_food = 0
        if peripheral.isPresent(cfg.invmanager) then
            local ok2, inv = pcall(function() return peripheral.wrap(cfg.invmanager).list() end)
            if ok2 and type(inv) == "table" then
                for _, it in pairs(inv) do
                    if it and it.name == item_name then inv_food = inv_food + (it.count or 1) end
                end
            end
        end
        local chk = brgPost("/subscription_food_check", {username=uname, item=item_name, inv_food_count=inv_food})
        if not chk or not chk.deliver then
            reply(cid, {ok=true, delivered=0,
                reason=(chk and chk.reason) or "server_error",
                wait_sec=chk and chk.wait_sec}, seq)
            return
        end
        local to_deliver = chk.amount or 0
        local moved = moveItem(FOOD_VAULT, cfg.vault, item_name, to_deliver)
        local in_inv = 0
        if moved > 0 then
            local ok2, n = pcall(function()
                return peripheral.call(cfg.invmanager, "addItemToPlayer",
                    cfg.vaultDir or "back", {name=item_name, count=moved})
            end)
            if ok2 and type(n) == "number" then in_inv = n end
            local dr = brgPost("/subscription_food_delivered", {username=uname, item=item_name, amount=moved})
            reply(cid, {ok=true, delivered=moved, in_inv=in_inv,
                remaining=(dr and dr.remaining_today) or math.max(0, chk.remaining_today - moved)}, seq)
        else
            reply(cid, {ok=false, err="No food in food vault (vault 63)"}, seq)
        end
        return
    end

    -- Unknown type
    reply(cid, {ok=false, err="Unknown request type: "..(t or "nil")}, seq)
end

-- (main loop replaced by parallel version below)

-- ══════════════════════════════════════════════════════════════════════════════
-- PATCH v3.1 — Non-blocking main loop
-- Substitui o "while true do rednet.receive" acima por versão com parallel.
-- Cada request do tablet vira uma coroutine independente — HTTP lento num
-- request não bloqueia os outros tablets de receber resposta.
-- Também adiciona timeout de 8s em TODOS os HTTP calls para nunca travar.
-- ══════════════════════════════════════════════════════════════════════════════

-- Override das funções HTTP com timeout embutido
local _rawPost = http.post
local function timedPost(url, body, headers, timeoutSec)
    timeoutSec = timeoutSec or 8
    local result = nil
    local done = false
    parallel.waitForAny(
        function()
            local ok, res = pcall(_rawPost, url, body, headers)
            if ok and res then result = res end
            done = true
        end,
        function()
            sleep(timeoutSec)
            done = true
        end
    )
    return result
end

-- Substitui apiPost e brgPost para usar timedPost
function apiPost(path, body)
    local res = timedPost(SERVER_URL..path,
        textutils.serialiseJSON(body or {}), apiHeaders)
    if not res then return nil end
    local d = textutils.unserialiseJSON(res.readAll()); res.close()
    return d
end

function brgPost(path, body)
    local res = timedPost(SERVER_URL..path,
        textutils.serialiseJSON(body or {}), brgHeaders)
    if not res then return nil end
    local d = textutils.unserialiseJSON(res.readAll()); res.close()
    return d
end

function brgGet(path)
    local ok, res = pcall(http.get, SERVER_URL..path, brgHeaders)
    -- GET já tem timeout nativo do CC; wrapping desnecessário
    if not ok or not res then return nil end
    local d = textutils.unserialiseJSON(res.readAll()); res.close()
    return d
end

-- Fila de requests recebidos pelo rednet, processados em paralelo
local queue = {}        -- { cid, msg }
local MAX_WORKERS = 4   -- no máximo 4 requests HTTP simultâneos

-- Per-cid lock: prevents two workers handling the same tablet simultaneously,
-- which would cause interleaved responses and seq desync.
local cidLock     = {}   -- [cid] = true quando worker está processando
local cidQueuedAt = {}   -- [cid+seq] = os.clock() quando entrou na fila

local function workerLoop()
    while true do
        if #queue > 0 then
            local item, itemIdx = nil, nil
            for i, q in ipairs(queue) do
                if not cidLock[q.cid] then
                    item = q; itemIdx = i; break
                end
            end

            if item then
                table.remove(queue, itemIdx)
                local qkey = tostring(item.cid)..":"..tostring(item.msg._seq or 0)
                cidQueuedAt[qkey] = nil
                cidLock[item.cid] = true
                monEmit({type="op_start", cid=item.cid, queue_size=#queue, op_type=item.msg.type or "?"})
                local ok, err = pcall(handle, item.cid, item.msg)
                cidLock[item.cid] = nil
                local uname = type(item.msg)=="table" and item.msg._uname or nil
                monEmit({type="op_done", cid=item.cid, queue_size=#queue,
                         op_type=item.msg.type or "?", uname=uname, ok=ok})
                if not ok then
                    print("[WORKER] Erro em "..tostring(item.msg.type)..": "..tostring(err))
                    monLog("err", "Worker: "..tostring(item.msg.type).." — "..tostring(err))
                    rednet.send(item.cid, {ok=false, err="Internal error", _seq=item.msg._seq}, PROTOCOL)
                end
            else
                -- Todos os items na fila estão bloqueados pelo cidLock.
                -- Verifica se algum esperou demais (>4s) — manda busy e remove.
                local now = os.clock()
                local i = 1
                while i <= #queue do
                    local q = queue[i]
                    local qkey = tostring(q.cid)..":"..tostring(q.msg._seq or 0)
                    if not cidQueuedAt[qkey] then
                        cidQueuedAt[qkey] = now
                    elseif now - cidQueuedAt[qkey] > 4 then
                        table.remove(queue, i)
                        cidQueuedAt[qkey] = nil
                        rednet.send(q.cid, {ok=false, err="Bridge busy", _seq=q.msg._seq}, PROTOCOL)
                        monLog("warn", "Dropped stale queued op for cid "..tostring(q.cid))
                    else
                        i = i + 1
                    end
                end
                sleep(0.05)
            end
        else
            sleep(0.05)
        end
    end
end

-- Per-cid flood control: max 3 pending items per tablet
local function receiveLoop()
    while true do
        local cid, msg = rednet.receive(PROTOCOL, 30)
        if type(msg) == "table" then
            -- Count pending items for this cid
            local cidCount = 0
            for _, q in ipairs(queue) do
                if q.cid == cid then cidCount = cidCount + 1 end
            end
            if cidCount >= 3 then
                -- Tablet is spamming — drop with busy signal
                -- Only send busy if this is a newer seq than what's queued
                rednet.send(cid, {ok=false, err="Bridge busy", _seq=msg._seq}, PROTOCOL)
            elseif #queue < 32 then
                table.insert(queue, {cid=cid, msg=msg})
                monEmit({type="queue_update", size=#queue})
                -- Register queue entry time for stale detection
                local _qkey = tostring(cid)..":"..tostring(msg._seq or 0)
                cidQueuedAt[_qkey] = os.clock()
            else
                print("[BRIDGE] Fila global cheia, descartando de "..tostring(cid))
                monLog("warn", "Queue full, dropped from "..tostring(cid))
                rednet.send(cid, {ok=false, err="Bridge busy", _seq=msg._seq}, PROTOCOL)
            end
        end
    end
end

-- Periodic: busca bridge_ops pendentes + verifica se URL mudou
local _pingCounter = 0
local function pendingLoop()
    while true do
        sleep(15) -- a cada 15s
        _pingCounter = _pingCounter + 1

        -- Verifica URL a cada 60s (4 × 15s)
        if _pingCounter % 4 == 0 then
            local oldUrl = SERVER_URL
            loadServerUrl()
            if SERVER_URL ~= oldUrl and SERVER_URL ~= "" then
                print("[URL] Tunnel mudou: "..SERVER_URL)
                monLog("warn", "Tunnel URL atualizada: "..SERVER_URL)
                monEmit({type="init", version="v3.1", server_url=SERVER_URL,
                         peripherals=_periph_list or {}})
            end

            -- Ping com a URL atual
            local pr = brgGet("/bridge/pending")
            local pingOk = pr ~= nil
            monEmit({type="server_ping", ok=pingOk})
            if not pingOk then
                monLog("warn", "Server não respondeu — tentando URL do GitHub...")
                -- Força refresh da URL mesmo fora do ciclo normal
                local prevUrl = SERVER_URL
                loadServerUrl()
                if SERVER_URL ~= prevUrl then
                    print("[URL] Reconectando para "..SERVER_URL)
                    monLog("ok", "Reconectado: "..SERVER_URL)
                end
            end
        end
        local r = brgGet("/bridge/pending")
        if r and r.ok and r.ops and #r.ops > 0 then
            print("[PENDING] "..#r.ops.." op(s) para reprocessar")
            monLog("warn", "Recovered "..#r.ops.." stale op(s)")
            for _, op in ipairs(r.ops) do
                local payload = textutils.unserialiseJSON(op.payload or "{}")
                payload._pending_op_id = op.id
                payload.type = op.type
                if #queue < 32 then
                    table.insert(queue, {cid=0, msg=payload})
                end
            end
        end
    end
end

-- Inicia tudo em paralelo

print("Bridge v3.1 — parallel mode")
print("Server: "..SERVER_URL)
local _periph_names = peripheral.getNames()
print("Periféricos: "..table.concat(_periph_names, ", "))

-- Build peripheral list for monitor
local _periph_list = {}
local _KNOWN_ROLES = {
    [BANK_VAULT]="bank_vault",
}
for _, mv in ipairs(MARKET_VAULTS) do _KNOWN_ROLES[mv]="market_vault" end
_KNOWN_ROLES[FOOD_VAULT] = "food_vault"
for _, pname in ipairs(_periph_names) do
    table.insert(_periph_list, {
        name  = pname,
        ptype = peripheral.getType(pname) or "?",
        role  = _KNOWN_ROLES[pname],
    })
end
monEmit({
    type         = "init",
    version      = "v3.1",
    server_url   = SERVER_URL,
    peripherals  = _periph_list,
})

-- Monta lista de coroutines: receive + pending + N workers
local tasks = {receiveLoop, pendingLoop}
for i = 1, MAX_WORKERS do
    table.insert(tasks, workerLoop)
end

parallel.waitForAll(table.unpack(tasks))
