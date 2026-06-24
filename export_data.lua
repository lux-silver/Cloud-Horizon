-- export_data.lua — Run this on the CC server computer to migrate data to Node.js
-- wget https://raw.githubusercontent.com/Oorange2/cloud-solutions/main/export_data.lua

local SERVER_URL = "https://explains-terminal-associate-manager.trycloudflare.com"
local BRIDGE_KEY = "c0460efe2108f8bf25d9b6dbf73292fe"

local function readDat(path)
    if not fs.exists(path) then print("Not found: "..path); return nil end
    local f = fs.open(path, "r")
    local raw = f.readAll(); f.close()
    local data = textutils.unserialize(raw)
    if not data then print("Failed to parse: "..path); return nil end
    return data
end

local function postData(path, data)
    print("Sending "..path.."...")
    local body = textutils.serialiseJSON(data)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-bridge-key"] = BRIDGE_KEY,
    }
    local ok, res = pcall(http.post, SERVER_URL..path, body, headers)
    if not ok or not res then print("  FAILED"); return false end
    local reply = res.readAll(); res.close()
    print("  "..reply)
    return true
end

print("=== Cloud Solutions Data Export ===")

local accounts = readDat("cloud_accounts.dat")
local bank     = readDat("bank_data.dat")
local market   = readDat("market_data.dat")

if accounts then postData("/import/accounts", accounts) end
if bank     then postData("/import/bank",     bank)     end
if market   then postData("/import/market",   market)   end

print("Done! All data sent to Node.js server.")
