-- monitor.lua — Painel de status do Bridge/Servidor
-- Pode rodar:
--   1) No mesmo computador do bridge: multishell.launch("monitor.lua")
--      O bridge emite eventos "cloud_monitor" via os.queueEvent()
--   2) Em outro computador CC: recebe via rednet protocolo "cloud_monitor"
--
-- Uso: monitor [lado_modem]
-- Ex:  monitor left
--      monitor          (detecta modem automático)

local MON_PROTO  = "cloud_monitor"
local BRIDGE_VER = "v3.1"
local W, H = term.getSize()

-- ── Detecta modem ─────────────────────────────────────────────────────────────
local modemSide = ...
if not modemSide then
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            modemSide = name; break
        end
    end
end
if modemSide then
    pcall(rednet.open, modemSide)
end

-- ── Estado do painel ──────────────────────────────────────────────────────────
local state = {
    server_url   = "?",
    bridge_ver   = BRIDGE_VER,
    peripherals  = {},
    queue_size   = 0,
    active_cids  = {},      -- { [cid]=true } workers ativos
    log          = {},      -- lista de {ts, level, msg}
    op_log       = {},      -- últimas ops bridge: {ts, type, uname, ok}
    stats        = {
        total_ops    = 0,
        total_errors = 0,
        uptime_start = os.epoch("utc"),
    },
    server_ok    = nil,     -- nil=unknown, true=ok, false=offline
    last_ping    = 0,
}

local MAX_LOG    = 50
local MAX_OP_LOG = 20
local tab        = 1   -- aba ativa: 1=status 2=log 3=ops 4=periféricos

-- ── Log helper ────────────────────────────────────────────────────────────────
local LOG_COLORS = {
    info  = colors.white,
    ok    = colors.lime,
    warn  = colors.yellow,
    err   = colors.red,
    gray  = colors.gray,
}

local function addLog(level, msg)
    local ts = math.floor(os.epoch("utc") / 1000)
    table.insert(state.log, {ts=ts, level=level, msg=msg})
    while #state.log > MAX_LOG do table.remove(state.log, 1) end
end

local function addOp(opType, uname, ok, extra)
    local ts = math.floor(os.epoch("utc") / 1000)
    table.insert(state.op_log, {ts=ts, type=opType, uname=uname or "?", ok=ok, extra=extra})
    while #state.op_log > MAX_OP_LOG do table.remove(state.op_log, 1) end
    state.stats.total_ops = state.stats.total_ops + 1
    if not ok then state.stats.total_errors = state.stats.total_errors + 1 end
end

-- ── Formatação de tempo ───────────────────────────────────────────────────────
local function fmtTs(ts)
    local now = math.floor(os.epoch("utc") / 1000)
    local d = now - ts
    if d < 60    then return d.."s ago" end
    if d < 3600  then return math.floor(d/60).."m ago" end
    return math.floor(d/3600).."h ago"
end

local function fmtUptime()
    local d = math.floor((os.epoch("utc") - state.stats.uptime_start) / 1000)
    local h = math.floor(d/3600)
    local m = math.floor((d%3600)/60)
    local s = d % 60
    if h > 0 then return h.."h "..m.."m" end
    if m > 0 then return m.."m "..s.."s" end
    return s.."s"
end

-- ── Desenho ───────────────────────────────────────────────────────────────────
local function clr(bg, fg)
    term.setBackgroundColor(bg or colors.black)
    term.setTextColor(fg or colors.white)
end

local function drawHeader()
    clr(colors.gray, colors.black)
    term.setCursorPos(1,1) term.clearLine()
    -- Status dot
    local dotBg = state.server_ok == true  and colors.lime
               or state.server_ok == false and colors.red
               or colors.orange
    term.setBackgroundColor(dotBg) term.write(" ")
    clr(colors.gray, colors.black)
    term.write(" Cloud Bridge Monitor ")
    -- Uptime
    local up = " up "..fmtUptime().." "
    term.setCursorPos(W - #up + 1, 1)
    clr(colors.gray, colors.black) term.write(up)
end

local function drawTabs()
    local tabs = {"Status","Log","Ops","Periféricos"}
    local tabW = math.floor(W / #tabs)
    for i, label in ipairs(tabs) do
        local x = (i-1)*tabW + 1
        if i == tab then
            clr(colors.blue, colors.white)
        else
            clr(colors.black, colors.gray)
        end
        term.setCursorPos(x, 2)
        local lbl = " "..label
        lbl = lbl..string.rep(" ", tabW - #lbl)
        term.write(lbl:sub(1, tabW))
    end
end

-- Tab 1: Status
local function drawStatus()
    local y = 3
    local function row(label, val, vc)
        term.setCursorPos(1, y) clr(colors.black, colors.gray)
        term.clearLine()
        term.write(" "..label..": ")
        clr(colors.black, vc or colors.white)
        term.write(tostring(val))
        y = y + 1
    end

    row("Server",   state.server_url,
        state.server_ok and colors.lime or colors.red)
    row("Bridge",   state.bridge_ver, colors.cyan)
    row("Uptime",   fmtUptime(), colors.white)
    row("Ops total",state.stats.total_ops, colors.white)
    row("Errors",   state.stats.total_errors,
        state.stats.total_errors > 0 and colors.red or colors.lime)

    y = y + 1
    -- Queue visual
    term.setCursorPos(1, y) clr(colors.black, colors.gray)
    term.clearLine() term.write(" Queue: ")
    local qBg = state.queue_size == 0 and colors.gray
              or state.queue_size  < 3 and colors.yellow
              or colors.red
    clr(qBg, colors.black) term.write(" "..state.queue_size.." ")
    y = y + 1

    -- Active cids
    term.setCursorPos(1, y) clr(colors.black, colors.gray)
    term.clearLine() term.write(" Active tablets: ")
    local cids = {}
    for cid in pairs(state.active_cids) do table.insert(cids, tostring(cid)) end
    clr(colors.black, #cids > 0 and colors.cyan or colors.gray)
    term.write(#cids > 0 and table.concat(cids,", ") or "none")
    y = y + 1

    y = y + 1
    -- Last 5 ops mini-preview
    term.setCursorPos(1, y) clr(colors.black, colors.gray)
    term.clearLine() term.write(" Recent ops:")
    y = y + 1
    local start = math.max(1, #state.op_log - 4)
    for i = start, #state.op_log do
        local op = state.op_log[i]
        if y > H then break end
        term.setCursorPos(1, y) clr(colors.black) term.clearLine()
        -- ok dot
        clr(op.ok and colors.lime or colors.red, colors.black)
        term.write(" ")
        clr(colors.black, op.ok and colors.lime or colors.red)
        term.write(" "..op.type:sub(1,14))
        clr(colors.black, colors.gray)
        term.write(" "..op.uname:sub(1,10).." "..fmtTs(op.ts))
        y = y + 1
    end

    -- Clear rest
    while y <= H do
        term.setCursorPos(1,y) clr(colors.black) term.clearLine()
        y = y + 1
    end
end

-- Tab 2: Log
local logScroll = 0
local function drawLog()
    local listH = H - 2
    local maxScroll = math.max(0, #state.log - listH)
    if logScroll > maxScroll then logScroll = maxScroll end

    for row = 1, listH do
        local idx = row + logScroll
        local entry = state.log[idx]
        local y = row + 2
        term.setCursorPos(1, y) clr(colors.black) term.clearLine()
        if entry then
            local c = LOG_COLORS[entry.level] or colors.white
            clr(colors.black, colors.gray)
            term.write(fmtTs(entry.ts).." ")
            clr(colors.black, c)
            term.write(entry.msg:sub(1, W - 8))
        end
    end

    -- Scroll hint
    if #state.log > listH then
        term.setCursorPos(W, 3)
        clr(colors.gray, colors.white)
        term.write(logScroll > 0 and "\30" or " ")
        term.setCursorPos(W, H)
        term.write(logScroll < maxScroll and "\31" or " ")
    end
end

-- Tab 3: Ops log
local opsScroll = 0
local function drawOps()
    local listH = H - 3
    local maxScroll = math.max(0, #state.op_log - listH)
    if opsScroll > maxScroll then opsScroll = maxScroll end

    -- Column header
    -- Dynamic column widths based on terminal width
    local typeW = math.max(16, W - 28)
    local unameW = 10
    term.setCursorPos(1, 3) clr(colors.gray, colors.black) term.clearLine()
    local hdr = " OK  " .. "Type" .. string.rep(" ", typeW-4) .. "User       Time"
    term.write(hdr:sub(1, W))

    for row = 1, listH do
        local idx = #state.op_log - (row-1) - opsScroll  -- newest first
        local op  = state.op_log[idx]
        local y   = row + 3
        term.setCursorPos(1, y) clr(colors.black) term.clearLine()
        if op then
            clr(op.ok and colors.lime or colors.red, colors.black)
            term.write(" ")
            clr(colors.black, op.ok and colors.lime or colors.red)
            term.write(op.ok and " ok " or " !! ")
            clr(colors.black, colors.white)
            local typeFmt = op.type:sub(1, typeW)
            term.write(typeFmt..string.rep(" ", typeW+1-#typeFmt))
            clr(colors.black, colors.cyan)
            local unFmt = (op.uname or "?"):sub(1, unameW)
            term.write(unFmt..string.rep(" ", unameW+1-#unFmt))
            clr(colors.black, colors.gray)
            term.write(fmtTs(op.ts))
        end
    end

    if #state.op_log > listH then
        term.setCursorPos(W, 4)
        clr(colors.gray, colors.white) term.write(opsScroll > 0 and "\30" or " ")
        term.setCursorPos(W, H)
        term.write(opsScroll < maxScroll and "\31" or " ")
    end
end

-- Tab 4: Periféricos
local function drawPeripherals()
    local y = 3
    if #state.peripherals == 0 then
        term.setCursorPos(2, y) clr(colors.black, colors.gray)
        term.clearLine() term.write("Nenhum periférico registrado.")
        y = y + 1
    end
    for _, p in ipairs(state.peripherals) do
        if y > H then break end
        term.setCursorPos(1, y) clr(colors.black) term.clearLine()
        -- Type color
        local tc = colors.cyan
        if p.ptype:find("vault")     then tc = colors.yellow end
        if p.ptype:find("modem")     then tc = colors.lime   end
        if p.ptype:find("computer")  then tc = colors.orange end
        if p.ptype:find("inventory") then tc = colors.purple end
        clr(tc, colors.black) term.write(" ")
        clr(colors.black, tc) term.write(" "..p.name:sub(1,16))
        clr(colors.black, colors.gray)
        local t = p.ptype:sub(1, W-20)
        term.write("  "..t)
        -- Role label
        local role = p.role
        if role then
            clr(colors.black, colors.orange)
            term.write("  ["..role.."]")
        end
        y = y + 1
    end
    while y <= H do
        term.setCursorPos(1,y) clr(colors.black) term.clearLine()
        y = y + 1
    end
end

local function redraw()
    drawHeader()
    drawTabs()
    if     tab == 1 then drawStatus()
    elseif tab == 2 then drawLog()
    elseif tab == 3 then drawOps()
    elseif tab == 4 then drawPeripherals()
    end
    term.setCursorPos(1, H)
end

-- ── Processa evento do bridge ─────────────────────────────────────────────────
local function processEvent(data)
    if not type(data) == "table" then return end
    local t = data.type

    if t == "init" then
        state.server_url  = data.server_url or state.server_url
        state.bridge_ver  = data.version    or state.bridge_ver
        state.peripherals = data.peripherals or {}
        state.stats.uptime_start = os.epoch("utc")
        addLog("ok", "Bridge iniciado — "..#state.peripherals.." periféricos")

    elseif t == "log" then
        addLog(data.level or "info", data.msg or "")

    elseif t == "op_start" then
        state.active_cids[data.cid] = true
        state.queue_size = data.queue_size or state.queue_size

    elseif t == "op_done" then
        state.active_cids[data.cid] = nil
        state.queue_size = data.queue_size or state.queue_size
        addOp(data.op_type or "?", data.uname or "?", data.ok ~= false, data.extra)

    elseif t == "queue_update" then
        state.queue_size = data.size or 0

    elseif t == "server_ping" then
        state.server_ok = data.ok
        state.last_ping = os.epoch("utc") / 1000

    elseif t == "peripheral_update" then
        state.peripherals = data.peripherals or state.peripherals
    end
end

-- ── Input handler ─────────────────────────────────────────────────────────────
local function handleInput(ev, p1, p2, p3)
    if ev == "key" then
        if     p1 == keys.one   or p1 == keys.f1 then tab = 1
        elseif p1 == keys.two   or p1 == keys.f2 then tab = 2
        elseif p1 == keys.three or p1 == keys.f3 then tab = 3
        elseif p1 == keys.four  or p1 == keys.f4 then tab = 4
        elseif p1 == keys.up then
            if tab==2 then logScroll=math.max(0,logScroll-1)
            elseif tab==3 then opsScroll=math.max(0,opsScroll-1) end
        elseif p1 == keys.down then
            if tab==2 then logScroll=logScroll+1
            elseif tab==3 then opsScroll=opsScroll+1 end
        elseif p1 == keys.q then
            term.setBackgroundColor(colors.black) term.clear()
            term.setCursorPos(1,1) error("exit",0)
        end
        return true

    elseif ev == "mouse_click" then
        local mx, my = p2, p3
        if my == 2 then
            local tabs = {"Status","Log","Ops","Periféricos"}
            local tabW = math.floor(W / #tabs)
            local clicked = math.ceil(mx / tabW)
            if clicked >= 1 and clicked <= #tabs then
                tab = clicked; return true
            end
        end
        if tab==2 then
            if mx==W and my==3 then logScroll=math.max(0,logScroll-1); return true end
            if mx==W and my==H then logScroll=logScroll+1; return true end
        end
        if tab==3 then
            if mx==W and my==4 then opsScroll=math.max(0,opsScroll-1); return true end
            if mx==W and my==H then opsScroll=opsScroll+1; return true end
        end

    elseif ev == "mouse_scroll" then
        local dir = p1
        if tab==2 then logScroll=math.max(0,logScroll+dir)
        elseif tab==3 then opsScroll=math.max(0,opsScroll+dir) end
        return true
    end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
term.setBackgroundColor(colors.black) term.clear()
addLog("info", "Monitor iniciado")
addLog("gray", "Aguardando eventos do bridge...")
redraw()

-- Timer para redesenhar header (uptime) a cada segundo
local tickTimer = os.startTimer(1)

while true do
    local ev, p1, p2, p3 = os.pullEvent()

    if ev == "timer" and p1 == tickTimer then
        tickTimer = os.startTimer(1)
        redraw()

    elseif ev == "cloud_monitor" then
        -- Evento local (mesmo computador, bridge usa os.queueEvent)
        processEvent(p1)
        redraw()

    elseif ev == "rednet_message" then
        -- p1=sender, p2=msg, p3=protocol
        if p3 == MON_PROTO and type(p2) == "table" then
            processEvent(p2)
            redraw()
        end

    elseif ev == "term_resize" then
        W, H = term.getSize()
        redraw()

    else
        if handleInput(ev, p1, p2, p3) then redraw() end
    end
end
