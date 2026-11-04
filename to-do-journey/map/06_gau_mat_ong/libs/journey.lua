-- libs/journey - the to-do journey body from the head's store or the pack frame
-- Resolve: require("libs/journey")
--
-- Newer firmware stores the raw GET body under Pack.data("journey") and calls
-- on_pack_data("journey", version) when it changes; every firmware still sends
-- it as on_pack_cmd {op="journey", args=<body>}. Both carry the same body, so a
-- pack hands either one to its handler and skips one it has already applied.
--
--   local JOURNEY = require("libs/journey")
--   JOURNEY.reset()                      -- game_start
--   local j = JOURNEY.stored()           -- nil on 1.1.5 and older
--   if not JOURNEY.seen(body) then apply(body) end

local M = {}

local last_key = nil

-- The stored body, or nil: no Pack / Pack.data (old firmware), nothing
-- published (1.1.5), tombstoned, or a decode failure. Never raises. The table
-- is the engine's cached copy: read it, never write it.
function M.stored()
  local ok, j = pcall(function()
    if type(Pack) ~= "table" or type(Pack.data) ~= "function" then return nil end
    return Pack.data("journey")
  end)
  if ok and type(j) == "table" then return j end
  return nil
end

-- Narration urls the body offers: a refetch can bring one that was still null
-- (TTS not ready), and that refetch must be applied.
local function url_count(meta)
  local audio = type(meta) == "table" and meta.audio or nil
  if type(audio) ~= "table" then return 0 end
  local n = 0
  for _, list in ipairs({ audio.dynamic, audio.static }) do
    if type(list) == "table" then
      for _, item in ipairs(list) do
        if type(item) == "table" and type(item.url) == "string" and item.url ~= "" then
          n = n + 1
        end
      end
    end
  end
  return n
end

-- One scalar for the key: whole numbers print without ".0" (the store and the
-- frame decode the same JSON), a table or a JSON-null sentinel only by type.
local function s(v)
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) and v >= -2147483648 and v <= 2147483647 then
      return string.format("%d", v)
    end
    return tostring(v)
  end
  if t == "string" or t == "boolean" then return tostring(v) end
  if v == nil then return "" end
  return t
end

-- Reward fields of one checkpoint the reward packs read: egg options (count,
-- amounts, item ids, total_xp, equipped) and chest progress, prize, equipped.
local function reward_part(cp)
  local out = ""
  local ro = cp.reward_options
  if type(ro) == "table" then
    local opts = type(ro.options) == "table" and ro.options or {}
    local am = {}
    for i, o in ipairs(opts) do
      am[i] = type(o) == "table" and (s(o.amount) .. "#" .. s(o.item_id)) or "?"
    end
    local o1 = opts[1]
    out = out .. ":o" .. #opts .. "=" .. table.concat(am, "+") .. "x" ..
          s(type(o1) == "table" and o1.total_xp or nil) .. "e" .. s(ro.equipped_item_id)
  end
  local fr = cp.final_reward
  if type(fr) == "table" then
    out = out .. ":f" .. s(fr.pieces_owned) .. "/" .. s(fr.pieces_total) .. s(fr.reward_type) ..
          "#" .. s(fr.reward_item_id) .. "e" .. s(fr.equipped_item_id)
  end
  return out
end

-- Same list, cursor, shape, statuses, reward fields, theme and narration -> same
-- key. nil when the body has no data table (never treated as a duplicate).
function M.key(body)
  local data = type(body) == "table" and body.data or nil
  if type(data) ~= "table" then return nil end
  local cps = data.checkpoints
  local n = type(cps) == "table" and #cps or 0
  local parts = { tostring(data.todo_list_id or ""), "|", tostring(data.current_index), "/", n, "/" }
  for i = 1, n do
    local cp = cps[i]
    parts[#parts + 1] = (type(cp) == "table" and (tostring(cp.status) .. reward_part(cp)) or "-") .. ","
  end
  parts[#parts + 1] = "/" .. url_count(data.theme_meta) .. "/" .. s(data.theme_id)
  return table.concat(parts)
end

-- true when body equals the last one recorded; otherwise records it.
function M.seen(body)
  local k = M.key(body)
  if k ~= nil and k == last_key then return true end
  last_key = k
  return false
end

-- Forget the last body: each launch starts with nothing applied.
function M.reset()
  last_key = nil
end

return M
