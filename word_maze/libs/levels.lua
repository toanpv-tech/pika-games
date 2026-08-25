-- libs/levels — the 10-map ladder and post-map-10 escalation
-- Resolve: require("libs/levels")
--
-- Every rule column (braid / monsters / mrange / key / fog / chaser / timeK) is
-- carried unchanged from input/word_maze.html LEVELS[].
--
-- Logical map sizes match the HTML exactly. The renderer shows these maps through
-- a pooled 5x4 camera viewport; map size is no longer coupled to sprite count.

local M = {}

-- cols, rows, braid, monsters, mrange, key, fog, chaser, timeK
local LEVELS = {
  { 5, 3, 0.60, 0, 0, false, false, false, 1.80 },
  { 6, 4, 0.52, 0, 0, true,  false, false, 1.60 },
  { 7, 4, 0.44, 1, 2, true,  false, false, 1.45 },
  { 8, 5, 0.38, 1, 2, false, false, false, 1.30 },
  { 9, 5, 0.32, 2, 3, false, false, false, 1.20 },
  {10, 6, 0.26, 2, 3, true,  false, false, 1.10 },
  {11, 6, 0.22, 2, 3, false, true,  false, 1.05 },
  {11, 7, 0.18, 3, 3, false, true,  false, 1.00 },
  {12, 7, 0.15, 2, 4, false, false, true,  0.98 },
  {13, 7, 0.11, 3, 4, true,  true,  true,  0.95 },
}

M.COUNT = #LEVELS

-- Reused scratch table: cfg() runs on map entry, not per frame, but returning a
-- fresh table each time would still add avoidable garbage on a 512 KB heap.
local cfg = {}

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

-- Per-level configuration. Mirrors HTML levelCfg(): past the table the maze gets
-- denser, monsters more numerous with longer routes, and time tighter.
--
function M.cfg(level)
  local row = LEVELS[min(level, M.COUNT)]
  local x = max(0, level - M.COUNT)
  cfg.cols     = row[1]
  cfg.rows     = row[2]
  cfg.braid    = max(0.07, row[3] - 0.008 * x)
  cfg.monsters = min(6, row[4] + ceil(x / 2))
  cfg.mrange   = min(5, row[5] + (row[5] > 0 and floor(x / 2) or 0))
  cfg.key      = row[6]
  cfg.fog      = row[7]
  cfg.chaser   = row[8]
  cfg.time_k   = max(0.85, row[9] - 0.015 * x)
  return cfg
end

-- HTML ruleName()
-- Both return an i18n KEY, not display text: this module stays pure logic with
-- no i18n dependency so it keeps running headless under libs/testkit. The
-- render layer resolves the key through I18n.t().
function M.rule_name(c)
  if c.chaser then return "rule_gauntlet" end
  if c.fog then return "rule_fog" end
  if c.key and c.monsters > 0 then return "rule_key_monsters" end
  if c.key then return "rule_key" end
  if c.monsters > 0 then return "rule_monsters" end
  return "rule_tutorial"
end

-- HTML ruleHint()
function M.rule_hint(c)
  if c.chaser then return "hint_gauntlet" end
  if c.fog then return "hint_fog" end
  if c.monsters > 0 then return "hint_monsters" end
  if c.key then return "hint_key" end
  return "hint_tutorial"
end

return M
