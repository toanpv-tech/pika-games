-- libs/tel - Telemetry.event that also runs on a head without the API
-- Resolve: require("libs/tel")
--
-- Report milestones only (an answer, a stage end, a reward opened), at most a
-- few per 5 s; never per frame or per button press. Returns true when the
-- event was sent (or held until game.start), false otherwise - never raises.
--
--   local tel = require("libs/tel")
--   tel.event("stage.end", { stage = 2, result = "win", score = 6 })
--   tel.event("content.bad", { q = 5 }, { key = "quiz", level = "error" })

local M = {}

local function api()
  return Telemetry and Telemetry.event and Telemetry or nil
end

-- What the head supports, or nil when it has no Telemetry API at all.
function M.caps()
  local T = api()
  if T and T.caps then return T.caps() end
  return nil
end

function M.event(name, fields, opts)
  local T = api()
  if not T then return false end
  if type(opts) == "table" and T.caps then
    -- Drop options this head does not know, so the event itself still goes out
    -- (the head would ignore them anyway; this keeps its log quiet).
    local known = T.caps().opts or {}
    local keep = {}
    for k, v in pairs(opts) do
      if known[k] then keep[k] = v end
    end
    opts = keep
  end
  return T.event(name, fields, opts)
end

return M
