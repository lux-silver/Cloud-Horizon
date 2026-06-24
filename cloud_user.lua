-- Cloud User v6
local PROTOCOL = "cloud_ui"
-- API_URL é dinâmica — buscada do GitHub no boot e refreshada a cada 5min
local URL_SRC    = "https://raw.githubusercontent.com/Oorange2/cc-player-radar/main/tunnel_url.txt"
local URL_CACHE  = "/.cloud_api_url"
local API_URL    = ""

local function loadApiUrl()
    -- 1. Tenta GitHub
    local ok, res = pcall(http.get, URL_SRC)
    if ok and res then
        local u = res.readAll():gsub("%s+",""); res.close()
        if u and #u > 10 then
            API_URL = u
            local f = fs.open(URL_CACHE,"w"); f.write(u); f.close()
            return true
        end
    end
    -- 2. Cache local
    if fs.exists(URL_CACHE) then
        local f = fs.open(URL_CACHE,"r")
        local u = f.readAll():gsub("%s+",""); f.close()
        if u and #u > 10 then API_URL = u; return true end
    end
    return false
end

-- Carrega no boot (antes de qualquer HTTP)
loadApiUrl()

local modemSide = nil
for _, s in ipairs({"top","bottom","left","right","front","back"}) do
    if peripheral.getType(s) == "modem" then modemSide = s break end
end
if modemSide then rednet.open(modemSide) end

local W, H     = term.getSize()
pcall(term.setPaletteColor, colors.orange, 0xCC6600)

local DENOMS = {
    {name="numismatics:sun",      label="Sun",      value=4096},
    {name="numismatics:crown",    label="Crown",    value=512},
    {name="numismatics:cog",      label="Cog",      value=64},
    {name="numismatics:sprocket", label="Sprocket", value=16},
    {name="numismatics:bevel",    label="Bevel",    value=8},
    {name="numismatics:spur",     label="Spur",     value=1},
}

local serverId     = nil
local token        = nil
local username     = nil
local isAdmin      = false
local unreadNotifs = 0
local needsRelogin = false

local foodSubCache   = nil
local foodSubCacheTs = 0

local iconColors = {
    colors.orange, colors.magenta, colors.lightBlue, colors.yellow,
    colors.lime, colors.pink, colors.cyan, colors.purple,
    colors.blue, colors.brown, colors.green, colors.red,
}
local function itemColor(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + string.byte(name, i)) % #iconColors end
    return iconColors[h + 1]
end

-- Prettify item IDs when displayName wasn't fetched (e.g. "minecraft:bone_meal" → "Bone Meal")
local function prettyName(item)
    local dn = item.displayName or item.name or "?"
    -- If displayName looks like a raw ID (contains ":" and no spaces), prettify it
    if dn:find(":") and not dn:find(" ") then
        local plain = dn:match(":(.+)$") or dn
        plain = plain:gsub("_", " ")
        plain = plain:gsub("(%a)([%w_']*)", function(a,b) return a:upper()..b end)
        return plain
    end
    return dn
end

local rpcSeq    = 0
local rpcBusy   = false   -- serial lock: only one bridgeRpc at a time
local rpcBuf    = {}      -- [seq] = response buffered while waiting for another seq

local function bridgeRpc(msg, timeout)
    if not modemSide then return {ok=false, err="No modem"} end

    -- Serial gate: se já tem um request em andamento, espera até 2s antes de prosseguir
    -- Isso evita que spam mande seq=N+1 antes de seq=N ser respondido
    local gateDeadline = os.clock() + 2
    while rpcBusy and os.clock() < gateDeadline do
        sleep(0.05)
    end
    rpcBusy = true

    rpcSeq = rpcSeq + 1
    local mySeq = rpcSeq
    msg._seq = mySeq

    -- Limpa respostas antigas do buffer
    for k in pairs(rpcBuf) do
        if k < mySeq then rpcBuf[k] = nil end
    end

    -- Já tem no buffer (chegou fora de ordem antes)?
    if rpcBuf[mySeq] then
        local r = rpcBuf[mySeq]
        rpcBuf[mySeq] = nil
        rpcBusy = false
        return r
    end

    if serverId then rednet.send(serverId, msg, PROTOCOL)
    else rednet.broadcast(msg, PROTOCOL) end

    local deadline = os.clock() + (timeout or 5)
    while true do
        local remaining = deadline - os.clock()
        if remaining <= 0 then
            rpcBusy = false
            return nil
        end
        local id, res = rednet.receive(PROTOCOL, remaining)
        if not res then
            rpcBusy = false
            return nil
        end
        if id then serverId = id end
        if type(res) ~= "table" then -- ignorar não-tabelas
        elseif res._seq == nil then  -- resposta sem seq (protocolo antigo) — aceita
            rpcBusy = false
            return res
        elseif res._seq == mySeq then
            rpcBusy = false
            -- Bridge busy: espera 0.3s e tenta de novo (não dessincroniza)
            if res.err == "Bridge busy" then
                sleep(0.3)
                rpcBusy = true
                if serverId then rednet.send(serverId, msg, PROTOCOL)
                else rednet.broadcast(msg, PROTOCOL) end
                deadline = os.clock() + (timeout or 5)
            else
                if res.err == "Session expired" then needsRelogin = true end
                return res
            end
        elseif res._seq > mySeq then
            rpcBuf[res._seq] = res  -- guarda para o próximo bridgeRpc
        end
        -- res._seq < mySeq: resposta velha, descarta
    end
end

-- Pure-data ops that can skip the bridge and go direct to the API
local HTTP_OPS = {
    login=true, get_log=true, bank_info=true,
    bank_get_loan=true, bank_pay_loan=true, bank_get_log=true, bank_transfer=true,
    get_notif_count=true, get_notifications=true,
    market_list=true, market_public_list=true, market_my_listings=true,
    market_create_listing=true, market_edit_listing=true, market_boost_listing=true,
    coinflip_create=true, coinflip_list=true, coinflip_join=true,
    coinflip_cancel=true, coinflip_my_bets=true,
    slots_spin=true, mines_start=true, mines_reveal=true, mines_cashout=true,
    get_leaderboard=true,
    admin_list_users=true, admin_create_user=true, admin_delete_user=true,
    subscription_status=true, subscription_create=true, subscription_cancel=true,
    subscription_food_items=true,
}

-- ── HTTP com retry e timeout explícito ───────────────────────────────────────
-- Tenta até MAX_RETRIES vezes com intervalo crescente antes de desistir.
-- Retorna nil SOMENTE se todas as tentativas falharam (túnel caído de verdade).
local HTTP_TIMEOUT  = 8   -- segundos por tentativa
local MAX_RETRIES   = 3   -- quantas vezes tenta antes de devolver nil
local RETRY_DELAY   = 1.5 -- segundos entre tentativas

local function httpPost(path, bodyTable, headers)
    local bodyJson = textutils.serialiseJSON(bodyTable)
    local hdrs = headers or { ["Content-Type"] = "application/json" }
    for attempt = 1, MAX_RETRIES do
        local ok, resp = pcall(http.post, API_URL..path, bodyJson, hdrs)
        if ok and resp then
            local raw = resp.readAll(); resp.close()
            local data = textutils.unserialiseJSON(raw)
            return data  -- sucesso — pode ser nil se JSON inválido, mas não é erro de rede
        end
        -- Falha de rede: espera um pouco e tenta de novo (exceto na última tentativa)
        if attempt < MAX_RETRIES then sleep(RETRY_DELAY) end
    end
    return nil  -- todas as tentativas falharam
end

local function httpRpc(msg)
    local body = {}
    for k, v in pairs(msg) do
        if k ~= "type" and k ~= "_seq" then body[k] = v end
    end
    local data = httpPost("/"..msg.type, body)
    if data and data.err == "Session expired" then needsRelogin = true end
    return data
end

local function rpc(msg, timeout)
    if HTTP_OPS[msg.type] then return httpRpc(msg) end
    return bridgeRpc(msg, timeout)
end

-- ── Persistência de sessão ────────────────────────────────────────────────────
local SESSION_FILE = "/.cloud_session"

local function saveSession(tok, uname, admin)
    local f = fs.open(SESSION_FILE, "w")
    if f then
        f.write(textutils.serialiseJSON({token=tok, username=uname, isAdmin=admin}))
        f.close()
    end
end

local function clearSession()
    if fs.exists(SESSION_FILE) then fs.delete(SESSION_FILE) end
end

-- Tenta restaurar a sessão salva em disco.
-- IMPORTANTE: se o servidor não responder (túnel caído), NÃO limpa a sessão —
-- assume que o token ainda é válido e deixa o usuário entrar offline.
-- Só limpa a sessão se o servidor responder explicitamente com ok=false.
local function tryRestoreSession()
    if not fs.exists(SESSION_FILE) then return false end
    local f = fs.open(SESSION_FILE, "r")
    if not f then return false end
    local raw = f.readAll(); f.close()
    local data = textutils.unserialiseJSON(raw)
    if not data or not data.token then return false end

    -- Tenta validar o token no servidor
    local res = httpPost("/session_check", {token=data.token})

    if res == nil then
        -- Servidor não respondeu (túnel caído, rede instável) —
        -- restaura a sessão localmente sem validar para não perder acesso
        token    = data.token
        username = data.username
        isAdmin  = data.isAdmin or false
        return true   -- entra "otimisticamente" — se o token expirou, needsRelogin vai pegar depois
    end

    if res.ok then
        token    = data.token
        username = data.username or res.username
        isAdmin  = data.isAdmin or res.isAdmin or false
        return true
    end

    -- Servidor respondeu e disse que o token é inválido — aí sim limpa
    clearSession()
    return false
end

-- Login
local function doLogin()
    while true do
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine() term.write(" Cloud Storage")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
        term.setCursorPos(1,3) term.write("Username: ")
        local uname = read()
        term.setCursorPos(1,4) term.write("Password: ")
        local pass = read("*")
        -- Mostra "Conectando..." enquanto tenta
        term.setCursorPos(1,6) term.setTextColor(colors.gray) term.write("Connecting...")
        local res = rpc({ type="login", username=uname, password=pass })
        term.setCursorPos(1,6) term.setBackgroundColor(colors.black) term.write(string.rep(" ", W))
        if res and res.ok then
            token=res.token username=uname isAdmin=res.isAdmin or false
            unreadNotifs = res.unread_notifs or 0
            saveSession(token, username, isAdmin)
            local subR = httpRpc({type="subscription_status", token=res.token})
            if subR and subR.ok then foodSubCache=subR; foodSubCacheTs=os.epoch("utc") end
            return
        else
            term.setCursorPos(1,6) term.setTextColor(colors.red)
            if res == nil then
                term.write("Server unreachable (tunnel down?)")
            else
                term.write(res.err or "Login failed")
            end
            term.setCursorPos(1,7) term.setTextColor(colors.gray) term.write("Press any key to retry...")
            os.pullEvent()
        end
    end
end

-- Item list UI (click-based)
local function itemListUI(cfg)
    local items       = {}
    local filtered    = {}
    local scroll      = 0
    local selIdx      = nil
    local selAmt      = {}
    local searchMode  = false
    local searchQuery = ""
    local message     = ""
    local msgTimer    = 0
    local fetchErr    = nil
    local shiftHeld   = false

    local LIST_TOP = 2
    local function listBot()  return H - 3 end
    local function listRows() return listBot() - LIST_TOP + 1 end

    local function doFetch()
        local res = cfg.fetchFn()
        items    = (res and res.items) or {}
        fetchErr = res and res.err
    end

    local function applyFilter()
        if searchQuery == "" then
            filtered = items
        else
            local q = searchQuery:lower()
            filtered = {}
            for _, item in ipairs(items) do
                if prettyName(item):lower():find(q, 1, true) then
                    table.insert(filtered, item)
                end
            end
        end
        scroll = 0
        selIdx = nil
    end

    doFetch()
    applyFilter()

    local function getAmt(item)
        return selAmt[item.name] or 1
    end

    local function draw()
        W, H = term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1, 1) term.clearLine()
        if searchMode then
            term.write(" /" .. searchQuery .. "_")
        else
            local hdr = " " .. cfg.title .. " [" .. #filtered .. "]"
            if #hdr > W - 3 then hdr = hdr:sub(1, W - 3) end
            term.write(hdr .. string.rep(" ", math.max(0, W - #hdr - 3)) .. "[X]")
        end
        if fetchErr and #filtered == 0 then
            term.setCursorPos(1, LIST_TOP)
            term.setBackgroundColor(colors.black) term.setTextColor(colors.red)
            term.write(fetchErr:sub(1, W))
        else
            for row = 1, listRows() do
                local idx  = row + scroll
                local item = filtered[idx]
                local sr   = LIST_TOP + row - 1
                term.setCursorPos(1, sr)
                if item then
                    local isSel = (idx == selIdx)
                    local amt   = getAmt(item)
                    term.setBackgroundColor(itemColor(item.name)) term.setTextColor(colors.black) term.write(" ")
                    if isSel then
                        local qStr = ">" .. amt .. "/" .. item.count .. "<"
                        local lbl  = prettyName(item):sub(1, W - 2 - #qStr)
                        term.setBackgroundColor(colors.gray) term.setTextColor(colors.yellow)
                        term.write(" " .. lbl)
                        term.setTextColor(colors.lime)
                        term.write(string.rep(" ", math.max(0, W - 2 - #lbl - #qStr)) .. qStr)
                    else
                        local cs  = "x" .. item.count
                        local lbl = prettyName(item):sub(1, W - 3 - #cs)
                        term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
                        term.write(" " .. lbl)
                        term.setTextColor(colors.cyan)
                        term.write(string.rep(" ", math.max(0, W - 3 - #lbl - #cs)) .. cs)
                    end
                else
                    term.setBackgroundColor(colors.black) term.write(string.rep(" ", W))
                end
            end
        end
        if scroll > 0 then
            term.setCursorPos(W, LIST_TOP)
            term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^")
        end
        if scroll + listRows() < #filtered then
            term.setCursorPos(W, listBot())
            term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v")
        end
        local bRow = H - 2
        term.setCursorPos(1, bRow) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write(" / Search ")
        term.setBackgroundColor(colors.black) term.write(" ")
        term.setBackgroundColor(colors.gray)  term.write(" R Refresh ")
        term.setBackgroundColor(colors.black) term.write(" ")
        term.setBackgroundColor(colors.orange)  term.write(" < Back ")
        term.setCursorPos(1, H - 1) term.setBackgroundColor(colors.black)
        if message ~= "" and os.clock() < msgTimer then
            term.setTextColor(colors.lime) term.write(message:sub(1, W))
        else
            message = ""
            if selIdx and cfg.actionFn then
                local item = filtered[selIdx]
                if item then
                    term.setTextColor(colors.yellow)
                    term.write(("Click again to confirm (" .. prettyName(item) .. ")"):sub(1, W))
                end
            else
                term.setTextColor(colors.gray) term.write("RClick=full stack  Q=back")
            end
        end
        term.setCursorPos(1, H) term.setBackgroundColor(colors.black) term.write(string.rep(" ", W))
    end

    local function rowToIdx(my)
        if my < LIST_TOP or my > listBot() then return nil end
        local idx = (my - LIST_TOP) + 1 + scroll
        return (idx >= 1 and idx <= #filtered) and idx or nil
    end

    local function hitBtnBar(mx, my)
        if my ~= H - 2 then return nil end
        if mx >= 1  and mx <= 10 then return "search"  end
        if mx >= 12 and mx <= 22 then return "refresh" end
        if mx >= 24 and mx <= 31 then return "back"    end
        return nil
    end

    local function doAction(item)
        if not cfg.actionFn then return end
        local amt = math.min(getAmt(item), item.count)
        local ok, err = cfg.actionFn(item, amt)
        if ok then
            message  = (cfg.actionLabel or "Done") .. " x" .. amt .. ": " .. prettyName(item)
            msgTimer = os.clock() + 3
            selIdx   = nil
            doFetch() applyFilter()
        else
            message  = err or "Failed"
            msgTimer = os.clock() + 3
        end
    end

    while true do
        draw()
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "term_resize" then W, H = term.getSize() shiftHeld = false
        elseif searchMode then
            if ev == "char" then searchQuery = searchQuery .. p1 applyFilter()
            elseif ev == "key" then
                if p1 == keys.backspace then
                    if searchQuery == "" then searchMode = false
                    else searchQuery = searchQuery:sub(1, -2) applyFilter() end
                elseif p1 == keys.enter then searchMode = false end
            elseif ev == "mouse_click" then searchMode = false end
        else
            if ev == "mouse_click" then
                local mx, my = p2, p3
                if my == 1 and mx >= W - 2 then return end
                local idx = rowToIdx(my)
                if idx then
                    local item = filtered[idx]
                    if p1 == 2 then
                        -- right click: instant full stack
                        selAmt[item.name] = math.min(64, item.count)
                        selIdx = idx
                        doAction(item)
                    elseif idx == selIdx then doAction(item)
                    else
                        selIdx = idx
                        if not selAmt[item.name] then selAmt[item.name] = 1 end
                    end
                else selIdx = nil end
                local btn = hitBtnBar(mx, my)
                if btn == "search" then searchMode = true searchQuery = "" applyFilter()
                elseif btn == "refresh" then doFetch() applyFilter() message = "Refreshed" msgTimer = os.clock() + 1
                elseif btn == "back" then return end
            elseif ev == "mouse_scroll" then
                local dir, mx, my = p1, p2, p3
                local idx = rowToIdx(my)
                if idx and idx == selIdx then
                    local item = filtered[idx]
                    local cur  = selAmt[item.name] or 1
                    selAmt[item.name] = math.max(1, math.min(cur - dir, item.count))
                else
                    scroll = math.max(0, math.min(scroll + dir, math.max(0, #filtered - listRows())))
                end
            elseif ev == "key" then
                if p1 == keys.q then
                    if selIdx then selIdx = nil else return end
                elseif p1 == keys.r then doFetch() applyFilter() message = "Refreshed" msgTimer = os.clock() + 1
                elseif p1 == keys.slash then searchMode = true searchQuery = "" applyFilter() end
            elseif ev == "key_up" then
                if p1 == keys.leftShift or p1 == keys.rightShift then shiftHeld = false end
            end
        end
    end
end

-- Log screen (click-based)
local function logScreen()
    local res = rpc({ type="get_log", token=token })
    local log = (res and res.log) or {}
    local scroll = 0
    while true do
        W, H = term.getSize()
        local listH = H - 3
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1, 1) term.clearLine()
        local hdr = " Activity Log [" .. #log .. "]"
        term.write(hdr .. string.rep(" ", math.max(0, W - #hdr - 3)) .. "[X]")
        for row = 1, listH do
            local idx = #log - scroll - row + 1
            term.setCursorPos(1, row + 1) term.setBackgroundColor(colors.black)
            if log[idx] then
                term.setTextColor(colors.white) term.write((log[idx].event or ""):sub(1, W))
            else
                term.setTextColor(colors.black) term.write(string.rep(" ", W))
            end
        end
        if scroll > 0 then
            term.setCursorPos(W, 2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^")
        end
        if scroll + listH < #log then
            term.setCursorPos(W, H - 2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v")
        end
        term.setCursorPos(1, H - 1) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white) term.write(" < Back ")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.gray) term.write("  Q=back")
        term.setCursorPos(1, H) term.setBackgroundColor(colors.black) term.write(string.rep(" ", W))
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "term_resize" then W, H = term.getSize() shiftHeld = false
        elseif ev == "mouse_click" then
            local mx, my = p2, p3
            if (my == 1 and mx >= W - 2) or (my == H - 1 and mx <= 8) then return end
        elseif ev == "mouse_scroll" then
            scroll = math.max(0, math.min(scroll + p1, math.max(0, #log - listH)))
        elseif ev == "key" then
            if p1 == keys.q then return
            elseif p1 == keys.up   then scroll = math.max(0, scroll - 1)
            elseif p1 == keys.down then scroll = math.min(math.max(0, #log - listH), scroll + 1) end
        end
    end
end

-- Shared clickable menu helper
-- items may include flash=true to pulse the row's icon color
-- refreshSecs: if set, menu returns "__refresh__" after that many seconds so caller can re-poll
local function clickMenu(title, items, msg, refreshSecs)
    local message = msg or ""
    local msgTimer = 0
    local flashOn = true
    local flashTimer = nil
    local refreshTimer = refreshSecs and os.startTimer(refreshSecs) or nil
    for _, opt in ipairs(items) do
        if opt.flash then flashTimer = os.startTimer(0.5) break end
    end
    while true do
        W, H = term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1, 1) term.clearLine()
        local hdr = " " .. title
        if #hdr > W - 3 then hdr = hdr:sub(1, W - 3) end
        term.write(hdr .. string.rep(" ", math.max(0, W - #hdr - 3)) .. "[X]")
        for i, opt in ipairs(items) do
            term.setCursorPos(1, i + 2)
            local lit = opt.flash and flashOn
            term.setBackgroundColor(lit and colors.red or (opt.icon or colors.gray))
            term.setTextColor(colors.black) term.write(" ")
            term.setBackgroundColor(colors.black)
            term.setTextColor(lit and colors.red or colors.white)
            term.write(" " .. opt.label .. string.rep(" ", math.max(0, W - #opt.label - 2)))
        end
        term.setCursorPos(1, H) term.setBackgroundColor(colors.black)
        if message ~= "" and os.clock() < msgTimer then
            term.setTextColor(colors.lime) term.write(message:sub(1, W))
        else
            message = ""
            term.setTextColor(colors.gray) term.write("Click to select  Q=back")
        end
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "term_resize" then W, H = term.getSize() shiftHeld = false
        elseif ev == "timer" then
            if p1 == flashTimer then
                flashOn = not flashOn
                flashTimer = os.startTimer(0.5)
            elseif p1 == refreshTimer then
                return "__refresh__"
            end
        elseif ev == "mouse_click" then
            local mx, my = p2, p3
            if my == 1 and mx >= W - 2 then return nil end
            local idx = my - 2
            if idx >= 1 and idx <= #items then return idx end
        elseif ev == "key" then
            if p1 == keys.q then return nil end
        end
    end
end


-- ── Banking UI ───────────────────────────────────────────────────────────────
local function creditColor(s)
    s = s or 0
    if s >= 700 then return colors.lime
    elseif s >= 500 then return colors.yellow
    elseif s >= 300 then return colors.orange
    else return colors.red end
end
local function creditLabel(s)
    s = s or 0
    if s >= 800 then return "Excellent"
    elseif s >= 700 then return "Very Good"
    elseif s >= 600 then return "Good"
    elseif s >= 500 then return "Fair"
    elseif s >= 400 then return "Poor"
    elseif s >= 300 then return "Very Poor"
    else return "Critical" end
end

local function amountPicker(cfg)
    local minA = cfg.min or 1
    local maxA = math.min(cfg.max or cfg.available, cfg.available)
    if maxA < minA then return nil end
    local amount = minA
    local unit = cfg.unit or "sp"
    local msg2 = "" local mt2 = 0
    while true do
        W, H = term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(cfg.headerColor or colors.blue) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        local hdr = " " .. cfg.title
        if #hdr > W-3 then hdr = hdr:sub(1,W-3) end
        term.write(hdr .. string.rep(" ", math.max(0,W-#hdr-3)) .. "[X]")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
        local avLabel = cfg.availableLabel or ("Available: " .. cfg.available .. " " .. unit)
        term.setCursorPos(2,3) term.write(avLabel:sub(1,W-2))
        if cfg.hint then
            term.setCursorPos(2,4) term.setTextColor(colors.lightBlue) term.write(cfg.hint:sub(1,W-2))
        end
        -- Amount display
        local amtStr = tostring(amount) .. " " .. unit
        term.setCursorPos(math.max(1, math.floor((W-#amtStr)/2)+1), 6)
        term.setTextColor(colors.yellow) term.write(amtStr)
        -- Progress bar
        if maxA > minA then
            local bw = W-4
            local fill = math.floor((amount-minA)/(maxA-minA)*bw)
            term.setCursorPos(3,8)
            term.setBackgroundColor(colors.green) term.write(string.rep(" ",fill))
            term.setBackgroundColor(colors.gray) term.write(string.rep(" ",bw-fill))
            term.setBackgroundColor(colors.black)
        end
        term.setCursorPos(2,7) term.setTextColor(colors.gray)
        term.write("scroll / arrows to adjust")
        -- Status
        if msg2 ~= "" and os.clock() < mt2 then
            term.setCursorPos(1,10) term.setTextColor(colors.red) term.write(msg2:sub(1,W))
        end
        -- Buttons
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.green) term.setTextColor(colors.white) term.write(" Confirm ")
        term.setBackgroundColor(colors.black) term.write("  ")
        term.setBackgroundColor(colors.red) term.write(" Cancel ")
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3 = os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return nil end
            if my==H-1 then
                if mx>=1 and mx<=9 then
                    if amount < minA or amount > maxA then
                        msg2="Invalid amount" mt2=os.clock()+2
                    else return amount end
                elseif mx>=12 and mx<=19 then return nil end
            end
        elseif ev=="mouse_scroll" then
            amount=math.max(minA,math.min(maxA,amount-p1))
        elseif ev=="key" then
            if p1==keys.q then return nil
            elseif p1==keys.enter then return amount
            elseif p1==keys.up or p1==keys.right then amount=math.min(maxA,amount+1)
            elseif p1==keys.down or p1==keys.left then amount=math.max(minA,amount-1)
            end
        end
    end
end

-- Multi-denomination coin picker
-- cfg: { title, coins[{name,label,value,available}], target(sp, optional),
--        confirmLabel, preset({[name]=count}, optional) }
-- Returns {[name]=count} or nil
local function coinPickerUI(cfg)
    if #cfg.coins == 0 then return nil end
    local counts = {}
    for _, c in ipairs(cfg.coins) do
        counts[c.name] = (cfg.preset and cfg.preset[c.name]) or 0
    end
    local LIST_TOP = 3

    local function totalSp()
        local t = 0
        for _, c in ipairs(cfg.coins) do t = t + (counts[c.name] or 0) * c.value end
        return t
    end

    -- Effective max for a coin: capped by both bank stock and remaining target budget
    local function effMax(c)
        if cfg.target then
            local otherSp = totalSp() - (counts[c.name] or 0) * c.value
            return math.min(c.available, math.floor(math.max(0, cfg.target - otherSp) / c.value))
        end
        return c.available
    end

    while true do
        W, H = term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        -- Header
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        local hdr = " "..cfg.title
        if #hdr > W-3 then hdr = hdr:sub(1,W-3) end
        term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
        -- Auto-clamp counts to effective max (fixes counts made invalid by other row changes)
        for _, c in ipairs(cfg.coins) do
            local em = effMax(c)
            if (counts[c.name] or 0) > em then counts[c.name] = em end
        end
        -- Total line
        term.setBackgroundColor(colors.black)
        term.setCursorPos(1,2) term.clearLine()
        local sp = totalSp()
        if cfg.target then
            local diff = cfg.target - sp
            term.setTextColor(colors.gray) term.write(" "..sp.."/"..cfg.target.."sp ")
            if diff == 0 then
                term.setTextColor(colors.lime) term.write("OK!")
            elseif diff > 0 then
                term.setTextColor(colors.orange) term.write("need "..diff.."sp")
            else
                term.setTextColor(colors.red) term.write("over "..(-diff).."sp!")
            end
        else
            term.setTextColor(colors.gray) term.write(" Total: ")
            term.setTextColor(colors.yellow) term.write(sp.." sp")
        end
        -- Coin rows
        for i, c in ipairs(cfg.coins) do
            local y = LIST_TOP + i - 1
            if y >= H-1 then break end
            term.setCursorPos(1,y) term.setBackgroundColor(colors.black) term.clearLine()
            local cnt  = counts[c.name] or 0
            local em   = effMax(c)
            -- right side: "cnt/em" — uses effective max so it always reflects reality
            local rightStr = tostring(cnt).."/"..tostring(em)
            local leftStr  = c.label.." "..c.value.."sp"
            -- fit left text into available width, always leave room for right side
            local leftW = math.max(4, W - 2 - #rightStr - 1)
            local gap   = math.max(1, W - 2 - math.min(#leftStr, leftW) - #rightStr)
            term.setBackgroundColor(itemColor(c.name)) term.write(" ") term.setBackgroundColor(colors.black) term.write(" ")
            term.setTextColor(cnt > 0 and colors.white or colors.gray)
            term.write(leftStr:sub(1, leftW))
            term.setTextColor(colors.gray) term.write(string.rep(" ", gap))
            term.setTextColor(cnt > 0 and colors.yellow or colors.gray) term.write(rightStr)
        end
        -- Hint
        local hintY = LIST_TOP + #cfg.coins
        if hintY < H-1 then
            term.setCursorPos(1,hintY) term.setBackgroundColor(colors.black)
            term.setTextColor(colors.gray) term.write(" scroll a row to adjust")
        end
        -- Buttons
        local canConfirm = (not cfg.target and totalSp()>0) or (cfg.target and totalSp()==cfg.target)
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
        local confirmLbl = " "..(cfg.confirmLabel or "Confirm").." "
        if canConfirm then
            term.setBackgroundColor(colors.white) term.setTextColor(colors.black)
        else
            term.setBackgroundColor(colors.gray) term.setTextColor(colors.lightGray)
        end
        term.write(confirmLbl)
        term.setBackgroundColor(colors.black) term.write("  ")
        term.setBackgroundColor(colors.red) term.setTextColor(colors.white) term.write(" Cancel ")
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))

        local ev,p1,p2,p3 = os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my = p2,p3
            if my==1 and mx>=W-2 then return nil end
            if my==H-1 then
                if canConfirm and mx>=1 and mx<=#confirmLbl then return counts end
                if mx>=#confirmLbl+3 then return nil end
            end
        elseif ev=="mouse_scroll" then
            local dir,mx,my = p1,p2,p3
            local row = my - LIST_TOP + 1
            if row>=1 and row<=#cfg.coins then
                local c = cfg.coins[row]
                counts[c.name] = math.max(0, math.min(effMax(c), (counts[c.name] or 0) - dir))
            end
        elseif ev=="key" then
            if p1==keys.q then return nil
            elseif p1==keys.enter and canConfirm then return counts end
        end
    end
end

local function bankBlog()
    local res = rpc({type="bank_get_log", token=token})
    local log = (res and res.log) or {}
    local scroll = 0
    local function buildLines()
        local lines={}
        for _,e in ipairs(log) do
            local ev=e.event or ""
            -- First line: up to W-1 chars
            table.insert(lines,{text=ev:sub(1,W-1),color=colors.white})
            -- Overflow onto second line if needed
            if #ev>=W then
                table.insert(lines,{text="  "..ev:sub(W,W+W-4),color=colors.lightGray})
            end
        end
        return lines
    end
    while true do
        W,H=term.getSize()
        local lines=buildLines()
        local lh=H-3
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        local hdr=" Bank Log ["..#log.."]"
        term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
        for row=1,lh do
            local ln=lines[row+scroll]
            term.setCursorPos(1,row+1) term.setBackgroundColor(colors.black)
            if ln then
                term.setTextColor(ln.color)
                term.write(ln.text..string.rep(" ",math.max(0,W-#ln.text)))
            else term.setTextColor(colors.black) term.write(string.rep(" ",W)) end
        end
        if scroll>0 then term.setCursorPos(W,2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
        if scroll+lh<#lines then term.setCursorPos(W,H-1) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white) term.write(" < Back ")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.gray) term.write("  Q=back")
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if (my==1 and mx>=W-2) or (my==H-1 and mx<=8) then return end
        elseif ev=="mouse_scroll" then scroll=math.max(0,math.min(scroll+p1,math.max(0,#lines-lh)))
        elseif ev=="key" then
            if p1==keys.q then return
            elseif p1==keys.up then scroll=math.max(0,scroll-1)
            elseif p1==keys.down then scroll=math.min(math.max(0,#lines-lh),scroll+1) end
        end
    end
end

local function bankDeposit(info)
    local srcItems = {
        {label="From Inventory",   icon=colors.orange},
        {label="From Cloud Vault", icon=colors.cyan  },
        {label="Back",             icon=colors.gray  },
    }
    local src = clickMenu("Deposit - Source", srcItems)
    if src==nil or src==3 then return end
    local source = src==1 and "inventory" or "vault"
    -- Fetch items from chosen source and filter to coins
    local fetchRes = rpc({type=src==1 and "list_inventory" or "list_vault",token=token}, 8)
    local allItems = (fetchRes and fetchRes.items) or {}
    local coinItems = {}
    for _, d in ipairs(DENOMS) do
        for _, item in ipairs(allItems) do
            if item.name==d.name and item.count>0 then
                table.insert(coinItems,{name=d.name,label=d.label,value=d.value,available=item.count})
                break
            end
        end
    end
    if #coinItems==0 then
        term.setBackgroundColor(colors.black) term.clear()
        term.setCursorPos(1,3) term.setTextColor(colors.red)
        term.write("No coins in "..(src==1 and "inventory" or "vault"))
        term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
        os.pullEvent() return
    end
    local sel = coinPickerUI({title="Deposit to Bank",coins=coinItems,confirmLabel="Deposit"})
    if not sel then return end
    local res = rpc({type="bank_deposit",token=token,source=source,coins=sel}, 15)
    term.setBackgroundColor(colors.black) term.clear()
    term.setCursorPos(1,3)
    if res and res.ok then
        term.setTextColor(colors.lime) term.write("Deposited "..res.moved.." sp!")
        term.setCursorPos(1,4) term.setTextColor(colors.gray) term.write("New balance: "..res.balance.." sp")
    else
        term.setTextColor(colors.red) term.write((res and res.err) or "Failed")
    end
    term.setCursorPos(1,6) term.setTextColor(colors.gray) term.write("Press any key...")
    os.pullEvent()
end

local function bankWithdraw(info)
    if info.balance <= 0 then
        term.setBackgroundColor(colors.black) term.clear()
        term.setCursorPos(1,3) term.setTextColor(colors.red) term.write("No balance to withdraw")
        term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
        os.pullEvent() return
    end
    -- Step 1: pick total amount
    local amt = amountPicker({title="Withdraw Amount",available=info.balance,hint="Pick denomination breakdown next"})
    if not amt then return end
    -- Step 2: fetch coin counts from the physical bank vault via bridge
    local denomRes = rpc({type="list_bank_vault", token=token}, 8)
    local bankDenoms = (denomRes and denomRes.denoms) or {}
    local coinItems = {}
    for _, d in ipairs(DENOMS) do
        local have = bankDenoms[d.name] or 0
        if have > 0 then
            table.insert(coinItems,{name=d.name,label=d.label,value=d.value,available=have})
        end
    end
    if #coinItems==0 then
        term.setBackgroundColor(colors.black) term.clear()
        term.setCursorPos(1,3) term.setTextColor(colors.red) term.write("Bank vault has no coins!")
        term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
        os.pullEvent() return
    end
    -- Auto-suggest greedy breakdown (largest first)
    local preset = {}
    local remaining = amt
    for _, d in ipairs(DENOMS) do
        if remaining<=0 then break end
        local have = bankDenoms[d.name] or 0
        if have>0 and d.value<=remaining then
            local take = math.min(have, math.floor(remaining/d.value))
            preset[d.name] = take
            remaining = remaining - take * d.value
        end
    end
    if remaining > 0 then
        term.setBackgroundColor(colors.black) term.clear()
        term.setCursorPos(1,3) term.setTextColor(colors.red)
        term.write("Bank can't make "..amt.."sp exactly")
        term.setCursorPos(1,4) term.setTextColor(colors.gray) term.write("(needs smaller denominations)")
        term.setCursorPos(1,6) term.setTextColor(colors.gray) term.write("Press any key...")
        os.pullEvent() return
    end
    -- Step 3: coin picker with target and auto-filled preset
    local sel = coinPickerUI({
        title="Withdraw "..amt.."sp",
        coins=coinItems,target=amt,
        confirmLabel="Withdraw",preset=preset,
    })
    if not sel then return end
    local res = rpc({type="bank_withdraw",token=token,coins=sel}, 15)
    term.setBackgroundColor(colors.black) term.clear()
    term.setCursorPos(1,3)
    if res and res.ok then
        term.setTextColor(colors.lime) term.write("Withdrew "..res.moved.." sp!")
        term.setCursorPos(1,4) term.setTextColor(colors.gray) term.write("New balance: "..res.balance.." sp")
        term.setCursorPos(1,5) term.setTextColor(colors.lime) term.write("Coins sent to inventory!")
    else
        term.setTextColor(colors.red) term.write((res and res.err) or "Failed")
    end
    term.setCursorPos(1,7) term.setTextColor(colors.gray) term.write("Press any key...")
    os.pullEvent()
end

local function bankLoans(info)
    while true do
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" Loans" .. string.rep(" ",math.max(0,W-9)) .. "[X]")
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2,3) term.setTextColor(colors.gray) term.write("Credit: ")
        term.setTextColor(creditColor(info.credit))
        term.write(info.credit .. " (" .. creditLabel(info.credit) .. ")")

        if info.loan then
            local loan = info.loan
            -- Row 4: due status
            local dColor = loan.overdue and colors.red or colors.yellow
            term.setCursorPos(2,4) term.setTextColor(dColor)
            term.write((loan.overdue and "!! OVERDUE !!" or ("Due in "..math.max(0,loan.daysLeft).." irl days")):sub(1,W-2))
            -- Row 5: original
            term.setCursorPos(2,5) term.setTextColor(colors.gray)
            term.write("Original:  " .. loan.original .. " sp")
            -- Row 6: remaining
            term.setCursorPos(2,6) term.setTextColor(colors.orange)
            term.write("Remaining: " .. loan.remaining .. " sp")
            
            -- ─── ALTERADO ABAIXO: Mudado de /day para /12h ───
            local periodInt = math.ceil(loan.remaining * (loan.rate / 100))
            term.setCursorPos(2,7) term.setTextColor(colors.gray)
            term.write(("Rate: "..loan.rate.."%/12h  (+"..periodInt.." sp/12h)"):sub(1,W-2))
            
            -- Row 8: total owed at due date
            local daysLeft = math.max(0, loan.daysLeft)
            if not loan.overdue and daysLeft > 0 then
                local est = loan.remaining
                -- ─── ALTERADO ABAIXO: Roda 2 vezes por dia restante (a cada 12h) ───
                for _=1,(daysLeft * 2) do est=math.ceil(est*(1+loan.rate/100)) end
                term.setCursorPos(2,8) term.setTextColor(colors.red)
                term.write(("At due date: ~"..est.." sp owed"):sub(1,W-2))
            elseif loan.overdue then
                term.setCursorPos(2,8) term.setTextColor(colors.red)
                -- ─── ALTERADO ABAIXO: Texto de aviso de atraso ───
                term.write(("Pay now! Interest growing every 12h"):sub(1,W-2))
            end
            -- Buttons: rows btnStart+1, btnStart+2, btnStart+3
            local btnStart = 9
            local payOpts = {
                { label="Pay Amount", icon=colors.yellow },
                { label="Pay All ("..loan.remaining.." sp)", icon=colors.lime },
                { label="Back", icon=colors.gray },
            }
            for i,opt in ipairs(payOpts) do
                term.setCursorPos(1, btnStart+i)
                term.setBackgroundColor(opt.icon) term.setTextColor(colors.black) term.write(" ")
                term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
                term.write(" "..opt.label..string.rep(" ",math.max(0,W-#opt.label-2)))
            end
            term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
            local ev,p1,p2,p3=os.pullEvent()
            if ev=="term_resize" then W,H=term.getSize()
            elseif ev=="mouse_click" then
                local mx,my=p2,p3
                if my==1 and mx>=W-2 then return end
                local idx=my-btnStart
                if idx>=1 and idx<=#payOpts then
                    local lbl=payOpts[idx].label
                    if lbl=="Back" then return
                    else
                        local payAmt
                        if lbl:sub(1,7)=="Pay All" then payAmt=loan.remaining
                        else
                            payAmt=amountPicker({title="Pay Loan",available=loan.remaining,hint="Total owed: "..loan.remaining.." sp"})
                        end
                        if payAmt then
                            local res=rpc({type="bank_pay_loan",token=token,amount=payAmt},15)
                            term.setBackgroundColor(colors.black) term.clear()
                            term.setCursorPos(1,3)
                            if res and res.ok then
                                term.setTextColor(colors.lime)
                                if res.loanCleared then term.write("Loan fully cleared!")
                                else term.write("Paid "..res.paid.." sp. Left: "..res.remaining.." sp") end
                                term.setCursorPos(1,4) term.setTextColor(colors.gray)
                                term.write("Credit: "..res.credit)
                            else
                                term.setTextColor(colors.red) term.write((res and res.err) or "Failed")
                            end
                            term.setCursorPos(1,6) term.setTextColor(colors.gray) term.write("Press any key...")
                            os.pullEvent()
                            return
                        end
                    end
                end
            elseif ev=="key" and p1==keys.q then return end
        else
            -- No loan
            if info.loanRate then
                -- Row 4: rate
                term.setCursorPos(2,4) term.setTextColor(colors.gray)
                -- ─── ALTERADO ABAIXO: Mudado para %/12h ───
                term.write(("Rate: "..info.loanRate.."%/12h  |  Max: 64 sp"):sub(1,W-2))
                -- Row 5: term
                term.setCursorPos(2,5) term.setTextColor(colors.gray)
                term.write("Must repay within 5 irl days")
                
                -- Row 6: total cost for 64sp
                local est=64
                -- ─── ALTERADO ABAIXO: Roda 10 vezes (2 vezes por dia ao longo de 5 dias) ───
                for _=1,10 do est=math.ceil(est*(1+info.loanRate/100)) end
                term.setCursorPos(2,6) term.setTextColor(colors.orange)
                term.write(("64sp / 5 irl days = ~"..est.." sp"):sub(1,W-2))
                
                -- Row 7: daily interest on 64sp
                local period=math.ceil(64*(info.loanRate/100))
                term.setCursorPos(2,7) term.setTextColor(colors.lightBlue)
                -- ─── ALTERADO ABAIXO: Mudado para sp/12h ───
                term.write(("Interest: +"..period.." sp/12h"):sub(1,W-2))
                
                -- Buttons: rows btnStart2+1, btnStart2+2
                local btnStart2 = 8
                local lOpts={{label="Get a Loan",icon=colors.green},{label="Back",icon=colors.gray}}
                for i,opt in ipairs(lOpts) do
                    term.setCursorPos(1,btnStart2+i)
                    term.setBackgroundColor(opt.icon) term.setTextColor(colors.black) term.write(" ")
                    term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
                    term.write(" "..opt.label..string.rep(" ",math.max(0,W-#opt.label-2)))
                end
                term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
                local ev,p1,p2,p3=os.pullEvent()
                if ev=="term_resize" then W,H=term.getSize()
                elseif ev=="mouse_click" then
                    local mx,my=p2,p3
                    if my==1 and mx>=W-2 then return end
                    local idx=my-btnStart2
                    if idx==2 then return  -- Back
                    elseif idx==1 then
                        local amt=amountPicker({title="Loan Amount",available=64,
                            hint="Rate: "..info.loanRate.."%/12h, 5 irl day limit"})
                        if amt then
                            -- Show repayment estimate for chosen amount
                            local res=rpc({type="bank_get_loan",token=token,amount=amt},15)
                            term.setBackgroundColor(colors.black) term.clear()
                            term.setCursorPos(1,3)
                            if res and res.ok then
                                local repay=amt
                                -- ─── ALTERADO ABAIXO: Simulação do juro composto rodando 10 vezes ───
                                for _=1,10 do repay=math.ceil(repay*(1+info.loanRate/100)) end
                                term.setTextColor(colors.lime)
                                term.write("Loan of "..res.amount.." sp approved!")
                                term.setCursorPos(1,4) term.setTextColor(colors.gray)
                                -- ─── ALTERADO ABAIXO: Mudado para %/12h ───
                                term.write(("Rate: "..res.rate.."%/12h  5 irl days"):sub(1,W-2))
                                term.setCursorPos(1,5) term.setTextColor(colors.orange)
                                term.write(("At due date: ~"..repay.." sp owed"):sub(1,W-2))
                                term.setCursorPos(1,6) term.setTextColor(colors.lightBlue)
                                term.write("Coins are in your cloud vault")
                            else
                                term.setTextColor(colors.red) term.write((res and res.err) or "Failed")
                            end
                            term.setCursorPos(1,8) term.setTextColor(colors.gray) term.write("Press any key...")
                            os.pullEvent()
                            return
                        end
                    end
                elseif ev=="key" and p1==keys.q then return end
            else
                term.setCursorPos(2,4) term.setTextColor(colors.red)
                term.write("Credit too low for loans (need 300+)")
                term.setCursorPos(2,6) term.setTextColor(colors.gray) term.write("Press any key or Q...")
                local ev,p1,p2,p3=os.pullEvent()
                if ev=="key" or ev=="mouse_click" then return end
            end
        end
    end
end

local function bankMenu()
    while true do
        local info = rpc({type="bank_info", token=token}, 10)
        if not info or not info.ok then
            term.setBackgroundColor(colors.black) term.clear()
            term.setCursorPos(1,3) term.setTextColor(colors.red)
            term.write((info and info.err) or "Bank server error")
            term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
            os.pullEvent() return
        end
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        local hdr=" Bank - "..username
        if #hdr>W-3 then hdr=hdr:sub(1,W-3) end
        term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2,2) term.setTextColor(colors.gray) term.write("Balance: ")
        term.setTextColor(colors.yellow) term.write(info.balance.." sp")
        
        -- Row 3: daily deposit interest
        term.setCursorPos(2,3)
        if info.balance > 0 then
            -- ─── ALTERADO ABAIXO: Mudado o cálculo local de 0.02 (2%) para 0.005 (0.5%) ───
            local periodDep = math.max(1, math.floor(info.balance * 0.005))
            term.setTextColor(colors.lime)
            -- ─── ALTERADO ABAIXO: Mudado o texto de sp/day para sp/12h ───
            term.write(("+"..periodDep.." sp/12h  (0.5%/12h)"):sub(1,W-2))
        else
            term.setTextColor(colors.gray) term.write("Deposit coins to earn interest")
        end
        
        -- Row 4: credit score
        term.setCursorPos(2,4) term.setTextColor(colors.gray) term.write("Credit:  ")
        term.setTextColor(creditColor(info.credit))
        term.write((info.credit.." ("..creditLabel(info.credit)..")"):sub(1,W-10))
        -- Row 5: active loan summary (if any)
        if info.loan then
            local lc=info.loan.overdue and colors.red or colors.orange
            term.setCursorPos(2,5) term.setTextColor(lc)
            local ls=info.loan.overdue and "OVERDUE" or ("due "..info.loan.daysLeft.." irl days")
            term.write(("Loan: "..info.loan.remaining.."sp ("..ls..")"):sub(1,W-2))
        end
        local menuItems={
            {label="Deposit",   icon=colors.green},
            {label="Withdraw", icon=colors.blue},
            {label="Loans",    icon=colors.yellow},
            {label="Log",      icon=colors.gray},
            {label="Back",     icon=colors.red},
        }
        local mStart=5
        for i,opt in ipairs(menuItems) do
            term.setCursorPos(1,mStart+i)
            term.setBackgroundColor(opt.icon) term.setTextColor(colors.black) term.write(" ")
            term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
            term.write(" "..opt.label..string.rep(" ",math.max(0,W-#opt.label-2)))
        end
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return end
            local idx=my-mStart
            if idx>=1 and idx<=#menuItems then
                local lbl=menuItems[idx].label
                if lbl=="Back" then return
                elseif lbl=="Deposit" then bankDeposit(info)
                elseif lbl=="Withdraw" then bankWithdraw(info)
                elseif lbl=="Loans" then bankLoans(info)
                elseif lbl=="Log" then bankBlog()
                end
            end
        elseif ev=="key" and p1==keys.q then return end
    end
end

local function calcTax(price)
    if price < 5 then return 0
    elseif price <= 20 then return 1
    else return math.floor(price * 0.05) end
end

-- ── Market UI ────────────────────────────────────────────────────────────────

-- Numeric keyboard input (used for price, lot size, etc.)
local function numInput(title, hint, minV, maxV)
    while true do
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine() term.write(" "..title)
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2,3) term.setTextColor(colors.lightGray)
        term.write((hint or "Enter a number"):sub(1,W-2))
        term.setCursorPos(2,4) term.setTextColor(colors.gray)
        if maxV then term.write("Range: "..minV.." - "..maxV)
        else term.write("Min: "..minV.."  (blank=cancel)") end
        term.setCursorPos(2,6) term.setTextColor(colors.yellow) term.write("> ")
        term.setTextColor(colors.white)
        local input = read()
        if input=="" or input=="q" then return nil end
        local n = tonumber(input)
        if n and n>=(minV or 0) and (not maxV or n<=maxV) then return math.floor(n) end
        term.setCursorPos(2,8) term.setTextColor(colors.red)
        term.write("Invalid! ".. (maxV and (minV.."-"..maxV) or (">="..minV)))
        sleep(1.2)
    end
end

-- Scrollable item picker (single click to select, returns item or nil)
local function pickItem(source)
    local fetchType = source=="inventory" and "list_inventory" or "list_vault"
    local res = rpc({type=fetchType, token=token}, 12)
    local items = (res and res.items) or {}
    if #items==0 then
        term.setBackgroundColor(colors.black) term.clear()
        term.setCursorPos(2,3) term.setTextColor(colors.red)
        if not res then
            term.write("Bridge timeout - is bridge running?")
        elseif res.err then
            term.write(res.err:sub(1,W-2))
        else
            term.write("No items in "..(source=="inventory" and "inventory" or "vault"))
        end
        term.setCursorPos(2,5) term.setTextColor(colors.gray) term.write("Press any key...")
        os.pullEvent() return nil
    end
    local scroll=0
    while true do
        W,H=term.getSize()
        local listH=H-2
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        local hdrPick = " Pick Item ["..#items.."]"
        term.write(hdrPick..string.rep(" ",math.max(0,W-#hdrPick-3)).."[X]")
        for row=1,listH do
            local item=items[row+scroll]
            term.setCursorPos(1,row+1) term.setBackgroundColor(colors.black)
            if item then
                term.setBackgroundColor(itemColor(item.name)) term.setTextColor(colors.black) term.write(" ") term.setBackgroundColor(colors.black)
                local cs="x"..item.count
                local lbl=prettyName(item):sub(1,W-3-#cs)
                term.setTextColor(colors.white) term.write(" "..lbl)
                term.setTextColor(colors.cyan)
                term.write(string.rep(" ",math.max(0,W-3-#lbl-#cs))..cs)
            else term.write(string.rep(" ",W)) end
        end
        if scroll>0 then term.setCursorPos(W,2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
        if scroll+listH<#items then term.setCursorPos(W,H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
        term.write("Click item to select  Q=cancel")
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return nil end
            local idx=my-1+scroll
            if idx>=1 and idx<=#items then return items[idx] end
        elseif ev=="mouse_scroll" then
            scroll=math.max(0,math.min(scroll+p1,math.max(0,#items-listH)))
        elseif ev=="key" and p1==keys.q then return nil end
    end
end

-- Browse & buy market listings
local function marketBrowse()
    local listings,bundles,filteredBundles={},{},{}
    local scroll=0
    local searchMode=false local searchQuery=""
    local message="" local msgTimer=0
    local LIST_TOP=2
    local shimmerPhase = 0
    local shimmerTimer = os.startTimer(0.4)
    local SHIMMER_COLS = {colors.yellow, colors.orange, colors.white, colors.orange}
    local function listBot() return H-3 end
    local function listItems() return math.floor((listBot()-LIST_TOP+1)/2) end
    local function shortName(l)
        local dn = l.display_name
        if dn and not dn:match("^[^%s]+:") then return dn end
        local plain = (l.item_name:match(":(.+)$") or l.item_name):gsub("_"," ")
        return plain:gsub("(%a)([%w_']*)", function(a,b) return a:upper()..b end)
    end
    local function ppi(l) return l.price / math.max(1, l.lot_size) end

    local function buildBundles()
        local byItem={} local order={}
        for _,l in ipairs(listings) do
            local key=l.item_name
            if not byItem[key] then
                byItem[key]={item_name=l.item_name,display_name=l.display_name,sellers={},is_boosted=false}
                table.insert(order,key)
            end
            local b=byItem[key]
            table.insert(b.sellers,l)
            if l.boost_ts and l.boost_ts>os.epoch("utc") then b.is_boosted=true end
        end
        bundles={}
        for _,iname in ipairs(order) do
            local b=byItem[iname]
            table.sort(b.sellers,function(a,c)
                local aoos=a.stock<=0; local coos=c.stock<=0
                if aoos~=coos then return not aoos end
                return ppi(a)<ppi(c)
            end)
            table.insert(bundles,b)
        end
        table.sort(bundles,function(a,c)
            if a.is_boosted~=c.is_boosted then return a.is_boosted end
            local ab=a.sellers[1]; local cb=c.sellers[1]
            if not ab then return false end; if not cb then return true end
            local aoos=ab.stock<=0; local coos=cb.stock<=0
            if aoos~=coos then return not aoos end
            return ppi(ab)<ppi(cb)
        end)
    end

    local function applyFilter()
        if searchQuery=="" then filteredBundles=bundles
        else
            local q=searchQuery:lower() filteredBundles={}
            for _,b in ipairs(bundles) do
                local dn=(b.display_name or b.item_name):lower()
                if dn:find(q,1,true) or b.item_name:lower():find(q,1,true) then
                    table.insert(filteredBundles,b) end
            end
        end
        scroll=0
    end

    local function doFetch()
        local r=rpc({type="market_list",token=token},8)
        listings=(r and r.listings) or {}
        buildBundles()
    end

    -- Listing detail / buy page; returns true if a purchase was made
    local function showDetail(l)
        local bi=rpc({type="bank_info",token=token},5)
        local bal=(bi and bi.balance) or 0
        local qty=1
        local maxQty=math.max(1,l.stock)
        local tax=calcTax(l.price)
        while true do
            W,H=term.getSize()
            local totalPrice=l.price*qty
            local canBuy=(l.stock>0) and (bal>=totalPrice)
            local buyLabel=" Buy ("..qty.." lot"..(qty>1 and "s" or "")..") "
            local cancelLabel=" Back "
            term.setBackgroundColor(colors.black) term.clear()
            term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
            term.setCursorPos(1,1) term.clearLine()
            term.write(" Listing"..string.rep(" ",math.max(0,W-11)).."[X]")
            term.setBackgroundColor(colors.black)
            -- Item + seller
            term.setCursorPos(2,2) term.setBackgroundColor(itemColor(l.item_name)) term.write(" ") term.setBackgroundColor(colors.black) term.write(" ")
            term.setTextColor(colors.white) term.write((l.display_name or l.item_name):sub(1,W-4))
            term.setCursorPos(2,3) term.setTextColor(colors.gray) term.write("By: ")
            term.setTextColor(colors.yellow) term.write((l.seller or "?"):sub(1,W-6))
            -- Lot & price
            term.setCursorPos(2,4) term.setTextColor(colors.gray)
            term.write(("Lot:  "..l.lot_size.." item(s) / purchase"):sub(1,W-2))
            term.setCursorPos(2,5) term.setTextColor(colors.gray)
            term.write("Price: "..l.price.." sp each")
            -- Stock
            term.setCursorPos(2,6)
            if l.stock<=0 then term.setTextColor(colors.red) term.write("OUT OF STOCK")
            else term.setTextColor(colors.lime) term.write("Stock: "..l.stock.." lot(s)") end
            -- Divider
            term.setCursorPos(1,7) term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
            term.write(string.rep("-",W))
            -- Qty selector (only if in stock)
            if l.stock>0 then
                term.setCursorPos(2,8) term.setTextColor(colors.white)
                term.write("Qty: ")
                term.setTextColor(colors.yellow) term.write(qty.." lot(s)")
                term.setCursorPos(2,9) term.setTextColor(colors.gray) term.write("  scroll to change")
                -- Summary
                term.setCursorPos(2,10) term.setTextColor(colors.white)
                term.write(("Total: "..totalPrice.." sp"):sub(1,W-2))
                term.setCursorPos(2,11)
                if bal>=totalPrice then
                    term.setTextColor(colors.lime)
                    term.write(("After: "..(bal-totalPrice).." sp"):sub(1,W-2))
                else
                    term.setTextColor(colors.red)
                    term.write(("Need "..(totalPrice-bal).." more sp!"):sub(1,W-2))
                end
            end
            -- Buttons
            term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
            if l.stock>0 then
                local buyBg = canBuy and colors.white or colors.gray
                local buyFg = canBuy and colors.black or colors.lightGray
                term.setBackgroundColor(buyBg) term.setTextColor(buyFg) term.write(buyLabel)
                local gap=math.max(1,W-#buyLabel-#cancelLabel)
                term.setBackgroundColor(colors.black) term.write(string.rep(" ",gap))
            end
            term.setBackgroundColor(colors.orange) term.setTextColor(colors.white) term.write(cancelLabel)
            term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
            local ev,p1,p2,p3=os.pullEvent()
            if ev=="term_resize" then W,H=term.getSize()
            elseif ev=="mouse_scroll" then
                if l.stock>0 then qty=math.max(1,math.min(maxQty,qty-p1)) end
            elseif ev=="key" then
                if p1==keys.q then return false
                elseif p1==keys.up   then qty=math.min(maxQty,qty+1)
                elseif p1==keys.down then qty=math.max(1,qty-1) end
            elseif ev=="mouse_click" then
                local mx,my=p2,p3
                if my==1 and mx>=W-2 then return false end
                if my==H-1 then
                    if l.stock>0 and mx<=#buyLabel then
                        if not canBuy then
                            -- flash message — just redraw, nothing to do
                        else
                            local r=rpc({type="market_buy",token=token,listing_id=l.id,lots=qty},15)
                            term.setBackgroundColor(colors.black) term.clear()
                            term.setCursorPos(1,3)
                            if r and r.ok then
                                term.setTextColor(colors.lime)
                                term.write(("Bought! "..r.count.."x "..r.item):sub(1,W-2))
                                term.setCursorPos(1,4) term.setTextColor(colors.gray)
                                term.write(("Paid: "..r.price.." sp  Bal: "..(r.new_balance or "?").." sp"):sub(1,W-2))
                                term.setCursorPos(1,5)
                                if r.inVault then term.setTextColor(colors.yellow) term.write("Items in vault (inv full)")
                                else term.setTextColor(colors.lime) term.write("Items sent to inventory!") end
                            else
                                term.setTextColor(colors.red) term.write((r and r.err) or "Failed")
                            end
                            term.setCursorPos(1,7) term.setTextColor(colors.gray) term.write("Press any key...")
                            os.pullEvent()
                            return true
                        end
                    else
                        return false
                    end
                end
            end
        end
    end

    -- Sellers list for a bundle; returns true if a purchase was made
    local function showSellers(bundle)
        local scr=0
        while true do
            W,H=term.getSize()
            local listH=H-3
            local perScreen=math.floor(listH/2)
            term.setBackgroundColor(colors.black) term.clear()
            term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
            term.setCursorPos(1,1) term.clearLine()
            local dn=shortName(bundle.sellers[1] or {item_name=bundle.item_name,display_name=bundle.display_name})
            local hdr=" "..dn:sub(1,W-8).." ("..#bundle.sellers..")"
            term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
            term.setBackgroundColor(colors.black)
            for row=1,perScreen do
                local l=bundle.sellers[row+scr]
                local ya=LIST_TOP+(row-1)*2
                local yb=ya+1
                term.setCursorPos(1,ya) term.setBackgroundColor(colors.black) term.clearLine()
                term.setCursorPos(1,yb) term.setBackgroundColor(colors.black) term.clearLine()
                if l then
                    local oos=l.stock<=0
                    local sc=oos and "OOS" or (l.stock.." lots")
                    local left=" "..(l.seller or "?")
                    term.setCursorPos(1,ya)
                    term.setTextColor(oos and colors.gray or colors.yellow)
                    term.write(left:sub(1,W-#sc-1))
                    term.setTextColor(oos and colors.red or colors.lime)
                    term.write(string.rep(" ",math.max(1,W-#left-#sc))..sc)
                    term.setCursorPos(1,yb)
                    term.setTextColor(oos and colors.gray or colors.white)
                    term.write("  x"..l.lot_size.." for "..l.price.."sp")
                end
            end
            if scr>0 then term.setCursorPos(W,LIST_TOP) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
            if scr+perScreen<#bundle.sellers then term.setCursorPos(W,listH+1) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
            term.setCursorPos(1,H-1) term.setBackgroundColor(colors.orange) term.setTextColor(colors.white) term.write(" < Back ")
            term.setBackgroundColor(colors.black) term.setTextColor(colors.gray) term.write("  Click listing to buy")
            term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
            local ev,p1,p2,p3=os.pullEvent()
            if ev=="term_resize" then W,H=term.getSize()
            elseif ev=="mouse_scroll" then
                scr=math.max(0,math.min(scr+p1,math.max(0,#bundle.sellers-perScreen)))
            elseif ev=="mouse_click" then
                local mx,my=p2,p3
                if my==1 and mx>=W-2 then return false end
                if my==H-1 and mx<=8 then return false end
                local row=my-LIST_TOP+1
                local l=bundle.sellers[math.ceil(row/2)+scr]
                if l then
                    local bought=showDetail(l)
                    if bought then return true end
                end
            elseif ev=="key" and p1==keys.q then return false end
        end
    end

    doFetch() applyFilter()
    while true do
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        if searchMode then term.write(" /"..searchQuery.."_")
        else
            local hdr=" Market ["..#filteredBundles.."]"
            term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
        end
        for i=1,listItems() do
            local b=filteredBundles[i+scroll]
            local ya=LIST_TOP+(i-1)*2
            local yb=ya+1
            term.setCursorPos(1,ya) term.setBackgroundColor(colors.black) term.clearLine()
            term.setCursorPos(1,yb) term.setBackgroundColor(colors.black) term.clearLine()
            if b then
                local best=b.sellers[1]
                local oos=not best or best.stock<=0
                local dn=shortName(best or {item_name=b.item_name,display_name=b.display_name})
                local sc=oos and "OOS" or ("["..#b.sellers.."]")
                local nameW=math.max(1,W-4-#sc)
                term.setCursorPos(1,ya)
                term.setBackgroundColor(oos and colors.gray or itemColor(b.item_name))
                term.write(" ")
                term.setBackgroundColor(colors.black) term.write(" ")
                local isBoosted=b.is_boosted and not oos
                if isBoosted then term.setTextColor(SHIMMER_COLS[shimmerPhase+1])
                else term.setTextColor(oos and colors.gray or colors.white) end
                term.write(dn:sub(1,nameW)..string.rep(" ",math.max(0,nameW-#dn)).." ")
                term.setTextColor(oos and colors.red or colors.lime) term.write(sc)
                term.setCursorPos(1,yb) term.setTextColor(colors.gray)
                if best then term.write("  x"..best.lot_size.." for "..best.price.."sp") end
            end
        end
        if scroll>0 then term.setCursorPos(W,LIST_TOP) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
        if scroll+listItems()<#filteredBundles then term.setCursorPos(W,listBot()) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
        term.setCursorPos(1,H-2) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.gray)  term.write(" / ")
        term.setBackgroundColor(colors.black) term.write(" ")
        term.setBackgroundColor(colors.gray)  term.write(" R Refresh ")
        term.setBackgroundColor(colors.black) term.write(" ")
        term.setBackgroundColor(colors.orange) term.write(" < Back ")
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black)
        if message~="" and os.clock()<msgTimer then
            term.setTextColor(colors.lime) term.write(message:sub(1,W))
        else
            message=""
            term.setTextColor(colors.gray) term.write("Click listing to view")
        end
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="timer" and p1==shimmerTimer then
            shimmerPhase=(shimmerPhase+1)%#SHIMMER_COLS
            shimmerTimer=os.startTimer(0.4)
        elseif searchMode then
            if ev=="char" then searchQuery=searchQuery..p1 applyFilter()
            elseif ev=="key" then
                if p1==keys.backspace then
                    if searchQuery=="" then searchMode=false
                    else searchQuery=searchQuery:sub(1,-2) applyFilter() end
                elseif p1==keys.enter then searchMode=false end
            elseif ev=="mouse_click" then searchMode=false end
        else
            if ev=="mouse_scroll" then
                scroll=math.max(0,math.min(scroll+p1,math.max(0,#filteredBundles-listItems())))
            elseif ev=="key" then
                if p1==keys.q then return
                elseif p1==keys.r then doFetch() applyFilter() message="Refreshed" msgTimer=os.clock()+1
                elseif p1==keys.slash then searchMode=true searchQuery="" applyFilter() end
            elseif ev=="mouse_click" then
                local mx,my=p2,p3
                if my==1 and mx>=W-2 then return end
                if my==H-2 then
                    if mx>=1 and mx<=3 then searchMode=true searchQuery="" applyFilter()
                    elseif mx>=5 and mx<=15 then doFetch() applyFilter() message="Refreshed" msgTimer=os.clock()+1
                    elseif mx>=17 and mx<=24 then return end
                else
                    local row=my-LIST_TOP+1
                    local b=filteredBundles[math.ceil(row/2)+scroll]
                    if b then
                        local bought=showSellers(b)
                        shimmerTimer=os.startTimer(0.4)
                        if bought then doFetch() applyFilter() end
                    end
                end
            end
        end
    end
end

-- Add a new listing (just defines item/lot/price; stock added via My Listings)
local function marketAddListing()
    -- Ask where to pick the item from
    local srcOpts={
        {label="From Inventory", icon=colors.orange},
        {label="From Vault",     icon=colors.cyan  },
        {label="Back",           icon=colors.gray  },
    }
    local s=clickMenu("Add Listing - Source",srcOpts)
    if not s or s==3 then return end
    local fromInventory = s==1
    local item=pickItem(fromInventory and "inventory" or "vault")
    if not item then return end
    local lot_size=numInput("Lot Size","Items per purchase (have "..item.count.."x)",1,item.count)
    if not lot_size then return end
    local price=numInput("Price per Lot",lot_size.."x "..(item.displayName or item.name):sub(1,W-12).." for?",0,nil)
    if price==nil then return end
    local tax=calcTax(price)
    -- Summary screen
    W,H=term.getSize()
    term.setBackgroundColor(colors.black) term.clear()
    term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
    term.setCursorPos(1,1) term.clearLine()
    local hdrCL = " Create Listing"
    term.write(hdrCL..string.rep(" ",math.max(0,W-#hdrCL-3)).."[X]")
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2,3) term.setTextColor(colors.white)
    term.write(("Item:  "..(item.displayName or item.name)):sub(1,W-2))
    term.setCursorPos(2,4) term.write("Lot:   "..lot_size.." item(s) per sale")
    term.setCursorPos(2,5) term.write("Price: "..price.." sp per lot")
    term.setCursorPos(2,6) term.setTextColor(colors.cyan) term.write("Starts with 0 stock")
    term.setCursorPos(2,7) term.setTextColor(colors.gray) term.write("Add stock in My Listings")
    term.setCursorPos(2,8) term.setTextColor(colors.orange)
    if tax==0 then term.write("No fee per lot sold (<5 sp)")
    elseif tax==1 then term.write("Flat 1 sp fee per lot sold (5-20 sp)")
    else term.write("5% fee: "..tax.." sp deducted per lot sold (>10 sp)") end
    term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
    term.setBackgroundColor(colors.white) term.setTextColor(colors.black) term.write(" Create ")
    term.setBackgroundColor(colors.black) term.write("  ")
    term.setBackgroundColor(colors.red) term.write(" Cancel ")
    term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
    while true do
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="mouse_click" then
            if p3==1 and p2>=W-2 then return end
            if p3==H-1 then
                if p2>=1 and p2<=8 then
                    local r=rpc({type="market_create_listing",token=token,
                        item_name=item.name,display_name=item.displayName or item.name,
                        lot_size=lot_size,price=price},10)
                    term.setBackgroundColor(colors.black) term.clear()
                    term.setCursorPos(1,3)
                    if r and r.ok then
                        term.setTextColor(colors.lime)
                        if r.merged then term.write("Listing already exists!")
                        else term.write("Listing created!") end
                        term.setCursorPos(1,4) term.setTextColor(colors.cyan) term.write("Add stock in My Listings")
                    else
                        term.setTextColor(colors.red) term.write((r and r.err) or "Failed")
                    end
                    term.setCursorPos(1,6) term.setTextColor(colors.gray) term.write("Press any key...")
                    os.pullEvent() return
                elseif p2>=11 and p2<=18 then return end
            end
        elseif ev=="key" and p1==keys.q then return end
    end
end

-- Manage own listings
local function marketMyListings()
    local listings={} local scroll=0 local needFetch=true
    while true do
        if needFetch then
            local r=rpc({type="market_my_listings",token=token},8)
            listings=(r and r.listings) or {}
            scroll=0 needFetch=false
        end
        W,H=term.getSize()
        local listH=H-3
        local perPage=math.floor(listH/2)
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" My Listings ["..#listings.."]"..string.rep(" ",math.max(0,W-18)).."[X]")
        for row=1,perPage do
            local l=listings[row+scroll]
            local ya=row*2
            local yb=ya+1
            term.setCursorPos(1,ya) term.setBackgroundColor(colors.black) term.clearLine()
            term.setCursorPos(1,yb) term.setBackgroundColor(colors.black) term.clearLine()
            if l then
                local oos=(l.stock<=0)
                term.setCursorPos(1,ya)
                term.setBackgroundColor(oos and colors.gray or itemColor(l.item_name)) term.setTextColor(colors.black) term.write(" ") term.setBackgroundColor(colors.black)
                local info=" x"..l.lot_size.."@"..l.price.."sp"
                local sc=oos and " OOS" or (" S:"..l.stock)
                local nameW=W-1-#info-#sc
                local name=" "..(l.display_name or l.item_name):sub(1,nameW-1)
                term.setTextColor(oos and colors.gray or colors.white)
                term.write(name..string.rep(" ",math.max(0,nameW-#name))..info)
                term.setTextColor(oos and colors.red or colors.lime) term.write(sc)
            end
        end
        if scroll>0 then term.setCursorPos(W,2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
        if scroll+perPage<#listings then term.setCursorPos(W,H-1) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.orange) term.write(" < Back ")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.gray) term.write("  Click listing to manage")
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return end
            if my==H-1 and mx<=8 then return end
            local idx=math.ceil((my-1)/2)+scroll
            local l=listings[idx]
            if l then
                local now_ts = os.epoch("utc")
                local boostDays = (l.boost_ts and l.boost_ts > now_ts) and math.ceil((l.boost_ts - now_ts) / 86400000) or nil
                local boostLabel = boostDays and ("Boosted ("..boostDays.."d left)") or "Boost (10sp/day)"
                local opts={
                    {label="Add Stock",     icon=colors.green},
                    {label="Edit Listing",  icon=colors.cyan},
                    {label=boostLabel,      icon=boostDays and colors.yellow or colors.orange},
                    {label="Cancel Listing",icon=colors.red},
                    {label="Back",          icon=colors.gray},
                }
                local sub=clickMenu("Manage: "..(l.display_name or l.item_name):sub(1,W-10),opts)
                if sub==1 then
                    -- Add stock
                    local srcOpts={{label="From Inventory",icon=colors.orange},{label="From Vault",icon=colors.cyan},{label="Back",icon=colors.gray}}
                    local s=clickMenu("Add Stock - Source",srcOpts)
                    if s and s~=3 then
                        local src2=s==1 and "inventory" or "vault"
                        local fetchRes=rpc({type=s==1 and "list_inventory" or "list_vault",token=token},8)
                        local itemCount=0
                        for _,it in ipairs((fetchRes and fetchRes.items) or {}) do
                            if it.name==l.item_name then itemCount=itemCount+it.count end
                        end
                        local maxLots=math.floor(itemCount/l.lot_size)
                        if maxLots<=0 then
                            term.setBackgroundColor(colors.black) term.clear()
                            term.setCursorPos(1,3) term.setTextColor(colors.red)
                            term.write("Not enough items! Need "..l.lot_size.."x "..(l.display_name or l.item_name):sub(1,W-12))
                            term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
                            os.pullEvent()
                        else
                            local lots=amountPicker({
                                title="Add Stock",
                                headerColor=colors.orange,
                                unit="lot(s)",
                                available=maxLots,
                                availableLabel="Have: "..itemCount.."x "..(l.display_name or l.item_name),
                                hint="Lot size: "..l.lot_size.." item(s) each",
                            })
                            if lots then
                                local r=rpc({type="market_add_stock",token=token,listing_id=l.id,lots=lots,source=src2},15)
                                term.setBackgroundColor(colors.black) term.clear()
                                term.setCursorPos(1,3)
                                if r and r.ok then term.setTextColor(colors.lime) term.write("Added "..r.added.." lot(s). Stock: "..r.stock)
                                else term.setTextColor(colors.red) term.write((r and r.err) or "Failed") end
                                term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
                                os.pullEvent() needFetch=true
                            end
                        end
                    end
                elseif sub==2 then
                    -- Edit listing (price or lot size)
                    local canEditLot = (l.stock == 0)
                    local lotLbl = canEditLot and ("Lot Size (now "..l.lot_size..")") or ("Lot Size (need 0 stock)")
                    local eOpts={
                        {label="Price (now "..l.price.."sp)", icon=colors.yellow},
                        {label=lotLbl,                        icon=canEditLot and colors.cyan or colors.gray},
                        {label="Back",                        icon=colors.gray},
                    }
                    local esub=clickMenu("Edit: "..(l.display_name or l.item_name):sub(1,W-8),eOpts)
                    if esub==1 then
                        local np=numInput("New Price","Current: "..l.price.."sp per lot",0)
                        if np~=nil then
                            local r=rpc({type="market_edit_listing",token=token,listing_id=l.id,price=np},10)
                            term.setBackgroundColor(colors.black) term.clear()
                            term.setCursorPos(1,3)
                            if r and r.ok then term.setTextColor(colors.lime) term.write("Price set to "..np.."sp")
                            else term.setTextColor(colors.red) term.write((r and r.err) or "Failed") end
                            term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
                            os.pullEvent() needFetch=true
                        end
                    elseif esub==2 and canEditLot then
                        local nl=numInput("New Lot Size","Current: "..l.lot_size.." item(s) per sale",1)
                        if nl~=nil then
                            local r=rpc({type="market_edit_listing",token=token,listing_id=l.id,lot_size=nl},10)
                            term.setBackgroundColor(colors.black) term.clear()
                            term.setCursorPos(1,3)
                            if r and r.ok then term.setTextColor(colors.lime) term.write("Lot size set to "..nl)
                            else term.setTextColor(colors.red) term.write((r and r.err) or "Failed") end
                            term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
                            os.pullEvent() needFetch=true
                        end
                    end
                elseif sub==3 then
                    -- Boost listing
                    local days=amountPicker({
                        title="Boost Listing",
                        headerColor=colors.yellow,
                        unit="day(s)",
                        available=30,
                        availableLabel="Max: 30 days",
                        hint="10 sp/day from bank balance",
                    })
                    if days then
                        local cost=days*10
                        W,H=term.getSize()
                        term.setBackgroundColor(colors.black) term.clear()
                        term.setBackgroundColor(colors.yellow) term.setTextColor(colors.black)
                        term.setCursorPos(1,1) term.clearLine() term.write(" Boost Listing")
                        term.setBackgroundColor(colors.black)
                        term.setCursorPos(2,3) term.setTextColor(colors.white)
                        term.write(("Item: "..(l.display_name or l.item_name)):sub(1,W-2))
                        term.setCursorPos(2,5) term.setTextColor(colors.yellow) term.write(days.." day(s)  =  "..cost.." sp")
                        term.setCursorPos(2,6) term.setTextColor(colors.gray) term.write("Deducted from bank balance")
                        term.setCursorPos(2,8) term.setTextColor(colors.cyan) term.write("Goes to top of market tab")
                        term.setCursorPos(2,9) term.setTextColor(colors.yellow) term.write("Name shimmers gold while active")
                        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
                        term.setBackgroundColor(colors.white) term.setTextColor(colors.black) term.write(" Confirm ")
                        term.setBackgroundColor(colors.black) term.write("  ")
                        term.setBackgroundColor(colors.red) term.setTextColor(colors.white) term.write(" Cancel ")
                        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
                        local confirmed=false
                        while true do
                            local bev,bp1,bp2,bp3=os.pullEvent()
                            if bev=="mouse_click" then
                                if bp3==1 and bp2>=W-2 then break end
                                if bp3==H-1 then
                                    if bp2>=1 and bp2<=9 then confirmed=true break
                                    elseif bp2>=12 then break end
                                end
                            elseif bev=="key" and bp1==keys.q then break end
                        end
                        if confirmed then
                            local r=rpc({type="market_boost_listing",token=token,listing_id=l.id,days=days},10)
                            term.setBackgroundColor(colors.black) term.clear()
                            term.setCursorPos(1,3)
                            if r and r.ok then
                                term.setTextColor(colors.yellow) term.write("Listing boosted!")
                                term.setCursorPos(1,4) term.setTextColor(colors.lime) term.write(days.." day(s) boost active")
                                term.setCursorPos(1,5) term.setTextColor(colors.orange) term.write("Cost: "..cost.." sp deducted")
                            else
                                term.setTextColor(colors.red) term.write((r and r.err) or "Failed")
                            end
                            term.setCursorPos(1,7) term.setTextColor(colors.gray) term.write("Press any key...")
                            os.pullEvent() needFetch=true
                        end
                    end
                elseif sub==4 then
                    -- Cancel listing
                    local r=rpc({type="market_cancel",token=token,listing_id=l.id},15)
                    term.setBackgroundColor(colors.black) term.clear()
                    term.setCursorPos(1,3)
                    if r and r.ok then
                        term.setTextColor(colors.lime) term.write("Listing removed.")
                        if (r.returned or 0)>0 then
                            term.setCursorPos(1,4) term.write("Returned "..r.returned.." item(s) to vault")
                        end
                    else term.setTextColor(colors.red) term.write((r and r.err) or "Failed") end
                    term.setCursorPos(1,6) term.setTextColor(colors.gray) term.write("Press any key...")
                    os.pullEvent() needFetch=true
                end
            end
        elseif ev=="mouse_scroll" then
            scroll=math.max(0,math.min(scroll+p1,math.max(0,#listings-perPage)))
        elseif ev=="key" and p1==keys.q then return end
    end
end

-- ── Gambling UI ──────────────────────────────────────────────────────────────

local function createCoinflip()
    local bi=rpc({type="bank_info",token=token},5)
    local bal=(bi and bi.balance) or 0
    if bal<=0 then
        term.setBackgroundColor(colors.black) term.clear()
        term.setCursorPos(1,3) term.setTextColor(colors.red) term.write("No bank balance!")
        term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
        os.pullEvent() return
    end
    local wager=amountPicker({
        title="Create Coinflip",
        headerColor=colors.pink,
        unit="sp",
        available=bal,
        hint="Winner gets ~90% of the pot",
    })
    if not wager then return end
    local pot=wager*2
    local houseCut=math.max(1,math.floor(pot*0.10))
    local prize=pot-houseCut
    W,H=term.getSize()
    term.setBackgroundColor(colors.black) term.clear()
    term.setBackgroundColor(colors.pink) term.setTextColor(colors.black)
    term.setCursorPos(1,1) term.clearLine() term.write(" Create Coinflip")
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2,3) term.setTextColor(colors.white) term.write("Wager: "..wager.." sp each")
    term.setCursorPos(2,4) term.setTextColor(colors.gray)  term.write("Pot:   "..pot.." sp if joined")
    term.setCursorPos(2,5) term.setTextColor(colors.lime)  term.write("Prize: ~"..prize.." sp if you win")
    term.setCursorPos(2,6) term.setTextColor(colors.orange)term.write("House: "..houseCut.." sp (10% cut)")
    term.setCursorPos(2,8) term.setTextColor(colors.cyan)  term.write("Wager deducted now.")
    term.setCursorPos(2,9) term.setTextColor(colors.cyan)  term.write("Cancel anytime if nobody joins.")
    term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
    term.setBackgroundColor(colors.white) term.setTextColor(colors.black) term.write(" Create ")
    term.setBackgroundColor(colors.black) term.write("  ")
    term.setBackgroundColor(colors.red) term.setTextColor(colors.white) term.write(" Cancel ")
    term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
    while true do
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="mouse_click" then
            if p3==1 and p2>=W-2 then return end
            if p3==H-1 then
                if p2>=1 and p2<=8 then
                    local r=rpc({type="coinflip_create",token=token,wager=wager},10)
                    term.setBackgroundColor(colors.black) term.clear()
                    term.setCursorPos(1,3)
                    if r and r.ok then
                        term.setTextColor(colors.lime) term.write("Coinflip #"..r.id.." created!")
                        term.setCursorPos(1,4) term.setTextColor(colors.gray) term.write("Wager: "..r.wager.." sp deducted")
                        term.setCursorPos(1,5) term.setTextColor(colors.cyan) term.write("Waiting for someone to join...")
                    else
                        term.setTextColor(colors.red) term.write((r and r.err) or "Failed")
                    end
                    term.setCursorPos(1,7) term.setTextColor(colors.gray) term.write("Press any key...")
                    os.pullEvent() return
                elseif p2>=11 then return end
            end
        elseif ev=="key" and p1==keys.q then return end
    end
end

local function openCoinflips()
    local flips={} local scroll=0 local needFetch=true local bal=0
    while true do
        if needFetch then
            local r=rpc({type="coinflip_list",token=token},8)
            flips=(r and r.flips) or {}
            local bi=rpc({type="bank_info",token=token},5)
            bal=(bi and bi.balance) or 0
            scroll=0 needFetch=false
        end
        W,H=term.getSize()
        local listH=H-3
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.pink) term.setTextColor(colors.black)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" Open Coinflips ["..#flips.."]"..string.rep(" ",math.max(0,W-20)).."[X]")
        for row=1,listH do
            local f=flips[row+scroll]
            term.setCursorPos(1,row+1) term.setBackgroundColor(colors.black)
            if f then
                local pot2=f.wager*2
                local prize2=pot2-math.max(1,math.floor(pot2*0.10))
                local prizeStr=" ~"..prize2.."sp"
                local left="#"..f.id.." "..f.wager.."sp by "..f.creator
                local canAfford = f.wager <= bal
                term.setTextColor(canAfford and colors.yellow or colors.gray)
                term.write(left:sub(1,W-#prizeStr-1))
                term.setTextColor(canAfford and colors.lime or colors.gray)
                term.write(string.rep(" ",math.max(1,W-#left-#prizeStr))..prizeStr)
            else term.write(string.rep(" ",W)) end
        end
        if scroll>0 then term.setCursorPos(W,2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
        if scroll+listH<#flips then term.setCursorPos(W,H-1) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.orange) term.write(" < Back ")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.gray) term.write("  R=refresh  Click to join")
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return end
            if my==H-1 and mx<=8 then return end
            local idx=my-1+scroll
            local f=flips[idx]
            if f then
                if f.wager > bal then
                    -- flash a brief "can't afford" message in the footer
                    term.setCursorPos(1,H) term.setBackgroundColor(colors.black)
                    term.setTextColor(colors.red)
                    term.write(("Need "..f.wager.."sp, you have "..bal.."sp"):sub(1,W))
                    sleep(1.5)
                else
                local pot2=f.wager*2
                local houseCut2=math.max(1,math.floor(pot2*0.10))
                local prize2=pot2-houseCut2
                W,H=term.getSize()
                term.setBackgroundColor(colors.black) term.clear()
                term.setBackgroundColor(colors.pink) term.setTextColor(colors.black)
                term.setCursorPos(1,1) term.clearLine() term.write(" Join Coinflip #"..f.id)
                term.setBackgroundColor(colors.black)
                term.setCursorPos(2,3) term.setTextColor(colors.gray)   term.write("By: "..f.creator)
                term.setCursorPos(2,4) term.setTextColor(colors.white)  term.write("Wager:  "..f.wager.." sp each")
                term.setCursorPos(2,5) term.setTextColor(colors.lime)   term.write("Winner: ~"..prize2.." sp")
                term.setCursorPos(2,6) term.setTextColor(colors.orange) term.write("House:  "..houseCut2.." sp")
                term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
                term.setBackgroundColor(colors.white) term.setTextColor(colors.black) term.write(" Flip! ")
                term.setBackgroundColor(colors.black) term.write("  ")
                term.setBackgroundColor(colors.red) term.setTextColor(colors.white) term.write(" Back ")
                term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
                local confirmed=false
                while true do
                    local bev,bp1,bp2,bp3=os.pullEvent()
                    if bev=="mouse_click" then
                        if bp3==1 and bp2>=W-2 then break end
                        if bp3==H-1 then
                            if bp2>=1 and bp2<=7 then confirmed=true break
                            elseif bp2>=10 then break end
                        end
                    elseif bev=="key" and bp1==keys.q then break end
                end
                if confirmed then
                    local r=rpc({type="coinflip_join",token=token,flip_id=f.id},15)
                    -- Coin flip animation (result already known, just looks good)
                    W,H=term.getSize()
                    term.setBackgroundColor(colors.black) term.clear()
                    term.setBackgroundColor(colors.pink) term.setTextColor(colors.black)
                    term.setCursorPos(1,1) term.clearLine() term.write(" Flipping...")
                    term.setBackgroundColor(colors.black)
                    local sides={"( HEADS )","( TAILS )"}
                    local delays={0.07,0.07,0.09,0.11,0.14,0.18,0.24,0.32}
                    local cy=math.floor(H/2)
                    for i,d in ipairs(delays) do
                        term.setCursorPos(1,cy) term.clearLine()
                        local s=sides[(i%2)+1]
                        term.setTextColor(i%2==0 and colors.yellow or colors.cyan)
                        term.setCursorPos(math.max(1,math.floor((W-#s)/2)+1),cy) term.write(s)
                        sleep(d)
                    end
                    sleep(0.25)
                    -- Result
                    term.setBackgroundColor(colors.black) term.clear()
                    term.setBackgroundColor(colors.pink) term.setTextColor(colors.black)
                    term.setCursorPos(1,1) term.clearLine() term.write(" Result")
                    term.setBackgroundColor(colors.black)
                    if r and r.ok then
                        if r.you_won then
                            local wt="YOU WIN!"
                            term.setCursorPos(math.max(1,math.floor((W-#wt)/2)+1),cy-1)
                            term.setTextColor(colors.yellow) term.write(wt)
                            term.setCursorPos(2,cy+1) term.setTextColor(colors.lime)
                            term.write("+"..r.prize.." sp")
                            term.setCursorPos(2,cy+2) term.setTextColor(colors.gray)
                            term.write("Balance: "..r.new_balance.." sp")
                        else
                            local lt="YOU LOSE"
                            term.setCursorPos(math.max(1,math.floor((W-#lt)/2)+1),cy-1)
                            term.setTextColor(colors.red) term.write(lt)
                            term.setCursorPos(2,cy+1) term.setTextColor(colors.orange)
                            term.write(r.winner.." won "..r.prize.." sp")
                            term.setCursorPos(2,cy+2) term.setTextColor(colors.gray)
                            term.write("Balance: "..r.new_balance.." sp")
                        end
                    else
                        term.setCursorPos(2,5) term.setTextColor(colors.red)
                        term.write((r and r.err) or "Failed")
                    end
                    term.setCursorPos(2,H-1) term.setTextColor(colors.gray) term.write("Press any key...")
                    os.pullEvent() needFetch=true
                end
                end -- canAfford
            end
        elseif ev=="mouse_scroll" then
            scroll=math.max(0,math.min(scroll+p1,math.max(0,#flips-listH)))
        elseif ev=="key" then
            if p1==keys.q then return
            elseif p1==keys.r then needFetch=true end
        end
    end
end

local function myBets()
    local bets={} local scroll=0 local needFetch=true
    while true do
        if needFetch then
            local r=rpc({type="coinflip_my_bets",token=token},8)
            bets=(r and r.bets) or {}
            scroll=0 needFetch=false
        end
        W,H=term.getSize()
        local listH=H-3
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.yellow) term.setTextColor(colors.black)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" My Active Bets ["..#bets.."]"..string.rep(" ",math.max(0,W-21)).."[X]")
        for row=1,listH do
            local f=bets[row+scroll]
            term.setCursorPos(1,row+1) term.setBackgroundColor(colors.black)
            if f then
                term.setTextColor(colors.yellow) term.write(("#"..f.id.."  "):sub(1,5))
                term.setTextColor(colors.white)  term.write((f.wager.."sp  waiting for player..."):sub(1,W-5))
            else term.write(string.rep(" ",W)) end
        end
        if scroll>0 then term.setCursorPos(W,2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
        if scroll+listH<#bets then term.setCursorPos(W,H-1) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.orange) term.write(" < Back ")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.gray) term.write("  Click bet to cancel it")
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return end
            if my==H-1 and mx<=8 then return end
            local idx=my-1+scroll
            local f=bets[idx]
            if f then
                local r=rpc({type="coinflip_cancel",token=token,flip_id=f.id},10)
                term.setBackgroundColor(colors.black) term.clear()
                term.setCursorPos(1,3)
                if r and r.ok then
                    term.setTextColor(colors.lime) term.write("Bet cancelled!")
                    term.setCursorPos(1,4) term.setTextColor(colors.gray) term.write("Returned "..r.returned.." sp to balance")
                else
                    term.setTextColor(colors.red) term.write((r and r.err) or "Failed")
                end
                term.setCursorPos(1,6) term.setTextColor(colors.gray) term.write("Press any key...")
                os.pullEvent() needFetch=true
            end
        elseif ev=="mouse_scroll" then
            scroll=math.max(0,math.min(scroll+p1,math.max(0,#bets-listH)))
        elseif ev=="key" and p1==keys.q then return end
    end
end

local function minesGame()
    local bi=rpc({type="bank_info",token=token},5)
    local bal=(bi and bi.balance) or 0
    local wager=math.max(1,math.min(10,bal))
    local active_wager=wager  -- wager locked in when game starts
    local num_bombs=5
    local state="setup"
    local game_id=nil
    local grid={}; for i=1,25 do grid[i]="hidden" end
    local gems_found=0
    local cur_mult=1.0
    local cur_payout=0
    local result_msg="" local result_col=colors.white
    local err_msg="" local err_t=0
    local GRID_TOP=6

    local function xyToTile(mx,my)
        local gy=my-GRID_TOP
        if gy<0 or gy>4 then return nil end
        local gx_raw=mx-4
        if gx_raw<0 or gx_raw>18 then return nil end
        if gx_raw%4==3 then return nil end
        return gy*5+math.floor(gx_raw/4)+1
    end

    local function drawGrid()
        for row=0,4 do
            term.setCursorPos(4,GRID_TOP+row)
            for col=0,4 do
                local t=row*5+col+1
                local st=grid[t]
                if     st=="gem"  then term.setBackgroundColor(colors.lime)   term.setTextColor(colors.black) term.write(" * ")
                elseif st=="bomb" then term.setBackgroundColor(colors.red)    term.setTextColor(colors.white) term.write(" X ")
                elseif st=="safe" then term.setBackgroundColor(colors.orange) term.setTextColor(colors.black) term.write(" . ")
                else                   term.setBackgroundColor(colors.gray)   term.setTextColor(colors.black) term.write(" ? ")
                end
                if col<4 then term.setBackgroundColor(colors.black) term.write(" ") end
            end
        end
        term.setBackgroundColor(colors.black)
    end

    local function draw()
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.red) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" MINES"..string.rep(" ",W-9).."[X]")
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2,2) term.setTextColor(colors.gray) term.write("Bal: ")
        term.setTextColor(colors.yellow) term.write(bal.."sp")
        term.setCursorPos(2,3) term.setTextColor(colors.gray) term.write("Bet: ")
        term.setTextColor(colors.white) term.write(wager.."sp")
        if state=="setup" then
            term.setCursorPos(16,3) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write(" -1 ")
            term.setCursorPos(21,3) term.write(" +1 ")
            term.setBackgroundColor(colors.black)
            term.setCursorPos(2,4) term.setTextColor(colors.gray) term.write("Bombs: ")
            term.setTextColor(colors.white) term.write(num_bombs)
            term.setCursorPos(14,4) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write(" - ")
            term.setCursorPos(18,4) term.write(" + ")
            term.setBackgroundColor(colors.black)
        elseif state=="playing" then
            term.setCursorPos(2,4)
            term.setTextColor(colors.lime) term.write(string.format("%.2fx",cur_mult))
            term.setTextColor(colors.gray) term.write("  Gems: ")
            term.setTextColor(colors.white) term.write(gems_found.."/".. (25-num_bombs))
        else
            term.setCursorPos(2,4) term.setTextColor(result_col) term.write(result_msg:sub(1,W-2))
        end
        term.setCursorPos(1,5) term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
        term.write(string.rep("-",W))
        drawGrid()
        term.setCursorPos(1,12) term.setBackgroundColor(colors.black) term.clearLine()
        if state=="setup" then
            term.setCursorPos(2,12) term.setBackgroundColor(colors.green) term.setTextColor(colors.white)
            term.write(string.rep(" ",W-3))
            term.setCursorPos(math.floor((W-5)/2)+1,12) term.write("START")
            term.setBackgroundColor(colors.black)
        elseif state=="playing" then
            if gems_found>0 then
                local cs=" CASH OUT: "..cur_payout.."sp "
                term.setCursorPos(math.max(2,math.floor((W-#cs)/2)+1),12)
                term.setBackgroundColor(colors.yellow) term.setTextColor(colors.black) term.write(cs)
                term.setBackgroundColor(colors.black)
            else
                term.setCursorPos(2,12) term.setTextColor(colors.gray) term.write("Reveal a gem first")
            end
        else
            term.setCursorPos(2,12) term.setTextColor(colors.gray) term.write("Any key = new game")
        end
        if err_msg~="" and os.clock()<err_t then
            term.setCursorPos(2,14) term.setTextColor(colors.red) term.write(err_msg:sub(1,W-2))
        end
        term.setCursorPos(2,H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write(" Back ")
        term.setBackgroundColor(colors.black)
    end

    local function reset()
        for i=1,25 do grid[i]="hidden" end
        gems_found=0 cur_mult=1.0 cur_payout=0 result_msg="" game_id=nil state="setup"
    end

    while true do
        draw()
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return end
            if my==H and mx>=2 and mx<=7 then return end
            if state=="setup" then
                if my==3 and mx>=16 and mx<=19 then wager=math.max(1,wager-1) end
                if my==3 and mx>=21 and mx<=24 then wager=math.min(bal,wager+1) end
                if my==4 and mx>=14 and mx<=16 then num_bombs=math.max(5,num_bombs-1) end
                if my==4 and mx>=18 and mx<=20 then num_bombs=math.min(24,num_bombs+1) end
                if my==12 then
                    if bal<wager then err_msg="Not enough balance" err_t=os.clock()+2
                    else
                        local r=rpc({type="mines_start",token=token,wager=wager,bombs=num_bombs},8)
                    if r and r.ok then active_wager=wager end
                        if not r or not r.ok then err_msg=(r and r.err) or "Server error" err_t=os.clock()+3
                        else
                            game_id=r.game_id
                            for i=1,25 do grid[i]="hidden" end
                            gems_found=0 cur_mult=1.0 cur_payout=0
                            state="playing" bal=r.balance
                        end
                    end
                end
            elseif state=="playing" then
                if my==12 and gems_found>0 then
                    local r=rpc({type="mines_cashout",token=token,game_id=game_id},8)
                    if r and r.ok then
                        for _,bp in ipairs(r.bombs) do if grid[bp]=="hidden" then grid[bp]="safe" end end
                        result_msg=string.format("Cashed %.2fx = %dsp!",r.mult,r.payout)
                        result_col=colors.lime state="over" bal=r.new_balance
                    end
                end
                local tile=xyToTile(mx,my)
                if tile and grid[tile]=="hidden" then
                    local r=rpc({type="mines_reveal",token=token,game_id=game_id,tile=tile},8)
                    if r and r.ok then
                        if r.is_bomb then
                            grid[tile]="bomb"
                            for _,bp in ipairs(r.bombs) do if grid[bp]=="hidden" then grid[bp]="bomb" end end
                            result_msg="BOOM! Lost "..(active_wager or wager).."sp"
                            result_col=colors.red state="over"
                            local bi2=rpc({type="bank_info",token=token},5)
                            bal=(bi2 and bi2.balance) or bal
                        else
                            grid[tile]="gem" gems_found=r.gems
                            cur_mult=r.multiplier cur_payout=r.potential_payout
                            if r.all_found then
                                for _,bp in ipairs(r.bombs) do if grid[bp]=="hidden" then grid[bp]="safe" end end
                                result_msg=string.format("ALL GEMS! %.2fx = %dsp!",r.multiplier,r.potential_payout)
                                result_col=colors.cyan state="over" bal=r.new_balance
                            end
                        end
                    else err_msg=(r and r.err) or "Server error" err_t=os.clock()+2 end
                end
            elseif state=="over" then
                reset()
                local bi2=rpc({type="bank_info",token=token},5) bal=(bi2 and bi2.balance) or bal
            end
        elseif ev=="mouse_scroll" then
            if state=="setup" then
                if p3==4 then num_bombs=math.max(5,math.min(24,num_bombs-p1))
                else wager=math.max(1,math.min(bal,wager-p1)) end
            end
        elseif ev=="key" then
            if p1==keys.q then return end
            if state=="over" then
                reset()
                local bi2=rpc({type="bank_info",token=token},5) bal=(bi2 and bi2.balance) or bal
            end
        end
    end
end

local function slotsGame()
    local SYMS = {
        {label=" LEM  ", color=colors.yellow  },  -- 1 loss
        {label=" GRP  ", color=colors.purple  },  -- 2 loss
        {label=" ORG  ", color=colors.orange  },  -- 3 loss
        {label=" CHR  ", color=colors.red     },  -- 4 win 2x
        {label=" BAR  ", color=colors.lightBlue}, -- 5 win 5x
        {label="  7   ", color=colors.cyan    },  -- 6 win 10x jackpot
    }
    local bi = rpc({type="bank_info",token=token},5)
    local bal = (bi and bi.balance) or 0
    local wager = math.max(1, math.min(10, bal))
    local reels = {1,2,3}
    local lastMsg, lastColor = nil, colors.white

    local function drawReels(r)
        local xs = {3,11,19}
        for i=1,3 do
            local sym=SYMS[r[i]]
            for row=6,8 do
                term.setCursorPos(xs[i],row)
                term.setBackgroundColor(sym.color) term.setTextColor(colors.black)
                if row==7 then term.write(sym.label) else term.write("      ") end
            end
        end
        term.setBackgroundColor(colors.black)
    end

    local function animateSpin(final)
        for _=1,15 do
            reels[1]=math.random(6) reels[2]=math.random(6) reels[3]=math.random(6)
            drawReels(reels) sleep(0.05)
        end
        reels[1]=final[1] drawReels(reels) sleep(0.1)
        for _=1,8 do reels[2]=math.random(6) reels[3]=math.random(6) drawReels(reels) sleep(0.07) end
        reels[2]=final[2] drawReels(reels) sleep(0.1)
        for _=1,6 do reels[3]=math.random(6) drawReels(reels) sleep(0.09) end
        reels[3]=final[3] drawReels(reels) sleep(0.3)
    end

    local function draw()
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.pink) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" SLOTS"..string.rep(" ",W-9).."[X]")
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2,2) term.setTextColor(colors.gray) term.write("Bal: ")
        term.setTextColor(colors.yellow) term.write(bal.."sp")
        term.setCursorPos(2,4) term.setTextColor(colors.gray) term.write("Bet: ")
        term.setTextColor(colors.white) term.write(wager.."sp")
        term.setCursorPos(16,4) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write(" -1 ")
        term.setCursorPos(21,4) term.write(" +1 ")
        term.setBackgroundColor(colors.black)
        drawReels(reels)
        if lastMsg then
            term.setCursorPos(math.max(1,math.floor((W-#lastMsg)/2)+1),10)
            term.setTextColor(lastColor) term.write(lastMsg)
        end
        term.setCursorPos(2,12) term.setBackgroundColor(colors.green) term.setTextColor(colors.white)
        term.write(string.rep(" ",W-3))
        term.setCursorPos(math.floor((W-4)/2)+1,12) term.write("SPIN")
        term.setBackgroundColor(colors.black)
        local function payRow(y, symColor, symTxt, mult)
            local payout = wager * mult .. "sp"
            term.setCursorPos(2,y)
            term.setBackgroundColor(symColor) term.setTextColor(colors.black)
            term.write(symTxt)
            term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
            term.write(" "..symTxt.." "..symTxt.." = ")
            term.setTextColor(colors.white) term.write(payout)
        end
        payRow(14, colors.cyan,      "  7 ", 10)
        payRow(15, colors.lightBlue, " BAR", 5 )
        payRow(16, colors.red,       " CHR", 2 )
        term.setCursorPos(2,H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write(" Back ")
        term.setBackgroundColor(colors.black)
    end

    while true do
        draw()
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return end
            if my==H and mx>=2 and mx<=7 then return end
            if my==4 and mx>=16 and mx<=19 then wager=math.max(1,wager-1) lastMsg=nil end
            if my==4 and mx>=21 and mx<=24 then wager=math.min(bal,wager+1) lastMsg=nil end
            if my==12 then
                if bal<wager then lastMsg="Not enough balance!" lastColor=colors.red
                else
                    local r=rpc({type="slots_spin",token=token,wager=wager},8)
                    if not r or not r.ok then
                        lastMsg=(r and r.err) or "Server error" lastColor=colors.red
                    else
                        local final
                        if     r.outcome=="jackpot" then final={6,6,6}
                        elseif r.outcome=="bigwin"  then final={5,5,5}
                        elseif r.outcome=="win"     then final={4,4,4}
                        else
                            local l1=math.random(3); local l2
                            repeat l2=math.random(3) until l2~=l1
                            final={l1, l2, math.random(3)}
                        end
                        animateSpin(final)
                        bal=r.balance
                        if     r.outcome=="loss"    then lastMsg="No match. -"..r.wager.."sp"         lastColor=colors.red
                        elseif r.outcome=="win"     then lastMsg="MATCH! 2x +"..r.prize-r.wager.."sp" lastColor=colors.lime
                        elseif r.outcome=="bigwin"  then lastMsg="BIG WIN! 5x +"..r.prize-r.wager.."sp" lastColor=colors.yellow
                        elseif r.outcome=="jackpot" then lastMsg="JACKPOT!! 10x +"..r.prize-r.wager.."sp" lastColor=colors.cyan
                        end
                    end
                end
            end
        elseif ev=="mouse_scroll" then wager=math.max(1,math.min(bal,wager-p1)) lastMsg=nil
        elseif ev=="key" and p1==keys.q then return end
    end
end

local function coinflipMenu()
    local menuItems={
        {label="Open Coinflips", icon=colors.cyan  },
        {label="Create Coinflip",icon=colors.green },
        {label="My Active Bets", icon=colors.yellow},
        {label="Back",           icon=colors.gray  },
    }
    while true do
        local sel=clickMenu("Coinflip",menuItems)
        if sel==nil or sel==4 then return
        elseif sel==1 then openCoinflips()
        elseif sel==2 then createCoinflip()
        elseif sel==3 then myBets()
        end
    end
end

local function leaderboardScreen()
    local data=nil
    local function fetch()
        local r=rpc({type="get_leaderboard",token=token},8)
        if r and r.ok then data=r else data=nil end
    end
    fetch()
    while true do
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.purple) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" Leaderboard - Wealthiest")
        term.setBackgroundColor(colors.black)
        if not data then
            term.setCursorPos(2,4) term.setTextColor(colors.red) term.write("Failed to load")
        else
            local list = data.wealth or {}
            local labels={"#1","#2","#3","#4","#5","#6","#7","#8","#9","#10"}
            term.setCursorPos(2,3) term.setTextColor(colors.gray)
            term.write(string.format("%-4s %-14s %s","#","Player","Balance"))
            for i,entry in ipairs(list) do
                local y=3+i
                term.setCursorPos(2,y)
                local rankCol = i==1 and colors.yellow or i==2 and colors.lightGray or i==3 and colors.orange or colors.white
                term.setTextColor(rankCol) term.write(string.format("%-4s",labels[i]))
                term.setTextColor(colors.white) term.write(string.format("%-14s",entry.name:sub(1,13)))
                term.setTextColor(colors.lime) term.write(entry.value.."sp")
            end
            if #list==0 then
                term.setCursorPos(2,5) term.setTextColor(colors.gray) term.write("No data yet")
            end
        end
        term.setCursorPos(1,H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
        term.clearLine() term.write(" Back  [R]efresh")
        term.setBackgroundColor(colors.black)
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="mouse_click" then
            if p3==H and p2>=2 and p2<=5 then return end
        elseif ev=="key" then
            if p1==keys.q or p1==keys.backspace then return end
            if p1==keys.r then fetch() end
        end
    end
end

local function gamblingLeaderboard()
    local tabs={"Most Won","Most Lost"}
    local tab=1
    local data=nil
    local function fetch()
        local r=rpc({type="get_leaderboard",token=token},8)
        if r and r.ok then data=r else data=nil end
    end
    fetch()
    while true do
        W,H=term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.purple) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" Gambling Leaderboard")
        local tx=1
        for i,label in ipairs(tabs) do
            if i==tab then
                term.setBackgroundColor(colors.white) term.setTextColor(colors.black)
            else
                term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
            end
            term.setCursorPos(tx,2) term.write(" "..label:sub(1,8).." ")
            tx=tx+#label:sub(1,8)+2
        end
        term.setBackgroundColor(colors.black)
        if not data then
            term.setCursorPos(2,4) term.setTextColor(colors.red) term.write("Failed to load")
        else
            local list = tab==1 and (data.won or {}) or (data.lost or {})
            local labels={"#1","#2","#3","#4","#5","#6","#7","#8","#9","#10"}
            local valLabel = tab==1 and "won" or "lost"
            term.setCursorPos(2,3) term.setTextColor(colors.gray)
            term.write(string.format("%-4s %-14s %s","#","Player","Amount"))
            for i,entry in ipairs(list) do
                local y=3+i
                term.setCursorPos(2,y)
                local rankCol = i==1 and colors.yellow or i==2 and colors.lightGray or i==3 and colors.orange or colors.white
                term.setTextColor(rankCol) term.write(string.format("%-4s",labels[i]))
                term.setTextColor(colors.white) term.write(string.format("%-14s",entry.name:sub(1,13)))
                term.setTextColor(tab==1 and colors.lime or colors.red) term.write(entry.value.."sp")
            end
            if #list==0 then
                term.setCursorPos(2,5) term.setTextColor(colors.gray) term.write("No data yet")
            end
        end
        term.setCursorPos(1,H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
        term.clearLine() term.write(" Back  [R]efresh")
        term.setBackgroundColor(colors.black)
        local ev,p1,p2,p3=os.pullEvent()
        if ev=="mouse_click" then
            if p3==H and p2>=2 and p2<=5 then return end
            if p3==2 then
                local tx2=1
                for i,label in ipairs(tabs) do
                    local w=#label:sub(1,8)+2
                    if p2>=tx2 and p2<tx2+w then tab=i break end
                    tx2=tx2+w
                end
            end
        elseif ev=="key" then
            if p1==keys.q or p1==keys.backspace then return end
            if p1==keys.r then fetch() end
            if p1==keys.right or p1==keys.d then tab=tab%2+1 end
            if p1==keys.left  or p1==keys.a then tab=(tab-2)%2+1 end
        end
    end
end

local function gamblingMenu()
    local menuItems={
        {label="Coinflip",    icon=colors.pink  },
        {label="Mines",       icon=colors.red   },
        {label="Slots",       icon=colors.yellow},
        {label="Leaderboard", icon=colors.cyan  },
        {label="Back",        icon=colors.gray  },
    }
    while true do
        local sel=clickMenu("Gambling",menuItems)
        if sel==nil or sel==5 then return
        elseif sel==1 then coinflipMenu()
        elseif sel==2 then minesGame()
        elseif sel==3 then slotsGame()
        elseif sel==4 then gamblingLeaderboard()
        end
    end
end

-- Market hub
local function marketMenu()
    local menuItems={
        {label="Browse Market", icon=colors.cyan  },
        {label="Add Listing",   icon=colors.green },
        {label="My Listings",   icon=colors.yellow},
        {label="Back",          icon=colors.gray  },
    }
    while true do
        local sel=clickMenu("Market",menuItems)
        if sel==nil or sel==4 then return
        elseif sel==1 then marketBrowse()
        elseif sel==2 then marketAddListing()
        elseif sel==3 then marketMyListings()
        end
    end
end

-- Cloud Storage submenu (vault withdraw, deposit, transaction log)
local function cloudStorageMenu()
    local items={
        {label="Withdraw", icon=colors.green},
        {label="Deposit",  icon=colors.blue},
        {label="Log",      icon=colors.gray},
        {label="Back",     icon=colors.red},
    }
    while true do
        local sel=clickMenu("Cloud Storage",items)
        if sel==nil or sel==4 then return
        elseif sel==1 then
            itemListUI({title="Withdraw",actionLabel="Withdrew",
                fetchFn=function() local r=rpc({type="list_vault",token=token}) return r or {} end,
                actionFn=function(item,amt)
                    local r=rpc({type="withdraw",token=token,name=item.name,displayName=item.displayName,count=amt},10)
                    return r and r.ok, r and r.err end})
        elseif sel==2 then
            itemListUI({title="Deposit",actionLabel="Deposited",
                fetchFn=function() local r=rpc({type="list_inventory",token=token}) return r or {} end,
                actionFn=function(item,amt)
                    local r=rpc({type="deposit",token=token,name=item.name,displayName=item.displayName,count=amt},10)
                    return r and r.ok, r and r.err end})
        elseif sel==3 then
            logScreen()
        end
    end
end

-- ── Notifications UI ─────────────────────────────────────────────────────────

local function notificationsScreen()
    local res = rpc({type="get_notifications", token=token}, 8)
    local notifs = (res and res.notifications) or {}
    local scroll = 0

    local function wordWrap(text, width)
        local lines = {}
        local line = ""
        for word in (text.." "):gmatch("(%S+)%s+") do
            if #line == 0 then
                line = word
            elseif #line + 1 + #word <= width then
                line = line .. " " .. word
            else
                table.insert(lines, line)
                line = "  " .. word  -- indent continuation
            end
        end
        if #line > 0 then table.insert(lines, line) end
        if #lines == 0 then table.insert(lines, "") end
        return lines
    end

    local function buildLines()
        local out = {}
        for i = 1, #notifs do
            local n = notifs[i]
            local txt = n.text or ""
            local wrapped = wordWrap(txt, W - 1)
            for j, ln in ipairs(wrapped) do
                table.insert(out, { text=ln, color=j==1 and colors.white or colors.lightGray })
            end
            table.insert(out, { text="", color=colors.black })
        end
        if #out == 0 then
            table.insert(out, { text=" No notifications yet.", color=colors.white })
        end
        return out
    end

    while true do
        W, H = term.getSize()
        local listH = H - 3
        local lines = buildLines()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.purple) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        local hdr = " Notifications ["..#notifs.."]"
        term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
        for row = 1, listH do
            local ln = lines[row + scroll]
            term.setCursorPos(1, row+1) term.setBackgroundColor(colors.black)
            if ln then
                term.setTextColor(ln.color)
                term.write(ln.text..string.rep(" ", math.max(0, W-#ln.text)))
            else
                term.setTextColor(colors.black) term.write(string.rep(" ",W))
            end
        end
        if scroll > 0 then
            term.setCursorPos(W,2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^")
        end
        if scroll + listH < #lines then
            term.setCursorPos(W,H-1) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v")
        end
        term.setCursorPos(1,H-1) term.setBackgroundColor(colors.black) term.clearLine()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white) term.write(" < Back ")
        term.setBackgroundColor(colors.black) term.setTextColor(colors.gray) term.write("  Q=back")
        term.setCursorPos(1,H) term.setBackgroundColor(colors.black) term.write(string.rep(" ",W))
        local ev,p1,p2,p3 = os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if (my==1 and mx>=W-2) or (my==H-1 and mx<=8) then return end
        elseif ev=="mouse_scroll" then
            scroll = math.max(0, math.min(scroll+p1, math.max(0, #lines-listH)))
        elseif ev=="key" then
            if p1==keys.q then return end
        end
    end
end

-- ── Subscriptions UI ─────────────────────────────────────────────────────────

local function checkAndDeliverFood()
    if not token then return end
    if not foodSubCache or not foodSubCache.food_sub then return end
    local fsub = foodSubCache.food_sub
    if (fsub.remaining_today or 0) <= 0 then return end
    local r = rpc({type="auto_food_deliver", token=token, item=fsub.item}, 10)
    if r and (r.delivered or 0) > 0 then
        fsub.remaining_today = r.remaining or math.max(0, (fsub.remaining_today or 0) - r.delivered)
    end
end

local function showAutoFood()
    local subRes = rpc({type="subscription_status", token=token}, 5)
    if not subRes or not subRes.ok then
        term.setBackgroundColor(colors.black) term.clear()
        term.setCursorPos(2,3) term.setTextColor(colors.red)
        term.write((subRes and subRes.err) or "Error fetching status")
        term.setCursorPos(2,5) term.setTextColor(colors.gray) term.write("Press any key...")
        os.pullEvent() return
    end
    if subRes and subRes.ok then foodSubCache=subRes; foodSubCacheTs=os.epoch("utc") end

    local foodsRes = rpc({type="subscription_food_items", token=token}, 5)
    local foods = (foodsRes and foodsRes.items) or {}
    if #foods == 0 then
        foods = {{id="createfood:breakfast_plate", display_name="Breakfast Plate", stack_size=16}}
    end

    local selFood = 1
    local selPlan = nil  -- nil=main view, "basic"/"premium"=plan detail
    local msg="" local msgTimer=0

    local function pickFoodUI(currentId)
        local sel = 1
        for i, f in ipairs(foods) do if f.id == currentId then sel=i break end end
        while true do
            W,H = term.getSize()
            term.setBackgroundColor(colors.black) term.clear()
            term.setBackgroundColor(colors.lime) term.setTextColor(colors.white)
            term.setCursorPos(1,1) term.clearLine()
            local hdr = " Change Food"
            term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
            term.setBackgroundColor(colors.black)
            for i, f in ipairs(foods) do
                term.setCursorPos(1, i+2)
                if i==sel then
                    term.setBackgroundColor(colors.lime) term.setTextColor(colors.black)
                else
                    term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
                end
                term.write(" ")
                term.setBackgroundColor(colors.black)
                term.setTextColor(i==sel and colors.lime or colors.white)
                term.write((" "..f.display_name):sub(1,W-1))
            end
            term.setCursorPos(1,H) term.setBackgroundColor(colors.black)
            term.setTextColor(colors.gray) term.write("Click to select  Q=cancel")
            local ev,p1,p2,p3 = os.pullEvent()
            if ev=="mouse_click" then
                local mx,my=p2,p3
                if my==1 and mx>=W-2 then return nil end
                local idx=my-2
                if idx>=1 and idx<=#foods then return foods[idx] end
            elseif ev=="key" and p1==keys.q then return nil end
        end
    end

    while true do
        local sub = foodSubCache and foodSubCache.food_sub
        local food = foods[selFood]
        local ss = food and food.stack_size or 16
        W,H = term.getSize()
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.lime) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        local hdr = sub and " Auto Food  (Active)" or " Auto Food"
        term.write(hdr..string.rep(" ",math.max(0,W-#hdr-3)).."[X]")
        term.setBackgroundColor(colors.black)

        if sub then
            local planL = (sub.plan or ""):sub(1,1):upper()..(sub.plan or ""):sub(2)
            term.setCursorPos(2,3) term.setTextColor(colors.gray)
            term.write(("Plan: "..planL.."  "..sub.cost_per_day.."sp/day"):sub(1,W-2))
            term.setCursorPos(2,4) term.setTextColor(colors.white)
            term.write((sub.display_name or "Food"):sub(1,W-2))
            local rem = sub.remaining_today or 0
            local tot = math.max(1, sub.daily_allowance or 1)
            local subSS = sub.stack_size or 16
            local remStacks = math.floor(rem/subSS)
            local totStacks = math.floor(tot/subSS)
            term.setCursorPos(2,5) term.setTextColor(colors.yellow)
            term.write(("Today: "..remStacks.."/"..totStacks.." stacks"):sub(1,W-2))
            term.setCursorPos(2,6) term.setTextColor(colors.gray)
            term.write(("  ("..rem.." items)"):sub(1,W-2))
            local bw=W-4
            local fill=math.max(0,math.floor(rem/tot*bw))
            term.setCursorPos(3,7)
            term.setBackgroundColor(colors.lime) term.write(string.rep(" ",fill))
            term.setBackgroundColor(colors.gray) term.write(string.rep(" ",bw-fill))
            term.setBackgroundColor(colors.black)
            local hs=math.floor(subSS/2)
            term.setCursorPos(2,8) term.setTextColor(colors.gray)
            term.write(("Refills when <"..hs.." in inv"):sub(1,W-2))
            term.setCursorPos(1,10)
            term.setBackgroundColor(colors.blue) term.setTextColor(colors.white)
            term.write(" Change Food ")
            term.setBackgroundColor(colors.black) term.write(string.rep(" ",math.max(0,W-13)))
            term.setCursorPos(1,11)
            term.setBackgroundColor(colors.red) term.setTextColor(colors.white)
            term.write(" Cancel Subscription ")
            term.setBackgroundColor(colors.black) term.write(string.rep(" ",math.max(0,W-21)))
            term.setCursorPos(1,12)
            term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
            term.write(" Back ")
            term.setBackgroundColor(colors.black) term.write(string.rep(" ",math.max(0,W-6)))
        elseif selPlan then
            -- Plan detail / confirm screen
            local pi = selPlan=="basic" and {stacks=3,cost=5} or {stacks=6,cost=10}
            local planL = selPlan:sub(1,1):upper()..selPlan:sub(2)
            local food = foods[selFood]
            local fss = food and food.stack_size or 16
            term.setCursorPos(2,3) term.setTextColor(colors.yellow)
            term.write((planL.."  "..pi.cost.."sp/day"):sub(1,W-2))
            term.setCursorPos(2,4) term.setTextColor(colors.white)
            term.write((food and food.display_name or "?"):sub(1,W-2))
            term.setCursorPos(2,5) term.setTextColor(colors.gray)
            term.write((pi.stacks.." stacks/day"):sub(1,W-2))
            term.setCursorPos(2,6) term.setTextColor(colors.gray)
            term.write(("  ("..pi.stacks*fss.." items)"):sub(1,W-2))
            term.setCursorPos(1,8)
            term.setBackgroundColor(colors.green) term.setTextColor(colors.black)
            term.write(" Subscribe ")
            term.setBackgroundColor(colors.black) term.write(string.rep(" ",math.max(0,W-11)))
            term.setCursorPos(1,9)
            term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
            term.write(" Back ")
            term.setBackgroundColor(colors.black) term.write(string.rep(" ",math.max(0,W-6)))
        else
            term.setCursorPos(2,3) term.setTextColor(colors.gray) term.write("Food:")
            for i, f in ipairs(foods) do
                local row = 3 + i
                term.setCursorPos(1, row)
                if i == selFood then
                    term.setBackgroundColor(colors.lime) term.setTextColor(colors.black)
                else
                    term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
                end
                term.write(" ")
                term.setBackgroundColor(colors.black)
                term.setTextColor(i==selFood and colors.lime or colors.white)
                term.write((" "..f.display_name):sub(1,W-1))
            end
            local planRow = 3 + #foods + 2
            term.setCursorPos(1, planRow)
            term.setBackgroundColor(colors.green) term.setTextColor(colors.black) term.write(" ")
            term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
            term.write((" Basic  5sp/day"):sub(1,W-1))
            term.setCursorPos(1, planRow+1) term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
            term.write(("  3 stacks/day"):sub(1,W))
            term.setCursorPos(1, planRow+3)
            term.setBackgroundColor(colors.cyan) term.setTextColor(colors.black) term.write(" ")
            term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
            term.write((" Premium 10sp/day"):sub(1,W-1))
            term.setCursorPos(1, planRow+4) term.setBackgroundColor(colors.black) term.setTextColor(colors.gray)
            term.write(("  6 stacks/day"):sub(1,W))
            local backRow = planRow + 6
            term.setCursorPos(1, backRow)
            term.setBackgroundColor(colors.gray) term.setTextColor(colors.white)
            term.write(" Back ")
            term.setBackgroundColor(colors.black) term.write(string.rep(" ",math.max(0,W-6)))
        end

        term.setCursorPos(1,H) term.setBackgroundColor(colors.black)
        if msg~="" and os.clock()<msgTimer then
            term.setTextColor(colors.lime) term.write(msg:sub(1,W))
        else msg=""; term.setTextColor(colors.gray) term.write("Q=back") end

        local ev,p1,p2,p3 = os.pullEvent()
        if ev=="term_resize" then W,H=term.getSize()
        elseif ev=="mouse_click" then
            local mx,my=p2,p3
            if my==1 and mx>=W-2 then return end
            if sub then
                if my==10 then
                    local newFood = pickFoodUI(sub.item)
                    if newFood and newFood.id ~= sub.item then
                        local planName = sub.plan
                        local r1=rpc({type="subscription_cancel",token=token},8)
                        if r1 and r1.ok then
                            local r2=rpc({type="subscription_create",token=token,plan=planName,item=newFood.id},8)
                            if r2 and r2.ok then
                                foodSubCache={ok=true,food_sub=r2.food_sub}; foodSubCacheTs=os.epoch("utc")
                                msg="Food changed!" msgTimer=os.clock()+3
                            else msg=(r2 and r2.err) or "Failed" msgTimer=os.clock()+3 end
                        else msg=(r1 and r1.err) or "Failed" msgTimer=os.clock()+3 end
                    end
                elseif my==11 then
                    local r=rpc({type="subscription_cancel",token=token},8)
                    if r and r.ok then
                        foodSubCache={ok=true,food_sub=nil}; foodSubCacheTs=os.epoch("utc")
                        msg="Subscription cancelled" msgTimer=os.clock()+3
                    else msg=(r and r.err) or "Failed" msgTimer=os.clock()+3 end
                elseif my==12 then return end
            elseif selPlan then
                local function doSubscribe(plan)
                    local f = foods[selFood]
                    if not f then msg="Select a food first" msgTimer=os.clock()+2 return end
                    local r=rpc({type="subscription_create",token=token,plan=plan,item=f.id},8)
                    if r and r.ok then
                        foodSubCache={ok=true,food_sub=r.food_sub}; foodSubCacheTs=os.epoch("utc")
                        selPlan=nil
                        msg="Subscribed! Balance: "..(r.balance or "?").."sp" msgTimer=os.clock()+4
                    else msg=(r and r.err) or "Failed" msgTimer=os.clock()+3 end
                end
                if my==8 then doSubscribe(selPlan)
                elseif my==9 then selPlan=nil end
            else
                for i=1,#foods do
                    if my == 3+i then selFood=i end
                end
                local planRow = 3 + #foods + 2
                if my==planRow then selPlan="basic"
                elseif my==planRow+3 then selPlan="premium"
                elseif my==planRow+6 then return end
            end
        elseif ev=="key" and p1==keys.q then
            if selPlan then selPlan=nil else return end
        end
    end
end

local function subscriptionsMenu()
    while true do
        local hasFoodSub = foodSubCache and foodSubCache.food_sub
        local foodLabel
        if hasFoodSub then
            local fsub = foodSubCache.food_sub
            local rem = fsub.remaining_today or 0
            local ss = fsub.stack_size or 16
            foodLabel = "Auto Food ("..math.floor(rem/ss).." stacks)"
        else
            foodLabel = "Auto Food"
        end
        local items = {
            {label=foodLabel, icon=hasFoodSub and colors.lime or colors.gray},
            {label="Back",    icon=colors.red},
        }
        local sel = clickMenu("Subscriptions", items)
        if sel==nil or sel==2 then return
        elseif sel==1 then showAutoFood() end
    end
end

-- User menu
local function userMenu()
    while true do
        if needsRelogin then needsRelogin = false doLogin() end
        local ncRes = rpc({type="get_notif_count", token=token}, 5)
        -- Se não conseguiu pegar notificações por erro de rede, mostra aviso mas não desloga
        local unreadCount
        if ncRes == nil then
            unreadCount = unreadNotifs  -- mantém o último valor conhecido
        else
            unreadCount = ncRes.count or unreadNotifs
        end
        local hasUnread = unreadCount > 0
        local notifLabel = hasUnread and ("Notifications ("..unreadCount..")") or "Notifications"
        local hasFoodSub = foodSubCache and foodSubCache.food_sub
        local menuItems={
            {label="Cloud Storage", icon=colors.cyan  },
            {label="Bank",          icon=colors.yellow},
            {label="Market",        icon=colors.orange},
            {label="Gambling",      icon=colors.pink  },
            {label="Subscriptions", icon=hasFoodSub and colors.lime or colors.purple},
            {label=notifLabel,      icon=colors.purple, flash=hasUnread},
            {label="Leaderboard",   icon=colors.gray  },
            {label="Logout",        icon=colors.red   },
        }
        local sel=clickMenu("Cloud - "..username, menuItems, nil, 15)
        if sel==nil or sel==8 then token=nil username=nil isAdmin=false foodSubCache=nil return
        elseif sel==1 then cloudStorageMenu()
        elseif sel==2 then bankMenu()
        elseif sel==3 then marketMenu()
        elseif sel==4 then gamblingMenu()
        elseif sel==5 then subscriptionsMenu()
        elseif sel==7 then leaderboardScreen()
        elseif sel==6 then
            notificationsScreen()
            unreadCount = 0
            unreadNotifs = 0
        end
    end
end

-- Admin: pick user from scrollable click list
local function pickUser()
    local res   = rpc({type="admin_list_users", token=token})
    local ulist = (res and res.users) or {}
    if #ulist == 0 then return nil, "No users found" end
    local scroll = 0
    while true do
        W, H = term.getSize()
        local listH = H - 2
        term.setBackgroundColor(colors.black) term.clear()
        term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
        term.setCursorPos(1,1) term.clearLine()
        term.write(" Select User [" .. #ulist .. "]" .. string.rep(" ", math.max(0, W - 17)) .. "[X]")
        for row = 1, listH do
            local u = ulist[row + scroll]
            term.setCursorPos(1, row + 1) term.setBackgroundColor(colors.black)
            if u then
                term.setTextColor(colors.yellow) term.write(" " .. (u.username or ""):sub(1, W - 2))
                term.setTextColor(colors.black) term.write(string.rep(" ", math.max(0, W - #(u.username or "") - 2)))
            else
                term.write(string.rep(" ", W))
            end
        end
        if scroll > 0 then
            term.setCursorPos(W, 2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^")
        end
        if scroll + listH < #ulist then
            term.setCursorPos(W, H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v")
        end
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "term_resize" then W, H = term.getSize() shiftHeld = false
        elseif ev == "mouse_click" then
            local mx, my = p2, p3
            if my == 1 and mx >= W - 2 then return nil end
            local idx = my - 1 + scroll
            if idx >= 1 and idx <= #ulist then return ulist[idx].username end
        elseif ev == "mouse_scroll" then
            scroll = math.max(0, math.min(scroll + p1, math.max(0, #ulist - listH)))
        elseif ev == "key" then
            if p1 == keys.q then return nil
            elseif p1 == keys.up   then scroll = math.max(0, scroll - 1)
            elseif p1 == keys.down then scroll = math.min(math.max(0, #ulist - listH), scroll + 1) end
        end
    end
end

-- Admin menu
local function adminMenu()
    local msg2 = ""
    local mt2  = 0
    while true do
        local adminItems = {
            { label="List Users",        icon=colors.cyan   },
            { label="Create User",       icon=colors.lime   },
            { label="Manage User",       icon=colors.yellow },
            { label="Debug Peripherals", icon=colors.orange },
            { label="Bank Overview",     icon=colors.yellow },
            { label="Logout",            icon=colors.red    },
        }
        local sel = clickMenu("Cloud Admin", adminItems, msg2)
        msg2 = ""

        if sel == nil or sel == 6 then
            token=nil username=nil isAdmin=false return

        elseif sel == 1 then
            -- List users
            local res   = rpc({type="admin_list_users", token=token})
            local users = (res and res.users) or {}
            local scroll = 0
            while true do
                W, H = term.getSize()
                local listH = H - 2
                term.setBackgroundColor(colors.black) term.clear()
                term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
                term.setCursorPos(1,1) term.clearLine()
                term.write(" Users [" .. #users .. "]" .. string.rep(" ", math.max(0, W - 12)) .. "[X]")
                for row = 1, listH do
                    local u = users[row + scroll]
                    term.setCursorPos(1, row + 1) term.setBackgroundColor(colors.black)
                    if u then
                        term.setTextColor(colors.yellow) term.write(" " .. u.username:sub(1, 12))
                        term.setTextColor(colors.gray)   term.write("  " .. (u.vault or "no vault"):sub(1, W - 16))
                    else
                        term.setTextColor(colors.black) term.write(string.rep(" ", W))
                    end
                end
                if scroll > 0 then
                    term.setCursorPos(W, 2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^")
                end
                if scroll + listH < #users then
                    term.setCursorPos(W, H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v")
                end
                local ev2, p2, p3, p4 = os.pullEvent()
                if ev2=="term_resize" then W, H = term.getSize()
                elseif ev2=="mouse_click" and p4==1 and p3>=W-2 then break
                elseif ev2=="mouse_scroll" then scroll=math.max(0,math.min(scroll+p2,math.max(0,#users-listH)))
                elseif ev2=="key" then
                    if p2==keys.q then break
                    elseif p2==keys.up   then scroll=math.max(0,scroll-1)
                    elseif p2==keys.down then scroll=math.min(math.max(0,#users-listH),scroll+1) end
                end
            end

        elseif sel == 2 then
            -- Create user (text input, keyboard only)
            term.setBackgroundColor(colors.black) term.clear()
            term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
            term.setCursorPos(1,1) term.clearLine() term.write(" Create User")
            term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
            local function prompt(row, label)
                term.setCursorPos(1,row) term.write(label) return read()
            end
            local uname = prompt(3,"Username:   ")
            local pass  = prompt(4,"Password:   ")
            local vnum  = prompt(5,"Vault #:    ")
            local imnum = prompt(6,"InvMgr #:   ")
            local vdir  = prompt(7,"VaultDir:   ")
            if vdir == "" then vdir = "back" end
            local vault  = "create:item_vault_"..vnum
            local invmgr = "inventory_manager_"..imnum
            local r = rpc({type="admin_create_user", token=token,
                username=uname, password=pass, vault=vault, invmanager=invmgr, vaultDir=vdir}, 10)
            if r and r.ok then msg2="Created: "..uname mt2=os.clock()+3
            else msg2=(r and r.err) or "Failed" mt2=os.clock()+3 end

        elseif sel == 3 then
            -- Manage user
            local target, err = pickUser()
            if not target then
                if err then msg2=err mt2=os.clock()+2 end
            else
                local subItems = {
                    { label="View Vault",      icon=colors.cyan   },
                    { label="View Inventory",  icon=colors.blue   },
                    { label="Withdraw",        icon=colors.green  },
                    { label="Deposit",         icon=colors.lime   },
                    { label="Delete User",     icon=colors.red    },
                    { label="Back",            icon=colors.gray   },
                }
                while true do
                    local sub = clickMenu("Manage: " .. target, subItems)
                    if sub == nil or sub == 6 then break
                    elseif sub == 1 then
                        itemListUI({title=target.." Vault", readOnly=true,
                            fetchFn=function() local r=rpc({type="admin_view_vault",token=token,username=target}) return r or {} end})
                    elseif sub == 2 then
                        itemListUI({title=target.." Inventory", readOnly=true,
                            fetchFn=function() local r=rpc({type="admin_view_inventory",token=token,username=target}) return r or {} end})
                    elseif sub == 3 then
                        itemListUI({title="Withdraw: "..target, actionLabel="Withdrew",
                            fetchFn=function() local r=rpc({type="admin_view_vault",token=token,username=target}) return r or {} end,
                            actionFn=function(item,amt)
                                local r=rpc({type="admin_withdraw",token=token,username=target,name=item.name,count=amt},10)
                                return r and r.ok, r and r.err end})
                    elseif sub == 4 then
                        itemListUI({title="Deposit: "..target, actionLabel="Deposited",
                            fetchFn=function() local r=rpc({type="admin_view_inventory",token=token,username=target}) return r or {} end,
                            actionFn=function(item,amt)
                                local r=rpc({type="admin_deposit",token=token,username=target,name=item.name,count=amt},10)
                                return r and r.ok, r and r.err end})
                    elseif sub == 5 then
                        term.setBackgroundColor(colors.black) term.clear()
                        term.setBackgroundColor(colors.red) term.setTextColor(colors.white)
                        term.setCursorPos(1,1) term.clearLine() term.write(" Confirm Delete")
                        term.setBackgroundColor(colors.black) term.setTextColor(colors.white)
                        term.setCursorPos(1,3) term.write("Delete " .. target .. "?")
                        term.setCursorPos(1,5)
                        term.setBackgroundColor(colors.red)    term.write(" Yes ")
                        term.setBackgroundColor(colors.black)  term.write("   ")
                        term.setBackgroundColor(colors.gray)   term.write(" No ")
                        while true do
                            local ev4,p4,p5,p6 = os.pullEvent()
                            if ev4=="mouse_click" then
                                if p6==5 and p5>=1 and p5<=5 then
                                    local r=rpc({type="admin_delete_user",token=token,username=target},10)
                                    if r and r.ok then msg2="Deleted: "..target mt2=os.clock()+3 end
                                    break
                                elseif p6==5 and p5>=9 and p5<=12 then break
                                end
                            elseif ev4=="key" then
                                if p4==keys.y then
                                    local r=rpc({type="admin_delete_user",token=token,username=target},10)
                                    if r and r.ok then msg2="Deleted: "..target mt2=os.clock()+3 end
                                end
                                break
                            end
                        end
                    end
                end
            end

        elseif sel == 4 then
            -- Debug peripherals
            local res   = rpc({type="debug_peripherals"})
            local names = (res and res.names) or {}
            local scroll = 0
            while true do
                W, H = term.getSize()
                local listH = H - 2
                term.setBackgroundColor(colors.black) term.clear()
                term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
                term.setCursorPos(1,1) term.clearLine()
                term.write(" Peripherals [" .. #names .. "]" .. string.rep(" ", math.max(0, W - 18)) .. "[X]")
                for row = 1, listH do
                    local n = names[row + scroll]
                    term.setCursorPos(1, row + 1) term.setBackgroundColor(colors.black)
                    if n then term.setTextColor(colors.white) term.write(" " .. n:sub(1, W - 1))
                    else term.setTextColor(colors.black) term.write(string.rep(" ", W)) end
                end
                if scroll > 0 then
                    term.setCursorPos(W, 2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^")
                end
                if scroll + listH < #names then
                    term.setCursorPos(W, H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v")
                end
                local ev2, p2, p3, p4 = os.pullEvent()
                if ev2=="term_resize" then W, H = term.getSize()
                elseif ev2=="mouse_click" and p4==1 and p3>=W-2 then break
                elseif ev2=="mouse_scroll" then scroll=math.max(0,math.min(scroll+p2,math.max(0,#names-listH)))
                elseif ev2=="key" then
                    if p2==keys.q then break
                    elseif p2==keys.up   then scroll=math.max(0,scroll-1)
                    elseif p2==keys.down then scroll=math.min(math.max(0,#names-listH),scroll+1) end
                end
            end

        elseif sel == 5 then
            -- Bank overview
            local res = rpc({type="admin_bank_overview", token=token}, 10)
            if not res or not res.ok then
                term.setBackgroundColor(colors.black) term.clear()
                term.setCursorPos(1,3) term.setTextColor(colors.red)
                term.write((res and res.err) or "Bank server error")
                term.setCursorPos(1,5) term.setTextColor(colors.gray) term.write("Press any key...")
                os.pullEvent()
            else
                local lines = {}
                table.insert(lines, "Vault:      " .. (res.vault_spurs    or 0) .. " sp")
                table.insert(lines, "Bank bal:   " .. (res.bank_balance   or 0) .. " sp")
                table.insert(lines, "Deps:       " .. (res.total_dep      or 0) .. " sp")
                table.insert(lines, "Loans:      " .. (res.total_loans    or 0) .. " sp")
                table.insert(lines, "Loan int/d: " .. (res.daily_loan_int or 0) .. " sp")
                table.insert(lines, "Dep int/d:  " .. (res.daily_dep_int  or 0) .. " sp")
                table.insert(lines, "Mkt vol 24h: " .. (res.market_volume  or 0) .. " sp")
                table.insert(lines, "Mkt tax 24h: " .. (res.market_revenue or 0) .. " sp")
                table.insert(lines, "Gambling:   " .. (res.slots_revenue  or 0) .. " sp")
                table.insert(lines, "House tot:  " .. ((res.market_revenue or 0)+(res.slots_revenue or 0)) .. " sp")
                table.insert(lines, string.rep("-", W))
                for _, u in ipairs(res.users or {}) do
                    local lstr = u.loan and (" L:"..u.loan.remaining) or ""
                    local uname = (u.username or "?"):sub(1, math.min(8, W))
                    table.insert(lines, (uname.." bal:"..u.balance.." cr:"..u.credit..lstr):sub(1,W))
                end
                local scroll = 0
                while true do
                    W, H = term.getSize()
                    local lh = H - 2
                    term.setBackgroundColor(colors.black) term.clear()
                    term.setBackgroundColor(colors.orange) term.setTextColor(colors.white)
                    term.setCursorPos(1,1) term.clearLine()
                    term.write(" Bank Overview" .. string.rep(" ", math.max(0, W-17)) .. "[X]")
                    for row = 1, lh do
                        local ln = lines[row + scroll]
                        term.setCursorPos(1, row+1) term.setBackgroundColor(colors.black)
                        if ln then term.setTextColor(colors.white) term.write(ln:sub(1,W))
                        else term.setTextColor(colors.black) term.write(string.rep(" ", W)) end
                    end
                    if scroll > 0 then term.setCursorPos(W,2) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("^") end
                    if scroll+lh < #lines then term.setCursorPos(W,H) term.setBackgroundColor(colors.gray) term.setTextColor(colors.white) term.write("v") end
                    local ev2, p2, p3, p4 = os.pullEvent()
                    if ev2=="term_resize" then W,H=term.getSize()
                    elseif ev2=="mouse_click" and p4==1 and p3>=W-2 then break
                    elseif ev2=="mouse_scroll" then scroll=math.max(0,math.min(scroll+p2,math.max(0,#lines-lh)))
                    elseif ev2=="key" then
                        if p2==keys.q then break
                        elseif p2==keys.up then scroll=math.max(0,scroll-1)
                        elseif p2==keys.down then scroll=math.min(math.max(0,#lines-lh),scroll+1) end
                    end
                end
            end
        end
    end
end

parallel.waitForAny(
    function()
        while true do
            -- Tenta restaurar sessão salva antes de pedir login
            if not tryRestoreSession() then
                doLogin()
            end
            if isAdmin then adminMenu() else userMenu() end
            -- needsRelogin: token rejeitado pelo servidor (não erro de rede)
            if needsRelogin then
                -- Tenta uma última vez ver se o servidor está respondendo
                local chk = httpPost("/session_check", {token=token or ""})
                if chk == nil then
                    -- Servidor offline: NÃO limpa sessão, mostra tela de espera
                    term.setBackgroundColor(colors.black) term.clear()
                    term.setBackgroundColor(colors.red) term.setTextColor(colors.white)
                    term.setCursorPos(1,1) term.clearLine() term.write(" Server Offline")
                    term.setBackgroundColor(colors.black)
                    term.setCursorPos(2,3) term.setTextColor(colors.yellow)
                    term.write("Tunnel unreachable.")
                    term.setCursorPos(2,4) term.setTextColor(colors.gray)
                    term.write("Sua sessão foi mantida.")
                    term.setCursorPos(2,5) term.write("Pressione qualquer tecla")
                    term.setCursorPos(2,6) term.write("para tentar reconectar...")
                    os.pullEvent()
                    needsRelogin = false
                    -- volta ao loop — tryRestoreSession vai restaurar do arquivo
                else
                    -- Servidor respondeu: token inválido de verdade, força login
                    clearSession()
                    needsRelogin = false
                    token=nil username=nil isAdmin=false
                end
            end
        end
    end,
    function()
        local _urlTick = 0
        while true do
            sleep(60)
            checkAndDeliverFood()
            -- Refresh API URL a cada 5min (5 × 60s)
            _urlTick = _urlTick + 1
            if _urlTick % 5 == 0 then
                local oldUrl = API_URL
                loadApiUrl()
                if API_URL ~= oldUrl and API_URL ~= "" then
                    -- URL mudou — força relogin para reconectar
                    needsRelogin = true
                end
            end
        end
    end
)
