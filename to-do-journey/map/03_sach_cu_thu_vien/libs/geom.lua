-- Journey map geometry, from final-demo-todo-resized.html (demo commit 22f1164),
-- with the 06/10 six-marker rule of map-demo_v4.html. The demo's MapLayoutPatch
-- wrapper is what actually draws, so everything here follows it rather than the
-- inner MAP_LAB page.
local M = {}

-- The eight anchors (BO_CUC_NHUNG.khuon), hand-placed on the 04_khi_dan_duong
-- backdrop that map_bg.png is. Since the six-marker rule every length from 3
-- to 6 has its own LAYOUTS entry, so these only place a two-point day (M.place
-- falls through to them).
M.KHUON = {
  { 55, 147}, {112, 232}, {239, 278}, {180, 132},
  {317,  77}, {298, 187}, {360, 274}, {420, 156},
}

-- Hand-placed layouts per day length (BO_CUC_NHUNG.layouts). A length with no
-- entry falls through to the formula in M.place. [6] also places every longer
-- day: four checkpoints, the "+K" pill at slot 5, the chest at slot 6. The
-- demo's [7] is left out: no window exceeds MAP_MAX.
M.LAYOUTS = {
  [3] = { { 55, 158}, {233, 162}, {420, 156} },
  [4] = { { 58, 147}, {180, 223}, {268, 115}, {404, 169} },
  [5] = { { 55, 147}, {156, 249}, {235, 119}, {307, 240}, {420, 156} },
  [6] = { { 59, 164}, {162, 103}, {286, 124}, {186, 230}, {313, 251}, {412, 150} },
}

-- The demo's .node box is 72x72 with its transform origin (the anchor) at
-- (36, 45); the pill-shift guard below measures from it.
M.NODE = { ANCHOR_X = 36 }

-- Node scale per kind (BO_CUC_NHUNG.k).
M.SIZE = { stage = 1.65, egg = 1.90, chest = 2.25 }

-- Anchor -> sprite CENTRE offsets in screen px, already scaled by the kind's k
-- and including the pedestal's translateY(16%) that the art bakes in:
--   base dy  = (6 + 32 + 0.16*64 - 45) * k
--   obj  dy  = (6 + 22 - 45) * k          (chest: 10 instead of 6)
--   badge dy = (10 + 16 - 45) * k          (every kind: a DONE reward shows
--                                           the lesson's tick too)
-- dx is 0: base and icon slots are both centred on the anchor.
M.OFF = {
  stage = { BASE_DY =  5.35, OBJ_DY = -28.05, BADGE_DY = -31.35 },
  egg   = { BASE_DY =  6.16, OBJ_DY = -32.30, BADGE_DY = -36.10 },
  chest = { BASE_DY =  7.06, OBJ_DY = -28.34, BADGE_DY = -42.75 },
}

-- Most markers on screen at once, the pill included (map-demo_v4, 06/10).
-- Not #M.KHUON: the anchor frame keeps its eight points.
M.MAP_MAX = 6

-- Duplicates CFG.CHIP.H: geom and config do not require each other.
M.CHIP_H = 24

-- Anchor of the n-th of `total` points. First and last are always included.
function M.place(n, total)
  local fixed = M.LAYOUTS[total]
  if fixed and fixed[n] then return fixed[n][1], fixed[n][2] end

  local last = #M.KHUON
  if total <= 1 then return M.KHUON[last][1], M.KHUON[last][2] end
  local j = math.floor((n - 1) * (last - 1) / (total - 1) + 0.5)
  local p = M.KHUON[j + 1] or M.KHUON[last]
  return p[1], p[2]
end

-- Which route points are drawn (the wrapper's QUY_TAC.A):
--
--   [<= 2 points already passed] [in progress] [what is next...] [+K] [chest]
--
-- Returns { i = <route index> } entries, plus one { gop = K } for the pill on a
-- day longer than MAP_MAX. Route indices are kept, never renumbered.
function M.window(route, cur)
  local total = #route
  local last = total
  local vis = {}

  if total <= M.MAP_MAX then
    for i = 1, total do vis[#vis + 1] = { i = i } end
    return vis
  end

  -- At most 2 passed checkpoints stay left of the current one, so with the
  -- next one it fills the MAP_MAX - 2 = 4 drawn slots before the pill. The
  -- clamp below slides the window onto the tail near the end of the day.
  local s = cur - 2
  local max_s = last - (M.MAP_MAX - 1)
  if s > max_s then s = max_s end
  if s < 1 then s = 1 end

  if last - s <= M.MAP_MAX - 1 then
    for i = s, last do vis[#vis + 1] = { i = i } end
    return vis
  end

  local shown = M.MAP_MAX - 2
  for i = s, s + shown - 1 do vis[#vis + 1] = { i = i } end

  -- K is what the pill hides: after the last drawn point, before the chest,
  -- rewards included. Floored at 1 for a malformed day, capped at 99 because
  -- the chip art is sized for two digits (CFG.CHIP.W).
  local gop = 0
  for i = s + shown, last - 1 do
    local pt = route[i]
    if pt and pt.kind ~= "chest" then gop = gop + 1 end
  end
  gop = math.max(1, math.min(gop, 99))
  vis[#vis + 1] = { gop = gop }
  vis[#vis + 1] = { i = last }
  return vis
end

-- The wrapper's datViGop: pull the pill left only when it shares a band with
-- the node after it. 39 / 25 are the .node box above / below its origin.
-- `pill_w` is CFG.CHIP.W. Mutates `pts` (parallel to `vis`) in place.
function M.shift_pill(vis, pts, route, pill_w)
  local half_h = M.CHIP_H / 2
  for k = 1, #vis do
    local v, b = vis[k], vis[k + 1]
    if v.gop and b and b.i and pts[k] and pts[k + 1] then
      local kind = route[b.i] and route[b.i].kind or "stage"
      local kb = M.SIZE[kind] or 1
      local vy, by = pts[k].y, pts[k + 1].y

      if not (vy + half_h < by - 39 * kb or vy - half_h > by + 25 * kb) then
        local half = pill_w / 2
        local edge = pts[k + 1].x - M.NODE.ANCHOR_X * kb - 6
        local over = pts[k].x + half - edge
        if over > 0 then pts[k].x = pts[k].x - over end
      end
    end
  end
end

return M
