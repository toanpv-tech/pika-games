-- Journey map: the in-day activity map, driven by the server's journey frame.
--
-- LIFECYCLE
--   game_start    loads art whose count does not depend on the day; draws nothing.
--   on_pack_cmd   the journey arrives; build_day maps it and arms the loader.
--   on_pack_data  newer firmware: the same body from Pack.data("journey"), also
--                 read in game_start; journey_feed skips a body already applied.
--   on_tick       pump_load spreads the day's sprite loads and the detail
--                 screen's art over ticks, then lays out and shows the whole
--                 map in one tick; after it only the breathing icon moves.
--   no frame      exits "map.exit;reason=no_journey" after NO_FRAME_MS.
--
-- REPORTS -- back parses these strings, keep them byte-exact:
--   lesson   "detail.enter;item=<item_id>"
--   reward   {"ev":"map.pick","game":"<game_id>","milestone_index":N}   (JSON, N may be -1)
--   all done "map.exit;reason=all_done" (every checkpoint DONE/SKIPPED)
--   no open  "map.exit;reason=no_open"  (the current node cannot be opened)
-- Back sends both of those to the day's fallback conversation; any other exit
-- without ";game=" counts toward its TODO_MAP_RETRY_MAX (3), after which it
-- abandons the journey. No screen ever waits on the child: each one moves on
-- by itself (hands-free advance) or falls back.
--
-- ENGINE LIMITS this pack sits against; overrunning any of them is SILENT:
--   GAME_TEXT_SLOTS 8   7 used (category, name x2, name shadow x2, bar chip,
--                       map chip); 8 at the detail label refresh -- FULL
--   GAME_FONT_SLOTS 8   5 used: Nunito Black 12, 14, 20, 26, 32
--   GAME_LINE_SLOTS 8   5 used, one per connector (MAP_MAX - 1)
--   Lua watchdog        1.5 s per hook call, which is why loads are spread
-- Sprite.image decodes every handle to RGB565A8 (w*h*3 of PSRAM): a 480x320
-- backdrop is 450KB. Peak is ~1.2MB (map + detail backdrop + pools, +55KB
-- with CFG.LEAVES); nothing grows without bound inside a session.
--
-- LOG   pf:<level> <ms since game_start> <phase> <tag> <message>
--       grep "pf:[EW]" lists everything that went wrong; the exit line sums up
--       the session (see the log section).
--
-- TELEMETRY (game.tel, at most 3 per session, under the 3-per-5 s cap). Only
-- what no other message carries: back's todo.* already has the activity kind,
-- item and the exit reason; t_ms already dates each event.
--   map.frame {n, done, cur, remote, fb, failed}  the map is up
--   map.card  {cat, via}                          a lesson card opened
--   pick      {item, via}                         the map is left for a choice
--   via = enter (confirm pressed) / auto (hands-free) / cap (hands-free after
--   the sound-end never came, AUTO_SOUND_CAP_MS)
--
-- CONTROLS   confirm only, and it takes the hands-free step now:
--              map     open the current node (the breathing one)
--              detail  enter the lesson
--            left / right are unused.

local GEO = require("libs/geom")
local CFG = require("libs/config")
local tel = require("libs/tel")
local JOURNEY = require("libs/journey")

local ART = "assets/runtime/"

-- Language for the strings the PACK owns (chip text, category label); the
-- engine injects params.language. Checkpoint names arrive already localised.
local LANG = "vi"
local function set_lang(code)
  LANG = (code == "en") and "en" or "vi"
end

local NO_FRAME_MS = 4000

-- Hands-free advance: once the narration is over and AUTO_AFTER_SOUND_MS has
-- passed, the screen takes the step confirm would. The sound-event ring can
-- drop on_sound_end, so the countdown also starts AUTO_SOUND_CAP_MS after
-- play(). The cap is a safety net, not a length: a remote map line measured
-- 8.6 s, and a cap inside a line cuts it off mid-sentence.
local AUTO_AFTER_SOUND_MS = 1500
-- Map -> reward game: no pause after the line, the game opens at once.
local AUTO_REWARD_AFTER_SOUND_MS = 0
local AUTO_SOUND_CAP_MS = 15000

-- Remote narration (manifest "remote": true -- set_url refuses anything else).
-- BE rewrites cp-1 ("what you just finished") and cp-2 ("what comes next") on
-- every call; cp-3 is the content-authored detail line. The map says cp-1
-- then cp-2, back to back (BE/api-contract.md, narration lines).
local NARR_JUST_DONE   = "cp-1"
local NARR_NEXT        = "cp-2"
local NARRATION_DETAIL = "cp-3"
local NARRATION_MAP    = { NARR_JUST_DONE, NARR_NEXT }
local NARRATION_ALL    = { NARR_JUST_DONE, NARR_NEXT, NARRATION_DETAIL }

-- Packaged line for when the remote one is not offered, has no url yet, is
-- refused by set_url or fails while playing. cp-1 has none: without it the
-- map simply opens on cp-2. cp-2 falls back to the generic map line, so the
-- map always says something.
local FALLBACK = {
  [NARR_NEXT]        = { vi = "fallback_map",      en = "fallback_map" },
  [NARRATION_DETAIL] = { vi = "fallback_activity", en = "fallback_activity" },
}

-- Sprites loaded per on_tick while the day's art arrives. One on_pack_cmd
-- loading the whole day measured 1.0-2.4 s and tripped the watchdog; the
-- slowest single load seen is ~95 ms, so 5 stays near 0.5 s.
local LOAD_BUDGET = 5

-- GAME_TRANSFORM_MAX_PX: larger sprites cannot scale.
local TRANSFORM_MAX_PX = 96

local S = {}    -- session state: the day, the cursor, the view
local R = {}    -- resources: every handle

-- ---------------------------------------------------------------- helpers

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- set_pos/set_z/align raise on a non-integral float, and a raise in on_tick
-- ends the session: every coordinate goes through here.
local function round(v) return math.floor(v + 0.5) end

-- ---------------------------------------------------------------- log
--
--   pf:W 1234 load narr cp-1 has no url yet -> fallback_map
--
-- Levels: E error, W something degraded, I milestone, D detail. A line above
-- LOG_LEVEL is never built (the parts are joined only when it prints). D also
-- turns on the lag trace and stays off on the robot: each line costs ~9 ms of
-- UART inside the frame that prints it.
-- Tags: boot day load map detail bar narr input exit lag, or the hook name.
local LOG_LEVEL = "I"
local LEVEL = { E = 1, W = 2, I = 3, D = 4 }
local LOG_MAX = LEVEL[LOG_LEVEL]
local DEBUG = LOG_MAX >= LEVEL.D

local log_count = { E = 0, W = 0 }   -- summed up on exit
local log_seen = {}                  -- keys log_once has printed

-- wait (no journey yet) / load (art arriving) / map / detail.
local function phase()
  if not S.have_day then return "wait" end
  if S.loading and S.view == "map" then return "load" end
  return S.view or "map"
end

local function log(level, tag, ...)
  if log_count[level] then log_count[level] = log_count[level] + 1 end
  if LEVEL[level] > LOG_MAX then return end
  local parts = table.pack(...)
  for i = 1, parts.n do parts[i] = tostring(parts[i]) end
  print("pf:" .. level .. " " .. (Timer.millis() - (S.start_t0 or 0)) .. " "
        .. phase() .. " " .. tag .. " " .. table.concat(parts, "", 1, parts.n))
end

-- For a fault that would otherwise repeat on every node or every frame.
local function log_once(key, level, tag, ...)
  if log_seen[key] then return end
  log_seen[key] = true
  log(level, tag, ...)
end

-- What the pack was doing, appended to the exit line and to a hook's error.
local function state_line()
  return "view=" .. tostring(S.view) .. " cur=" .. tostring(S.cur) .. "/"
      .. (S.route and #S.route or 0) .. " loading=" .. tostring(S.loading)
      .. " narr=" .. tostring(S.narr_now and S.narr_now.alias)
      .. " auto=" .. tostring(S.auto_alias)
end

-- ------------------------------------------------------------- lag trace
--
-- D only. A frame that starts TRACE_MS or more after the previous one logs:
--   lag dt=<frame> tick=<Lua in on_tick> hooks=<Lua in other hooks>
--       engine=<the rest: render, flush, other tasks> | <section>=<ms>[xN] ...
-- Sections are the Lua work since the previous frame, largest first; they may
-- nest (a load inside detail_enter counts in both). 1 ms resolution.
local TRACE_MS = DEBUG and 45 or nil
local TRACE_TOP = 6

local trace = { spans = {}, order = {}, tick_ms = 0, hook_ms = 0 }

-- Charge the time since t0 to section `name`.
local function span(name, t0)
  if not TRACE_MS then return end
  local ms = Timer.millis() - t0
  local s = trace.spans[name]
  if not s then
    s = { n = 0, ms = 0 }
    trace.spans[name] = s
    trace.order[#trace.order + 1] = name
  end
  s.n, s.ms = s.n + 1, s.ms + ms
end

local function trace_sections()
  local list = {}
  for _, name in ipairs(trace.order) do
    local s = trace.spans[name]
    if s.ms > 0 then list[#list + 1] = { name = name, n = s.n, ms = s.ms } end
  end
  table.sort(list, function(a, b) return a.ms > b.ms end)
  local parts = {}
  for i = 1, math.min(#list, TRACE_TOP) do
    local s = list[i]
    parts[#parts + 1] = s.name .. "=" .. s.ms .. (s.n > 1 and ("x" .. s.n) or "")
  end
  return (#parts > 0) and (" | " .. table.concat(parts, " ")) or ""
end

local function trace_reset()
  trace.spans, trace.order = {}, {}
  trace.tick_ms, trace.hook_ms = 0, 0
end

-- Called at the start of every on_tick, before this tick's work.
local function trace_frame(now)
  if not TRACE_MS then return end
  local last = trace.tick_at
  trace.tick_at = now
  if last and now - last >= TRACE_MS then
    local dt = now - last
    log("D", "lag", "dt=", dt, " tick=", trace.tick_ms, " hooks=", trace.hook_ms,
        " engine=", dt - trace.tick_ms - trace.hook_ms, trace_sections())
  end
  trace_reset()
end

-- One-off hooks (game_start, game_end): their time, and at D the breakdown.
local function trace_once(tag, t0)
  log("I", tag, Timer.millis() - t0, " ms", trace_sections())
  trace_reset()
end

-- Sprite.image returns (nil, msg) on a runtime failure and raises on a bad
-- path; both are caught.
local function load_sprite(path)
  local t0 = Timer.millis()
  local ok, spr, err = pcall(Sprite.image, path)
  span(path:match("[^/]+$"), t0)
  if not ok or not spr then
    log("W", "load", "sprite failed: ", path, " -- ", err or spr)
    S.sprite_failed = (S.sprite_failed or 0) + 1
    return nil
  end
  spr:set_visible(false)
  return spr
end

-- A refused set_scale is not cached and warns every frame, so oversize sprites
-- are flagged once here and never asked.
local function measure(spr)
  if not spr then return nil end
  local w, h = spr:get_size()
  return { spr = spr, w = w, h = h,
           fixed = (w > TRANSFORM_MAX_PX or h > TRANSFORM_MAX_PX) }
end

local function put(m, cx, cy, z)
  if not m then return end
  m.spr:set_pos(round(cx - m.w / 2), round(cy - m.h / 2))
  if z then m.spr:set_z(z) end
end

-- Split on ASCII space only: Lua's %s is byte-wise and matches 0xA0, the
-- second byte of "à", so "%S+" would cut UTF-8 codepoints in half.
local function split_words(s)
  local out = {}
  for w in string.gmatch(s, "[^ ]+") do out[#out + 1] = w end
  return out
end

-- The icon `bounce`: returns (scale, dy) at elapsed time `el`.
local function breathe(el)
  local B = CFG.BREATHE
  local w = math.sin((el % B.PERIOD) / B.PERIOD * 2 * math.pi)
  return 1.0 + B.AMP * w, -B.HOP_PX * math.max(0, w)
end

-- ---------------------------------------------------------------- resources

-- Top `pool` up to `n` handles of `path`, loading at most `budget`. Returns
-- the unspent budget (0 = call again). A failed load caps the pool, so a
-- missing file is reported once instead of retried every tick.
local function grow(pool, n, path, budget)
  for i = #pool + 1, (pool.capped or n) do
    if budget <= 0 then return 0 end
    local m = measure(load_sprite(path))
    if not m then
      log("W", "load", "pool ", path, " stopped at ", i - 1, " of ", n)
      pool.capped = i - 1
      break
    end
    pool[i] = m
    budget = budget - 1
  end
  return budget
end

-- Handles the visible window needs, per pedestal kind, per icon file, and
-- ticks. A sprite cannot stand in two places, so an icon shown N times needs
-- N handles. The chest's icon comes from the theme, not the icon pools.
local function count_needs(route, vis)
  local base, icon, badges = { stage = 0, egg = 0, chest = 0 }, {}, 0
  for _, v in ipairs(vis) do
    local pt = v.i and route[v.i]
    if pt then
      base[pt.kind] = base[pt.kind] + 1
      if pt.kind ~= "chest" then icon[pt.obj] = (icon[pt.obj] or 0) + 1 end
      if pt.status == "DONE" then badges = badges + 1 end
    end
  end
  return base, icon, badges
end

-- Chest first: it is the day's destination and always on screen.
local BASE_ORDER = { "chest", "stage", "egg" }

local function free_theme(t)
  if not t then return end
  if t.bg then t.bg:destroy() end
  for _, pool in pairs(t.base or {}) do
    for _, m in ipairs(pool) do m.spr:destroy() end
  end
  if t.chest then t.chest.spr:destroy() end
  for _, m in ipairs(t.leaves or {}) do m.spr:destroy() end
end

-- Corner leaves, top-left corner of each 72x64 sprite (poc_journey).
local LEAF_AT = { tl = { -6, -6 }, tr = { 414, -6 }, bl = { -6, 262 }, br = { 414, 262 } }
local LEAF_ORDER = { "tl", "tr", "bl", "br" }

-- Backdrop, chest icon and leaves; the pedestal pools are grown per day.
local function load_theme()
  local t = { base = { stage = {}, egg = {}, chest = {} } }

  local t0 = Timer.millis()
  local ok, bg, err = pcall(Sprite.image, ART .. "map_bg.png")
  span("map_bg.png", t0)
  if not ok or not bg then return nil, "map_bg: " .. tostring(err or bg) end
  bg:set_pos(0, 0)
  bg:set_visible(false)
  bg:set_z(0)
  t.bg = bg

  t.chest = measure(load_sprite(ART .. "map_icon_chest.png"))
  if not t.chest then
    free_theme(t)
    return nil, "map_icon_chest"
  end

  -- Placed once and never moved. A missing leaf is skipped (load_sprite warns).
  t.leaves = {}
  if CFG.LEAVES then
    for _, key in ipairs(LEAF_ORDER) do
      local spr = load_sprite(ART .. "map_leaf_" .. key .. ".png")
      if spr then
        spr:set_pos(LEAF_AT[key][1], LEAF_AT[key][2])
        t.leaves[#t.leaves + 1] = { spr = spr }
      end
    end
  end
  return t
end

-- Connectors: a walked segment drops the dash. Colour is per theme (config).
local LINE_MAX = GEO.MAP_MAX - 1
local LINE_RGB = CFG.LINE_RGB
local LINE_W = 3
local DASH = { 4, 5 }

-- set_z is lv_obj_move_to_index: a child-list index clamped to [0, n-1], so
-- whoever is re-stacked LAST wins, and any z past the end means "topmost".
-- The screen holds only ~30 objects, so NODE_Z and above all land on top.
--
-- A Text has no set_z and stays at its creation index, which sits low in the
-- list (game_start). So the chip's art must be put at a REAL low index, just
-- above the backdrop (0), the leaves and the connectors (1..LINE_MAX): a
-- clamped "top" would cover its own label. place_gop adds the leaf count.
local LINE_Z  = 1
local GOP_Z   = LINE_Z + LINE_MAX
local NODE_Z  = 100
local ICON_Z  = NODE_Z + 10
local BADGE_Z = NODE_Z + 15

-- Node centres for the window, pill shift applied. build_day computes them so
-- the connectors can be rasterised while the art loads.
local function plan_points(vis, route)
  local pts = {}
  for j = 1, #vis do
    local x, y = GEO.place(j, #vis)
    pts[j] = { x = x, y = y }
  end
  GEO.shift_pill(vis, pts, route, CFG.CHIP.W)
  return pts
end

-- A segment is walked when the node it LEADS TO has been reached.
local function walked(seg)
  local b = S.vis[seg + 1]
  return b ~= nil and b.i ~= nil and b.i <= S.cur
end

-- Style before geometry: each setter re-rasterises on its own, and doing the
-- style while the line is still the 1x1 stub makes that pass free. Both keep
-- the OLD shape when refused and skip an unchanged value. Returns the refusal.
local function shape_line(seg)
  local t0 = Timer.millis()
  local ln, a, b = R.lines[seg], S.pts[seg], S.pts[seg + 1]
  local _, err = ln:set_style({ width = LINE_W, color = LINE_RGB, cap = "round",
                                dash = (not walked(seg)) and DASH or nil })
  if not err then
    _, err = ln:set_points(round(a.x), round(a.y), round(b.x), round(b.y))
  end
  span("line", t0)
  return err
end

local function alloc_lines()
  R.lines = {}
  for i = 1, LINE_MAX do
    local ok, ln = pcall(Shape.line, 0, 0, 1, 1,
                         { width = LINE_W, color = LINE_RGB,
                           dash = DASH, cap = "round" })
    if not ok or not ln then return false, "line" .. i end
    ln:set_visible(false)
    R.lines[i] = ln
  end
  return true
end

-- The "+K" chip: one fixed-width pill and one live label. Published to R.gop
-- only when complete. Must run LAST in game_start: its label has to be the
-- newest Text to draw above every other object.
local function alloc_gop()
  local C = CFG.CHIP
  local g = {}

  g.pill = measure(load_sprite(ART .. "map_chip.png"))
  if not g.pill then return false, "map_chip" end

  local t, err = Text.new("", 0, 0)
  if not t then return false, "Text gop: " .. tostring(err) end
  -- A failed face leaves LVGL's built-in font, which has no Vietnamese glyphs.
  local _, fe = t:set_font(C.FONT, C.PX)
  if fe then
    t:destroy()
    return false, "font gop: " .. tostring(fe)
  end
  t:set_color(C.COLOR)
  t:show(false)
  g.text = t

  R.gop = g
  return true
end

-- Centre the chip on its anchor. Left hidden: reveal_map shows it.
local function place_gop(n, cx, cy)
  local g, C = R.gop, CFG.CHIP
  if not g then return end

  local x = round(cx - C.W / 2)
  local y = round(cy - C.H / 2)
  g.pill.spr:set_pos(x, y)
  g.pill.spr:set_z(GOP_Z + #R.theme.leaves)

  -- align() centres on the SCREEN with LVGL's own measured size; the offset
  -- moves it to the chip's centre. A failed align parks the label at (0,0),
  -- so it is kept hidden instead.
  g.text:set("+" .. n .. (CFG.CHIP_TEXT[LANG] or CFG.CHIP_TEXT.vi))
  local _, ae = g.text:align("center",
                             round(cx - CFG.SCREEN_W / 2),
                             round(y + C.H / 2 - CFG.SCREEN_H / 2))
  if ae then
    log("W", "map", "gop align failed: ", ae)
    g.text:show(false)
  end
  g.text_ok = not ae
end

local function hide_gop()
  local g = R.gop
  if not g then return end
  g.pill.spr:set_visible(false)
  g.text:show(false)
end

-- ---------------------------------------------------------------- the day

local function is_reward(pt)
  return pt.kind == "egg" or pt.kind == "chest"
end

-- checkpoints[i] -> one route point. Server fields are carried verbatim so the
-- report can echo the ids back; nothing is renumbered.
local function map_checkpoint(cp)
  -- A JSON null inside the array arrives as nil.
  if type(cp) ~= "table" then cp = {} end

  local cat = cp.category
  if type(cat) ~= "string" then cat = CFG.CAT_FALLBACK end

  local kind, obj
  if cat == CFG.CAT_FINAL_REWARD then
    kind = "chest"
  elseif cat == CFG.CAT_MID_REWARD then
    kind, obj = "egg", "map_icon_egg"
  else
    kind = "stage"
    if not CFG.CAT[cat] then
      log_once("cat:" .. cat, "W", "day", "unknown category '", cat, "' -> ", CFG.CAT_FALLBACK)
      cat = CFG.CAT_FALLBACK
    end
    obj = CFG.CAT[cat].obj
  end

  local st = cp.status
  if st ~= "TODO" and st ~= "IN_PROGRESS" and st ~= "DONE" and st ~= "SKIPPED" then
    if st ~= nil then
      log_once("st:" .. tostring(st), "W", "day", "unknown status '", st, "' -> TODO")
    end
    st = "TODO"
  end

  -- The greyed icon; pools are keyed by file, so it loads only when needed.
  if kind == "stage" and st == "SKIPPED" then
    obj = obj .. CFG.SKIP.ICON_SUFFIX
  end

  -- Why the node cannot be opened (nil: it can). There must still be
  -- something to report: DONE/SKIPPED have their socket nulled by contract,
  -- a lesson needs the item_id detail.enter carries, a reward the game_id
  -- map.pick carries.
  local shut
  if st == "DONE" or st == "SKIPPED" then
    shut = st
  elseif kind == "stage" then
    shut = (cp.item_id == nil and "no item_id")
        or (cp.socket_url == nil and "no socket_url") or nil
  elseif cp.game_id == nil then
    shut = "no game_id"
  end

  return {
    kind = kind, obj = obj, cat = cat,
    index   = cp.index,
    item_id = cp.item_id,
    game_id = cp.game_id,
    ms      = cp.milestone_index,
    name    = (type(cp.name) == "string") and cp.name or nil,
    -- BE's display text for the lesson's group; nil on rewards.
    label   = (type(cp.category_label) == "string" and cp.category_label ~= "")
              and cp.category_label or nil,
    status  = st,
    openable = (shut == nil),
    shut    = shut,
  }
end

-- ---------------------------------------------------------------- layout

-- Hide every handle before a layout claims what it needs, or a pedestal from
-- the previous layout keeps standing under a node that no longer exists.
local function hide_all()
  local t = R.theme
  if t then
    for _, pool in pairs(t.base) do
      for _, m in ipairs(pool) do m.spr:set_visible(false) end
    end
    if t.chest then t.chest.spr:set_visible(false) end
  end
  for _, pool in pairs(R.icon or {}) do
    for _, m in ipairs(pool) do m.spr:set_visible(false) end
  end
  for _, m in ipairs(R.badges or {}) do m.spr:set_visible(false) end
  for _, ln in ipairs(R.lines or {}) do ln:set_visible(false) end
  hide_gop()
end

-- Place the day over whatever handles are in hand. Everything is left hidden;
-- reveal_map shows it. Handles come from the per-kind pools by a running
-- count, in window order -- the order count_needs sized them in.
local function layout()
  hide_all()

  local route, cur, vis = S.route, S.cur, S.vis

  -- Re-stacked every layout: the connectors were created after the backdrop.
  R.theme.bg:set_z(0)
  R.theme.bg:set_visible(true)

  -- All connectors in this one tick: a raster re-stacks its sprite, and every
  -- re-stack repaints the WHOLE screen, so spreading them over ticks cost one
  -- full repaint each (~160 ms). Here they share the repaint this layout's
  -- own set_z calls trigger. A refused line is hidden, not drawn stale.
  local pts = S.pts
  S.dots = {}
  for seg = 1, #pts - 1 do
    local ln = R.lines[seg]
    if ln then
      local err = shape_line(seg)
      if err then
        log("W", "map", "line ", seg, " refused: ", err)
      else
        ln:set_z(LINE_Z)
        S.dots[#S.dots + 1] = { line = ln, seg = seg, done = walked(seg) }
      end
    end
  end
  -- After the connectors, at their index: each leaf pushes them up one, so
  -- the leaves end up just above the backdrop and under every line.
  for _, m in ipairs(R.theme.leaves) do m.spr:set_z(LINE_Z) end

  S.nodes = {}
  S.pill = nil
  local used = { stage = 0, egg = 0, chest = 0 }
  local icon_used = {}
  local badge_used = 0

  for j = 1, #vis do
    local v, p = vis[j], pts[j]
    if v.gop then
      place_gop(v.gop, p.x, p.y)
      S.pill = true
    else
      local pt = route[v.i]
      local kind = pt.kind

      used[kind] = used[kind] + 1
      local base = R.theme.base[kind][used[kind]]

      local icon
      if kind == "chest" then
        icon = R.theme.chest
      else
        icon_used[pt.obj] = (icon_used[pt.obj] or 0) + 1
        local pool = R.icon[pt.obj]
        icon = pool and pool[icon_used[pt.obj]]
      end

      -- Any DONE node, reward or lesson, trades its icon for the tick: a
      -- claimed egg or chest otherwise looks exactly like one still ahead.
      local badge
      if pt.status == "DONE" then
        badge_used = badge_used + 1
        badge = R.badges[badge_used]
        if not badge then log_once("badge", "W", "map", "no tick handle (#", badge_used, ")") end
      end
      if not base then log_once("base:" .. kind, "W", "map", "no ", kind, " pedestal (#", used[kind], ")") end
      if not icon then log_once("icon:" .. pt.obj, "W", "map", "no ", pt.obj, " handle (node ", j, ")") end

      put(base, p.x, p.y + GEO.OFF[kind].BASE_DY, NODE_Z)
      S.nodes[#S.nodes + 1] = {
        base = base, icon = icon, badge = badge,
        x = p.x, y = p.y, kind = kind, idx = v.i,
      }
    end
  end

  -- Stacked once, here: set_z is lv_obj_move_to_index, which repaints the
  -- whole screen whenever the index changes.
  for i = 1, #S.nodes do
    local n = S.nodes[i]
    if n.icon then n.icon.spr:set_z(ICON_Z) end
  end
  for i = 1, #S.nodes do
    local n = S.nodes[i]
    if n.badge then n.badge.spr:set_z(BADGE_Z) end
  end

  -- The one node that keeps moving once shown: the bounce invites a
  -- press, so only a node confirm can open moves. nil when the current node
  -- is not openable (DONE shows a tick; SKIPPED or missing ids does nothing
  -- on confirm) or has no icon, and on_tick then does nothing.
  S.breather = nil
  for i = 1, #S.nodes do
    local n = S.nodes[i]
    if n.idx == cur and n.icon and route[cur].openable then
      S.breather = n
      break
    end
  end
end

-- ---------------------------------------------------------------- render

-- Show the whole map in one pass, in the tick that laid it out (or left the
-- detail screen). That tick already repaints the full screen -- layout()
-- re-stacks the backdrop -- so revealing everything there rides on a repaint
-- already paid for. A staggered reveal cost ~1.6 s more and one partial
-- redraw per object. The breathing node is left at rest; render_breath moves
-- it from the next tick on.
-- What the child actually sees, once per session when the map first shows.
-- warn: a narration line came from the pack, not the server, or art is missing.
local function send_map_frame()
  local done = 0
  for _, pt in ipairs(S.route) do
    if pt.status == "DONE" then done = done + 1 end
  end
  local fb, failed = S.narr_fb or 0, S.sprite_failed or 0
  local sent = tel.event("map.frame", {
    n = #S.route, done = done, cur = S.cur,
    remote = S.narr_remote or 0, fb = fb, failed = failed,
  }, (fb > 0 or failed > 0) and { level = "warn" } or nil)
  log("I", "tel", "map.frame sent=", sent)
end

local function reveal_map(now)
  if S.pill and R.gop then
    local g = R.gop
    g.pill.spr:set_opacity(255)
    g.pill.spr:set_visible(true)
    if g.text_ok then g.text:show(true) end
  end

  R.theme.bg:set_visible(true)
  for _, m in ipairs(R.theme.leaves) do m.spr:set_visible(true) end
  for _, d in ipairs(S.dots or {}) do
    d.line:set_opacity(d.done and CFG.DOT.OPA_DONE or CFG.DOT.OPA_TODO)
    d.line:set_visible(true)
  end

  for _, n in ipairs(S.nodes or {}) do
    local pt = S.route[n.idx]
    if n.base then
      n.base.spr:set_opacity(255)
      n.base.spr:set_visible(true)
    end
    -- A DONE node shows its tick instead of its icon.
    if pt.status == "DONE" and n.badge then
      put(n.badge, n.x, n.y + GEO.OFF[n.kind].BADGE_DY)
      n.badge.spr:set_opacity(255)
      n.badge.spr:set_visible(true)
    elseif n.icon then
      put(n.icon, n.x, n.y + GEO.OFF[n.kind].OBJ_DY)
      if not n.icon.fixed then n.icon.spr:set_scale(256) end
      n.icon.spr:set_opacity((pt.status == "SKIPPED") and CFG.SKIP.OPA or 255)
      n.icon.spr:set_visible(true)
    end
    n.breath_x, n.breath_y, n.breath_scale = nil, nil, nil
  end

  S.shown = true
  if S.held then
    S.held = false
    Engine.show()   -- the screen goes up after this hook, all in one frame
  end
  if not S.map_ready_ms then
    S.map_ready_ms = now - S.start_t0
    log("I", "map", "shown")
    send_map_frame()
  end
end

-- Steady state: only the breathing icon moves (reveal_map showed it). set_pos/set_scale redraw even an unchanged value, so the last written
-- ints are cached and a repeat is skipped.
local function render_breath(el)
  local n = S.breather
  if not n then return end
  local k, dy = breathe(el)
  local x = round(n.x - n.icon.w / 2)
  local y = round(n.y + GEO.OFF[n.kind].OBJ_DY + dy - n.icon.h / 2)
  if n.breath_x ~= x or n.breath_y ~= y then
    n.icon.spr:set_pos(x, y)
    n.breath_x, n.breath_y = x, y
  end
  if not n.icon.fixed then
    local scale = round(256 * k)
    if n.breath_scale ~= scale then
      n.icon.spr:set_scale(scale)
      n.breath_scale = scale
    end
  end
end

-- ---------------------------------------------------------------- detail
--
-- The activity detail screen (the demo's dungDetail), drawn over the map.
-- Rewards never open it: they report map.pick straight away.

-- STACKING IS CREATION ORDER, with no set_z at all. A clamped set_z lands on
-- top of the child list -- above the labels, which have no set_z -- and that
-- is how the backdrop once hid every word on this screen. So the sprites are
-- created bottom-up (backdrop, pedestal, hero, box, rail, cells) and the
-- labels are re-created last on every entry (refresh_detail_labels). The map
-- is hidden while this screen is up, so its sprites' order does not matter.

-- Four lesson cells and the reward, always, so the numbers stay readable
-- across the room; the chip comes on top while lessons are left. A day with
-- fewer lessons shows what it has. Numbers never read past 99.
local BAR_LESSON_CELLS = 4
local BAR_NUM_MAX      = 99

local function cell_width(c)
  local B = CFG.D.BAR
  if c.kind == "cur"  then return B.W_CUR end
  if c.kind == "anchor" then return B.W_GIFT end
  if c.kind == "chip" then return c.wide and B.W_CHIP_WIDE or B.W_CHIP end
  return B.W_DONE
end

-- The bar row: the road to the next reward. Lesson cells numbered in route
-- order, the reward (anchor), and a "còn N bài" chip.
local function build_bar_cells()
  -- The anchor is the nearest unclaimed reward AHEAD of the child (one they
  -- walked past is not coming), else the day's last checkpoint when that is a
  -- reward. A day with no reward (off-contract) has no anchor cell.
  local anchor, anchor_i = nil, #S.route
  for i = S.cur, #S.route do
    local pt = S.route[i]
    if is_reward(pt) and pt.status ~= "DONE" then anchor, anchor_i = pt, i break end
  end
  if not anchor and is_reward(S.route[#S.route]) then anchor = S.route[#S.route] end

  -- Only the lessons before the anchor: one past it would be drawn on the
  -- wrong side of the reward. `n` still counts the whole day. With no anchor
  -- every lesson is kept.
  local upto = anchor and (anchor_i - 1) or #S.route
  local cells, lessons, n = {}, {}, 0
  for i = 1, #S.route do
    local pt = S.route[i]
    if not is_reward(pt) then
      n = n + 1
      if i <= upto then lessons[#lessons + 1] = { i = i, n = n, pt = pt } end
    end
  end

  -- The chip counts the same leg: open lessons from the cursor on, the
  -- current one included.
  local remaining = 0
  for _, l in ipairs(lessons) do
    if l.i >= S.cur and (l.pt.status == "TODO" or l.pt.status == "IN_PROGRESS") then
      remaining = remaining + 1
    end
  end

  -- SKIPPED keeps its number and fades, like a skipped node on the map; only
  -- DONE earns a tick.
  local function cell_for(l)
    local num = math.min(l.n, BAR_NUM_MAX)
    if l.i == S.cur then return { kind = "cur", num = num } end
    if l.pt.status == "SKIPPED" then return { kind = "todo", num = num, dim = true } end
    if l.pt.status == "DONE" then return { kind = "done" } end
    return { kind = "todo", num = num }
  end

  if #lessons <= BAR_LESSON_CELLS then
    for _, l in ipairs(lessons) do cells[#cells + 1] = cell_for(l) end
  else
    -- A window of BAR_LESSON_CELLS lessons with the child on the second, so
    -- the lesson just walked shows; the lessons left out are only counted by
    -- the chip. At the end the window stops at the reward and the child moves
    -- right. A cursor on a reward shows the tail.
    local cur_n = nil
    for _, l in ipairs(lessons) do
      if l.i == S.cur then cur_n = l.n break end
    end
    local last_first = #lessons - BAR_LESSON_CELLS + 1
    local first = cur_n and (cur_n - 1) or last_first
    first = clamp(first, 1, last_first)

    for k = first, first + BAR_LESSON_CELLS - 1 do cells[#cells + 1] = cell_for(lessons[k]) end
  end

  if anchor then cells[#cells + 1] = { kind = "anchor", pt = anchor } end
  -- `left`, not `num`: `num` routes a cell through the digit sprites. The
  -- chip only takes a slot when it has a count to show.
  if remaining > 0 then
    cells[#cells + 1] = { kind = "chip", wide = (remaining >= 10),
                          left = math.min(remaining, BAR_NUM_MAX) }
  end
  return cells
end

-- One PNG per digit, every glyph padded to the widest ("0"). ADV is each
-- glyph's real advance.
local NUM_ATLAS = {
  [false] = { fmt = "bar_num_%d.png",
              ADV = { 7, 4, 6, 6, 7, 6, 7, 6, 7, 7 } },
  [true]  = { fmt = "bar_num_cur_%d.png",
              ADV = { 9, 5, 8, 8, 8, 8, 9, 7, 9, 9 } },
}

local function d_num_sprites(num, cx, cy, big, opa)
  local s = tostring(num)
  local A = NUM_ATLAS[big and true or false]
  local recs, total = {}, 0
  for k = 1, #s do
    local d = tonumber(s:sub(k, k))
    local m = d and measure(load_sprite(ART .. string.format(A.fmt, d)))
    if m then
      m.adv = A.ADV[d + 1] or m.w
      recs[#recs + 1] = m
      total = total + m.adv
    end
  end
  total = total + CFG.D.BAR.NUM_GAP * math.max(0, #recs - 1)
  local x = cx - total / 2
  for k = 1, #recs do
    local m = recs[k]
    -- Centre the INK, not the padded frame, on its advance.
    m.spr:set_pos(round(x - (m.w - m.adv) / 2), round(cy - m.h / 2))
    if opa then m.spr:set_opacity(opa) end
    R.d.cells[#R.d.cells + 1] = m
    x = x + m.adv + CFG.D.BAR.NUM_GAP
  end
end

-- Build the bar for the current day, tearing down the previous one.
local function build_bar()
  local B = CFG.D.BAR

  for _, m in ipairs(R.d.segs) do m.spr:destroy() end
  for _, m in ipairs(R.d.cells) do m.spr:destroy() end
  for _, spr in ipairs(R.d.rails) do spr:destroy() end
  R.d.segs, R.d.cells, R.d.rails = {}, {}, {}

  local cells = build_bar_cells()
  -- e.g. "bar done 2~ (3) ... chest left=2": the row as the child sees it
  -- ((n) current, n~ skipped).
  local desc = {}
  for _, c in ipairs(cells) do
    desc[#desc + 1] = (c.kind == "cur" and "(" .. c.num .. ")")
                   or (c.num and (c.num .. (c.dim and "~" or "")))
                   or (c.kind == "anchor" and c.pt.kind)
                   or (c.kind == "chip" and "left=" .. c.left)
                   or c.kind
  end
  log("I", "bar", table.concat(desc, " "))

  local total = 0
  for i = 1, #cells do total = total + cell_width(cells[i]) end
  total = total + B.CELL_GAP * (#cells - 1) + B.BOX_PAD * 2
  local box_x = (CFG.SCREEN_W - total) / 2

  local cap_l = measure(load_sprite(ART .. "bar_box_l.png"))
  local cap_r = measure(load_sprite(ART .. "bar_box_r.png"))
  if not (cap_l and cap_r) then return false, "bar_box cap" end
  cap_l.spr:set_pos(round(box_x), B.BOX_TOP)
  cap_r.spr:set_pos(round(box_x + total - cap_r.w), B.BOX_TOP)
  R.d.segs[1], R.d.segs[2] = cap_l, cap_r

  -- Sprite.solid raises on a size outside (0,480]x(0,320]: clamp, never trust.
  local mid_w = math.max(0, total - B.CAP_W * 2)
  if mid_w > 0 then
    local w = clamp(round(mid_w), 1, CFG.SCREEN_W)
    local ok, spr = pcall(Sprite.solid, w, cap_l.h, B.MID_565)
    if not ok or not spr then return false, "qbox mid" end
    spr:set_pos(round(box_x + B.CAP_W), B.BOX_TOP)
    spr:set_opacity(B.MID_OPA)
    spr:set_visible(false)
    R.d.segs[#R.d.segs + 1] = { spr = spr, w = w, h = cap_l.h, fixed = true }
  end

  -- Cell centres first: the rail is strung between them and must be created
  -- BEFORE the cells so it draws under them.
  local mid = {}
  local x = box_x + B.BOX_PAD
  for i = 1, #cells do
    local w = cell_width(cells[i])
    mid[i] = x + w / 2
    x = x + w + B.CELL_GAP
  end

  -- One rail from the first cell's centre to the anchor's (the last lesson's
  -- when the day has no reward; never the chip's): the lessons and the reward
  -- read as one road.
  local last = nil
  for i = 1, #cells do
    if cells[i].kind == "anchor" then last = i break end
  end
  if not last then
    for i = #cells, 1, -1 do
      if cells[i].kind ~= "chip" then last = i break end
    end
  end
  if last and last > 1 then
    local w = clamp(round(mid[last] - mid[1]), 1, CFG.SCREEN_W)
    local ok, spr = pcall(Sprite.solid, w, B.RAIL_H, B.RAIL_565)
    if not ok or not spr then return false, "bar rail" end
    spr:set_pos(round(mid[1]), B.RAIL_Y)
    spr:set_opacity(B.RAIL_OPA)
    spr:set_visible(false)
    R.d.rails[1] = spr
  end

  R.d.chip_at = nil
  for i = 1, #cells do
    local c = cells[i]
    local cx = mid[i]
    -- The map's egg/chest are too big to scale into a 32px slot, so each
    -- reward kind has its own pre-shrunk bar icon.
    local art
    if c.kind == "anchor" then
      art = (c.pt.kind == "chest") and "bar_chest.png" or "bar_gift.png"
    else
      art = (c.kind == "done") and "bar_done.png"
         or (c.kind == "cur")  and "bar_cur.png"
         or (c.kind == "todo") and "bar_todo.png"
         or (c.wide and "bar_chip_wide.png" or "bar_chip.png")
    end
    local m = measure(load_sprite(ART .. art))
    if not m then return false, art end
    m.spr:set_pos(round(cx - m.w / 2), round(B.CY - m.h / 2))
    local opa = c.dim and CFG.SKIP.OPA or nil
    if opa then m.spr:set_opacity(opa) end
    R.d.cells[#R.d.cells + 1] = m
    if c.num then d_num_sprites(c.num, cx, B.CY, c.kind == "cur", opa) end

    -- The phrase goes on the chip label, which is re-created after this
    -- (refresh_detail_labels): record it here, write it there.
    if c.kind == "chip" then
      local t = B.CHIP_TEXT[LANG] or B.CHIP_TEXT.vi
      R.d.chip_at = { text = t.pre .. tostring(c.left) .. t.post, cx = cx }
    end
  end
  return true
end

-- Built lazily on detail entry, and only when the day changed. Cleared before
-- the attempt so a failing build is not retried on every press.
local function ensure_bar()
  if not S.bar_stale then return end
  S.bar_stale = false
  local t0 = Timer.millis()
  local ok, which = build_bar()
  span("bar", t0)
  if not ok then log("W", "bar", "build failed: ", which) end
end

-- The detail screen's labels. The name takes one label per line: a label has
-- no text-align, so a short second line of a multi-line one would sit off
-- centre. `name` labels take the lesson's name size. Shadows come before
-- their names: creation order is stacking order.
local NAME_SH = CFG.D.SHADOW.COLOR[CFG.D.PROG_FALLBACK]
local DETAIL_LABELS = {
  { key = "loai",     px = CFG.D.LOAI.PX,     color = CFG.D.COLOR.LOAI },
  { key = "name_sh",  px = CFG.D.NAME.PX,     color = NAME_SH, name = true },
  { key = "name2_sh", px = CFG.D.NAME.PX,     color = NAME_SH, name = true },
  { key = "name",     px = CFG.D.NAME.PX,     color = CFG.D.COLOR.NAME, name = true },
  { key = "name2",    px = CFG.D.NAME.PX,     color = CFG.D.COLOR.NAME, name = true },
  { key = "chip",     px = CFG.D.BAR.CHIP_PX, color = CFG.D.BAR.CHIP_COLOR },
}

local function new_label(spec, px)
  local t, e = Text.new("", 0, 0)
  if not t then return nil, "Text " .. spec.key .. ": " .. tostring(e) end
  local _, fe = t:set_font(CFG.D.FONT_BLACK, px or spec.px)
  if fe then
    t:destroy()
    return nil, "font " .. spec.key .. ": " .. tostring(fe)
  end
  t:set_color(spec.color)
  t:show(false)
  return t
end

-- Created in game_start so a font failure stops the pack at load, not on the
-- child's first press. The small name face is probe_small_name_face's.
local function load_detail_labels()
  R.d = { cells = {}, segs = {}, rails = {}, hero = {}, bg_failed = {} }
  for _, spec in ipairs(DETAIL_LABELS) do
    local t, err = new_label(spec)
    if not t then return false, err end
    R.d[spec.key] = t
  end
  return true
end

-- Probe the small name face once every other face is pinned (after the gop
-- chip): with fewer slots than faces it fails HERE, not on the first long
-- name, and the pack degrades instead of drawing two lines that overflow.
local function probe_small_name_face()
  local probe, err = new_label({ key = "name_small", color = CFG.D.COLOR.NAME },
                               CFG.D.NAME.SMALL.PX)
  R.d.small_ok = probe ~= nil
  if probe then
    probe:destroy()
  else
    log("W", "boot", "small name face unavailable (", err, "): long names cut to one line")
  end
end

-- Re-create the labels so they are the newest objects, above every detail
-- sprite. New before old: the old label keeps its face pinned in the font
-- cache, so the new one reuses it (8 of GAME_TEXT_SLOTS 8 at the peak). On
-- failure the old label is kept: present, even if a sprite may cover it.
-- `name_px` is this lesson's name size (NAME.PX or NAME.SMALL.PX).
local function refresh_detail_labels(name_px)
  local t0 = Timer.millis()
  for _, spec in ipairs(DETAIL_LABELS) do
    local t, err = new_label(spec, spec.name and name_px or nil)
    if t then
      R.d[spec.key]:destroy()
      R.d[spec.key] = t
    else
      log("W", "detail", "label refresh failed: ", err)
    end
  end
  span("labels", t0)
end

-- The programme backdrop for a checkpoint (CAT[].prog).
local function prog_of(pt)
  local row = pt and (CFG.CAT[pt.cat] or CFG.CAT[CFG.CAT_FALLBACK])
  return (row and row.prog) or CFG.D.PROG_FALLBACK
end

-- Pedestal once, and the backdrop for `prog` (nil: not yet known). Failures
-- are latched so a missing file is not re-read per press; the screen then
-- degrades to whatever did load. Returns true when it read the card.
local function ensure_detail(prog)
  local D = CFG.D
  local loaded = false

  if not R.d.base_tried then
    R.d.base_tried = true
    loaded = true
    R.d.base = measure(load_sprite(ART .. "det_base.png"))
    put(R.d.base, D.HERO_X, D.HERO_Y)
  end

  if prog and R.d.bg_prog ~= prog and not R.d.bg_failed[prog] then
    loaded = true
    -- Freed first: two resident backdrops would hold 900KB of PSRAM.
    if R.d.bg then R.d.bg:destroy() end
    R.d.bg, R.d.bg_prog = nil, nil
    local path = string.format(D.BG_FMT, prog)
    local t0 = Timer.millis()
    local ok, bg, err = pcall(Sprite.image, ART .. path)
    span(path, t0)
    if ok and bg then
      bg:set_pos(0, 0)
      bg:set_visible(false)
      -- Loaded after the pedestal (and on a swap, the hero): send it under them.
      bg:to_back()
      R.d.bg, R.d.bg_prog = bg, prog
    else
      R.d.bg_failed[prog] = true
      log("W", "detail", "backdrop failed: ", path, " -- ", err or bg)
    end
  end

  return loaded
end

-- One hero per file, loaded the first time its category is opened.
local function ensure_hero(name)
  if not name then return end
  local m = R.d.hero[name]
  if m then return end
  m = measure(load_sprite(ART .. name .. ".png"))
  if m then R.d.hero[name] = m end
end

-- Wrap a lesson name to at most MAX_LINES by estimated width. Returns the
-- lines, one per label.
local function wrap_name(s, px)
  local D = CFG.D
  local limit = CFG.SCREEN_W - D.CHU.PAD_X * 2
  local max_chars = math.max(1, math.floor(limit / (px * D.AVG_CHAR_K)))

  local lines, cur = {}, ""
  for _, w in ipairs(split_words(s)) do
    local probe = (cur == "") and w or (cur .. " " .. w)
    -- Characters, not bytes; invalid UTF-8 (nil) counts bytes, erring wide.
    if (utf8.len(probe) or #probe) <= max_chars or cur == "" then
      cur = probe
    else
      lines[#lines + 1] = cur
      cur = w
      if #lines >= D.NAME.MAX_LINES then break end
    end
  end
  if cur ~= "" and #lines < D.NAME.MAX_LINES then lines[#lines + 1] = cur end
  if #lines == 0 then lines[1] = s end
  return lines
end

-- Visibility only: the stacking comes from creation order (see above). The
-- hero is shown by detail_enter once it is placed.
local function detail_show()
  if R.d.bg then R.d.bg:set_visible(true) end
  for _, m in ipairs(R.d.segs) do m.spr:set_visible(true) end
  for _, spr in ipairs(R.d.rails) do spr:set_visible(true) end
  for _, m in ipairs(R.d.cells) do m.spr:set_visible(true) end
  if R.d.base then R.d.base.spr:set_visible(true) end
  -- A label whose align failed sits at (0,0): it stays hidden.
  for _, spec in ipairs(DETAIL_LABELS) do
    R.d[spec.key]:show(R.d[spec.key .. "_ok"] or false)
  end
end

-- Hide the map under the detail screen. S.nodes is read defensively: the
-- watchdog can abort layout() halfway and leave it unset.
local function map_hide()
  R.theme.bg:set_visible(false)
  for _, m in ipairs(R.theme.leaves) do m.spr:set_visible(false) end
  for _, ln in ipairs(R.lines) do ln:set_visible(false) end
  for _, n in ipairs(S.nodes or {}) do
    if n.base then n.base.spr:set_visible(false) end
    if n.icon then n.icon.spr:set_visible(false) end
    if n.badge then n.badge.spr:set_visible(false) end
  end
  hide_gop()
  S.shown = false
end

-- ------------------------------------------------------ hands-free advance

-- Arm the timer for the screen just opened. `alias` is the line now sounding,
-- or nil for a silent screen, which counts from now. Never disarmed: every
-- screen moves on by itself, a press only gets there sooner.
local function auto_arm(alias)
  S.auto_alias = alias
  S.auto_by_cap = false
  local now = Timer.millis()
  S.auto_t_end = (not alias) and now or nil
  S.auto_t_cap = alias and (now + AUTO_SOUND_CAP_MS) or now
end

-- True once the line has been over for `after_ms` (AUTO_AFTER_SOUND_MS when
-- nil), by the finish event or, failing that, the cap.
local function auto_due(now, after_ms)
  local base = S.auto_t_end
  if not base and S.auto_t_cap and now >= S.auto_t_cap then
    log("W", "narr", "no sound-end for ", S.auto_alias, ", advancing on the cap")
    base = S.auto_t_cap
    S.auto_t_end = base
    S.auto_by_cap = true
  end
  return base ~= nil and (now - base) >= (after_ms or AUTO_AFTER_SOUND_MS)
end

-- The packaged alias standing in for narration line `name`, or nil.
local function fallback_of(name)
  local fb = FALLBACK[name]
  return fb and (fb[LANG] or fb.vi)
end

-- Play a narration line, its packaged line if play() refuses the remote one.
-- Returns the alias only if it actually started; S.narr_now remembers it so
-- an ERROR finish can fall back.
local function narrate(name)
  local alias = S.narration[name]
  if not alias then return nil end
  local t0 = Timer.millis()
  local played = Speaker.play(alias)
  local fb = fallback_of(name)
  if not played and fb and fb ~= alias then
    log("W", "narr", "play refused: ", alias, " -> ", fb)
    S.narration[name] = fb
    alias = fb
    played = Speaker.play(alias)
  end
  span("play", t0)
  if not played then
    log("W", "narr", "play refused: ", alias)
    return nil
  end
  log("I", "narr", "play ", alias, (alias ~= name) and (" for " .. name) or "")
  S.narr_now = { name = name, alias = alias }
  return alias
end

-- Stop our own line by its request only. Never Speaker.stop_all: it is
-- queued, lands AFTER a play issued in the same hook and clears the audio
-- queue, so it killed the line that followed it.
local function hush()
  local n = S.narr_now
  S.narr_now = nil
  S.narr_queue = nil
  if n and Speaker.is_playing(n.alias) then
    local t0 = Timer.millis()
    Speaker.stop(n.alias)
    span("stop", t0)
  end
end

-- Say the line(s) for the screen just opened: one name or a list said in
-- order. A line with nothing to play is skipped; the countdown waits on the
-- last one that sounds. The new play queues behind the one hush() stopped
-- (both HIGH) and starts once that stop lands.
local function narrate_next()
  local q = S.narr_queue
  while q and #q > 0 do
    local alias = narrate(table.remove(q, 1))
    if alias then return alias end
  end
  S.narr_queue = nil
  return nil
end

local function say(lines)
  hush()
  S.narr_queue = type(lines) == "table" and { table.unpack(lines) } or { lines }
  auto_arm(narrate_next())
end

-- The line the countdown waits on is over; move on to the next queued one,
-- or start the countdown when the queue is empty.
local function narration_over(alias)
  if alias ~= S.auto_alias then return end
  if S.narr_queue and not S.exiting then
    local nxt = narrate_next()
    if nxt then
      auto_arm(nxt)
      return
    end
  end
  S.auto_t_end = S.auto_t_end or Timer.millis()
end

-- ---------------------------------------------------------------- detail flow

-- Pedestal and the current checkpoint's backdrop (~200 ms), loaded before the
-- map shows by pump_load, or early by the idle wait on a late frame. Hero and
-- bar depend on S.cur and load on the press instead (detail_enter): prewarmed,
-- they held the first checkpoint back by ~250 ms. Returns true when it loaded.
local function prewarm_detail()
  local prog = S.route and prog_of(S.route[S.cur]) or nil
  local t0 = Timer.millis()
  local loaded = ensure_detail(prog)
  if loaded then span("warm", t0) end
  return loaded
end

local function detail_enter(idx, via)
  local pt = S.route[idx]
  if not pt or is_reward(pt) then return end

  local row = CFG.CAT[pt.cat] or CFG.CAT[CFG.CAT_FALLBACK]
  S.d_idx = idx
  -- Kept, not re-read on confirm: a later frame may reorder the route under
  -- this screen, and the report must name the lesson the child is looking at.
  S.d_item = pt.item_id
  S.d_hero = row.hero
  S.detail_breath_cy = nil

  -- Normally prewarmed; whatever is still missing loads here, before anything
  -- is shown, in stacking order: backdrop and pedestal, hero, bar, labels.
  local t0 = Timer.millis()
  local prog = prog_of(pt)
  ensure_detail(prog)
  ensure_hero(row.hero)
  ensure_bar()

  local D = CFG.D
  -- category_label is shown as BE sends it, in every language; the table is
  -- only the fallback for a node that carries none.
  local loai_txt = pt.label or row.loai[LANG] or row.loai.vi

  -- The name is set large when it fits on one line, and smaller when it needs
  -- two, so the block never outgrows the band (config.lua, NAME).
  local name_src = pt.name or loai_txt
  local name_px, name_line_h = D.NAME.PX, D.NAME.LINE
  local lines = wrap_name(name_src, name_px)
  if #lines > 1 and R.d.small_ok then
    name_px, name_line_h = D.NAME.SMALL.PX, D.NAME.SMALL.LINE
    lines = wrap_name(name_src, name_px)
  elseif #lines > 1 then
    lines = { lines[1] .. "..." }   -- two lines at NAME.PX overflow the band
  end

  refresh_detail_labels(name_px)

  -- Centre the label + name block in the band.
  local name_h = name_line_h * #lines
  local top = round(D.CHU.TOP
            + ((D.CHU.BOTTOM - D.CHU.TOP) - (D.LOAI.LINE + D.CHU.GAP + name_h)) / 2)

  -- align() centres on the SCREEN; the offset moves a label onto its row.
  -- Each label records whether it landed (detail_show hides one that did not).
  local function place(key, text, how, dx, dy)
    local t = R.d[key]
    t:set(text)
    local _, ae = t:align(how, dx, dy)
    if ae then log("W", "detail", key, " align failed: ", ae) end
    R.d[key .. "_ok"] = not ae
    return not ae
  end

  place("loai", loai_txt, "center", 0, round(top + D.LOAI.LINE / 2 - CFG.SCREEN_H / 2))

  local shadow = D.SHADOW.COLOR[prog] or D.SHADOW.COLOR[D.PROG_FALLBACK]
  local name_top = top + D.LOAI.LINE + D.CHU.GAP
  R.d.name2_ok, R.d.name2_sh_ok = false, false
  for i, text in ipairs(lines) do
    local key = (i == 1) and "name" or "name2"
    local y = name_top + name_line_h * (i - 1)
    R.d[key .. "_sh"]:set_color(shadow)
    place(key .. "_sh", text, "top", 0, y + D.SHADOW.DY)
    place(key, text, "top", 0, y)
  end

  R.d.chip_ok = false
  local chip = R.d.chip_at
  if chip then
    place("chip", chip.text, "center", round(chip.cx - CFG.SCREEN_W / 2),
          round(D.BAR.CY - CFG.SCREEN_H / 2))
  end

  map_hide()
  detail_show()
  local hero = row.hero and R.d.hero[row.hero]
  if hero then
    put(hero, D.HERO_X, D.HERO_Y + D.ICON_DY)
    hero.spr:set_opacity(255)
    hero.spr:set_visible(true)
  end
  S.view = "detail"
  S.d_t0 = Timer.millis()
  log("I", "detail", "node ", idx, " ", pt.cat, " ready in ", S.d_t0 - t0,
      " ms, name ", name_px, "px x", #lines)

  say(NARRATION_DETAIL)
  span("detail_enter", t0)

  local sent = tel.event("map.card", { cat = pt.cat, via = via })
  log("I", "tel", "map.card sent=", sent)
end

-- Position only, and only when the rounded centre moves: set_pos redraws
-- even an unchanged value, and set_z would repaint the pedestal every tick.
local function render_detail(el)
  local icon = S.d_hero and R.d.hero[S.d_hero]
  if not icon then return end
  local _, dy = breathe(el)
  local cy = round(CFG.D.HERO_Y + CFG.D.ICON_DY + dy)
  if S.detail_breath_cy ~= cy then
    put(icon, CFG.D.HERO_X, cy)
    S.detail_breath_cy = cy
  end
end

-- ---------------------------------------------------------------- perf

-- Tick rate and worst frame gap per phase: the robot's own measure of
-- stutter, comparable across builds.
local PERF_PHASES = { "wait", "load", "map", "detail" }

local function perf_tick(now)
  local last = S.perf_last
  S.perf_last = now
  if not last then return end
  local ph = phase()
  local p = S.perf[ph]
  if not p then
    p = { n = 0, ms = 0, worst = 0 }
    S.perf[ph] = p
  end
  local dt = now - last
  p.n, p.ms = p.n + 1, p.ms + dt
  if dt > p.worst then p.worst = dt end
end

-- Two lines, once per session (finish or game_end, whichever comes first):
--   exit <event> E=<errors> W=<warnings> <state_line>
--   exit perf <phase> <fps>fps/<ms>ms worst=<gap> | ... map_ready=<ms>
local function session_report(event)
  if S.reported or not S.perf then return end
  S.reported = true
  log("I", "exit", event, " E=", log_count.E, " W=", log_count.W, " ", state_line())
  local parts = {}
  for _, k in ipairs(PERF_PHASES) do
    local p = S.perf[k]
    if p and p.ms > 0 then
      local fps10 = math.floor(p.n * 10000 / p.ms)
      parts[#parts + 1] = k .. " " .. (fps10 // 10) .. "." .. (fps10 % 10)
                          .. "fps/" .. p.ms .. "ms worst=" .. p.worst
    end
  end
  log("I", "exit", "perf ", table.concat(parts, " | "), " | map_ready=", S.map_ready_ms, "ms")
end

-- ---------------------------------------------------------------- reporting

-- report_result first (report-only), then Engine.exit. Both are wrapped: a
-- raise on the way out reads to back as a pack crash and counts against
-- TODO_MAP_RETRY_MAX. `item` (a category, or "none" for a finished day) and
-- `via` are given only by the exits the child chose, which send `pick`; a
-- dead end or a missing frame is back's to report (todo.*).
local function finish(event, item, via)
  if S.exiting then return end
  S.exiting = true

  -- Leave the last frame up: it covers the panel until the host's GIF shows.
  session_report(event)
  if item then
    local sent = tel.event("pick", { item = item, via = via })
    log("I", "tel", "pick sent=", sent)
  end
  local t0 = Timer.millis()
  local ok, res, err = pcall(Engine.report_result, { event = event })
  span("report", t0)
  if not ok then
    log("E", "exit", "report_result raised: ", res)
  elseif not res then
    log("E", "exit", "report_result failed: ", err)
  end

  t0 = Timer.millis()
  local eok, eerr = pcall(Engine.exit, event)
  span("exit", t0)
  if not eok then log("E", "exit", "Engine.exit raised: ", eerr) end
end

-- The map's way out when it has nothing to open: back takes data.fallback,
-- the day's conversation for a broken map, instead of redrawing the same
-- dead end. The map never just sits there.
local function dead_end(why)
  log("W", "map", "dead end (", why, ") -> fallback")
  finish("map.exit;reason=no_open")
end

-- A reward hands over to its own pack; a lesson opens the detail screen.
local function open_point(idx, via)
  local pt = S.route[idx]
  if not pt then
    dead_end("no node " .. tostring(idx))
    return
  end
  if not pt.openable then
    dead_end("node " .. idx .. " " .. pt.shut)
    return
  end
  if not is_reward(pt) then
    detail_enter(idx, via)
    return
  end

  -- The server names the pack as "x.zip" but the engine resolves game_id as a
  -- folder. The parentheses drop gsub's second return value.
  local game = (tostring(pt.game_id):gsub("%.zip$", ""))
  game = game:gsub('[%c"\\]', "")   -- JSON-safe; ids are plain names
  local ev = '{"ev":"map.pick","game":"' .. game .. '"'
  -- milestone_index -1 (the end-of-day chest) is a real value, distinct from absent.
  if pt.ms ~= nil then ev = ev .. ',"milestone_index":' .. tostring(pt.ms) end
  finish(ev .. "}", pt.cat, via)
end

-- The lesson on the detail screen, by the item_id detail_enter kept.
local function enter_lesson(via)
  if S.d_item == nil then
    dead_end("node " .. tostring(S.d_idx) .. " no item_id")
    return
  end
  local pt = S.route[S.d_idx]
  finish("detail.enter;item=" .. tostring(S.d_item), pt and pt.cat or CFG.CAT_FALLBACK, via)
end

-- ---------------------------------------------------------------- the frame

-- Resolve the alias to play for each narration line. A null url is NORMAL
-- (TTS has not caught up): fall back, do not retry.
local function install_narration(theme_meta)
  S.narration = {}
  local audio = type(theme_meta) == "table" and theme_meta.audio or nil
  if type(audio) ~= "table" then audio = {} end

  -- Either array may hold either line.
  local function find(name)
    for _, list in ipairs({ audio.dynamic, audio.static }) do
      if type(list) == "table" then
        for _, item in ipairs(list) do
          if type(item) == "table" and item.name == name then return item end
        end
      end
    end
    return nil
  end

  -- cp-2 is absent by contract once the journey is ALL_DONE (nothing comes
  -- next): the generic map line after the closing cp-1 would be a stray line.
  local function fall_back(level, name, why)
    local alias = nil
    if not (name == NARR_NEXT and S.all_done) then alias = fallback_of(name) end
    log(level, "narr", name, " ", why, " -> ", alias or "skipped")
    S.narration[name] = alias
    if alias then S.narr_fb = S.narr_fb + 1 end
  end

  S.narr_remote, S.narr_fb = 0, 0

  for _, name in ipairs(NARRATION_ALL) do
    local item = find(name)
    if not item then
      fall_back("I", name, "not offered by this theme")
    elseif type(item.url) ~= "string" or item.url == "" then
      fall_back("I", name, "has no url yet")
    else
      local t0 = Timer.millis()
      local installed = Speaker.set_url(name, item.url)
      span("set_url", t0)
      if installed then
        S.narration[name] = name
        S.narr_remote = S.narr_remote + 1
      else
        fall_back("W", name, "set_url refused")
      end
    end
  end
end

-- Map the journey and arm the loader. The art is loaded by pump_load; a
-- second frame of the same shape updates progress in place.
local function build_day(args)
  local data = type(args) == "table" and args.data or nil
  if type(data) ~= "table" then
    log("W", "day", "journey frame has no data")
    return
  end
  local cps = data.checkpoints
  if type(cps) ~= "table" or #cps == 0 then
    log("W", "day", "journey frame has no checkpoints")
    return
  end

  -- Rendered in the order received: the server puts DONE/SKIPPED first and
  -- the contract forbids re-sorting.
  local route = {}
  for i = 1, #cps do route[i] = map_checkpoint(cps[i]) end

  -- Handles were handed out for the first frame's shape; a reshaped day waits
  -- for the next launch.
  if S.route and #S.route ~= #route then
    log("W", "day", "journey reshaped (", #S.route, " -> ", #route, "): keeping the drawn day")
    return
  end

  -- The cursor is the server's call, never re-derived. Floored: a fractional
  -- index would index nil.
  local cur = clamp(math.floor(tonumber(data.current_index) or 0) + 1, 1, #route)

  S.route, S.cur = route, cur
  S.all_done = true
  for i = 1, #route do
    local st = route[i].status
    if st ~= "DONE" and st ~= "SKIPPED" then S.all_done = false break end
  end
  S.vis = GEO.window(route, cur)
  S.pts = plan_points(S.vis, route)
  install_narration(data.theme_meta)
  S.bar_stale = true
  S.loading = true
  S.load_t0 = Timer.millis()

  -- The map line is said once, on the first frame. A later frame keeps the
  -- current screen: on the detail screen the map is never pumped again.
  if not S.have_day then
    S.have_day = true
    say(NARRATION_MAP)
  end

  log("I", "day", #route, " checkpoints, cur=", cur, " shown=", #S.vis,
      S.all_done and " all_done" or "")
end

-- The one way in for a journey body: the store (game_start, on_pack_data) or
-- the frame (on_pack_cmd). Both carry the same GET body; a refetch that changed
-- nothing is skipped, a changed one is mapped again.
local function journey_feed(body, source)
  local dup = JOURNEY.seen(body)
  log("I", "day", "journey src=", source, " dup=", dup and 1 or 0)
  if dup then return end
  build_day(body)
end

-- One step of the day's art load: spend LOAD_BUDGET sprites, pedestals first
-- (a node without one draws nothing), ticks last. Then one step for the
-- detail backdrop, then place and show the day.
local function pump_load(now)
  local base, icon, badges = count_needs(S.route, S.vis)
  local left = LOAD_BUDGET

  for _, kind in ipairs(BASE_ORDER) do
    left = grow(R.theme.base[kind], base[kind],
                ART .. "map_base_" .. kind .. ".png", left)
  end

  -- Sorted: pairs() order is undefined, and the load resumes where it stopped.
  local names = {}
  for name in pairs(icon) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    R.icon[name] = R.icon[name] or {}
    left = grow(R.icon[name], icon[name], ART .. name .. ".png", left)
  end

  left = grow(R.badges, badges, ART .. "map_tick.png", left)
  if left == 0 then return end

  -- Before the map shows: afterwards this SD read froze the breathing icon.
  if prewarm_detail() then return end

  S.loading = false
  local t0 = Timer.millis()
  layout()
  reveal_map(now)
  span("layout", t0)
  S.t0 = Timer.millis()   -- the breath's phase origin
  log("I", "load", "art ready in ", now - S.load_t0, " ms, last step ", S.t0 - now, " ms")
end

-- ---------------------------------------------------------------- hooks

-- Runs a hook body. A raise still ends the session exactly as before (back
-- counts it as a pack crash); this only logs what the pack was doing first.
local function guarded(hook, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    log("E", hook, err, " | ", state_line())
    error(err, 0)
  end
end

function game_start(params)
  set_lang(type(params) == "table" and params.language or nil)

  S = { view = "map", t0 = Timer.millis(), perf = {} }
  S.start_t0 = S.t0
  log_count.E, log_count.W, log_seen = 0, 0, {}
  JOURNEY.reset()
  trace_reset()
  trace.tick_at = nil
  R.icon, R.badges = {}, {}

  -- Raising here is the right failure: every later frame would index nil.
  local ok, which = alloc_lines()
  if not ok then error("connector alloc failed: " .. tostring(which)) end

  ok, which = load_detail_labels()
  if not ok then error("detail labels failed: " .. tostring(which)) end

  R.theme, which = load_theme()
  if not R.theme then error("theme load failed: " .. tostring(which)) end
  -- The journey frame only arrives after start, so the loading animation is
  -- held until reveal_map has the whole map up (Engine.show). The backdrop
  -- is shown now regardless: firmware without Engine.show, or a frame that
  -- never comes (the engine's 3 s hold limit), would otherwise show black.
  S.held = Engine.show ~= nil and Engine.show(false)
  R.theme.bg:set_visible(true)

  -- LAST (see alloc_gop). Degrades: the chip only shows on long days.
  ok, which = alloc_gop()
  if not ok then log("W", "boot", "gop chip unavailable: ", which) end
  probe_small_name_face()

  -- Newer firmware already holds the day: no wait for the frame, and no
  -- no_journey exit. nil on 1.1.5 and older; the frame still comes.
  local j = JOURNEY.stored()
  if j then journey_feed(j, "store") end

  trace_once("boot", S.start_t0)
end

-- Lua time spent in hooks between two ticks, for the lag trace's "hooks=".
local function hook_done(name, t0)
  span(name, t0)
  trace.hook_ms = trace.hook_ms + (Timer.millis() - t0)
end

local function handle_pack_cmd(cmd)
  if type(cmd) ~= "table" then
    -- The engine hands over the raw JSON string when the frame exceeds its
    -- decode caps (depth 8 / 1024 nodes).
    log("W", "day", "journey frame not decoded (", type(cmd), ")")
    return
  end
  if cmd.op ~= "journey" then
    log("I", "day", "ignoring op=", cmd.op)
    return
  end
  journey_feed(cmd.args, "cmd")
end

-- back has already unwrapped the {type,data} envelope.
function on_pack_cmd(cmd)
  if S.exiting then return end
  local t0 = Timer.millis()
  guarded("on_pack_cmd", handle_pack_cmd, cmd)
  hook_done("on_pack_cmd", t0)
end

-- A tombstoned key reads nil: the drawn day stays.
local function handle_pack_data(key)
  if key ~= "journey" then return end
  local j = JOURNEY.stored()
  if j then journey_feed(j, "store") end
end

-- Newer firmware: the stored journey changed (a refetch) while the map runs.
function on_pack_data(key, _version)
  if S.exiting then return end
  local t0 = Timer.millis()
  guarded("on_pack_data", handle_pack_data, key)
  hook_done("on_pack_data", t0)
end

-- The countdown starts only for the line this screen is waiting on -- a late
-- finish from the previous screen must not. A remote line that fails (the
-- TTS url 404s, the network drops) is replaced once by the packaged one;
-- one that cannot be replaced counts as over, instead of waiting out the cap.
local function handle_sound_end(alias, reason)
  if reason == Speaker.REASON_COMPLETED then
    log("I", "narr", "finished ", alias)
    narration_over(alias)
    return
  end
  if reason ~= Speaker.REASON_ERROR then return end

  local n = S.narr_now
  if not (n and n.alias == alias) then return end
  S.narr_now = nil
  local fb_alias = fallback_of(n.name)
  if fb_alias and fb_alias ~= alias and not S.exiting then
    log("W", "narr", alias, " failed, playing ", fb_alias)
    S.narration[n.name] = fb_alias
    local played = narrate(n.name)
    if alias == S.auto_alias then
      if played then auto_arm(played) else narration_over(alias) end
    end
    return
  end
  log("W", "narr", alias, " failed, no fallback left")
  narration_over(alias)
end

function on_sound_end(alias, reason)
  guarded("on_sound_end", handle_sound_end, alias, reason)
end

function on_sound_lost(count)
  log("W", "narr", "lost ", count, " sound events")
end

-- Only confirm does anything, and it takes the step the hands-free advance
-- would, now. Left/right are unused.
local function handle_input(action)
  if S.exiting or not S.have_day or action ~= "confirm" then return end
  -- Presses while the map's art is still arriving would act on nodes the child
  -- cannot see yet. Not on detail: a frame arriving there never reshows the map.
  if S.loading and S.view == "map" then return end

  if S.view == "detail" then
    enter_lesson("enter")
  elseif S.all_done then
    finish("map.exit;reason=all_done", "none", "enter")
  else
    open_point(S.cur, "enter")
  end
end

function on_input(action, edge)
  if edge ~= Input.PRESS then return end
  local t0 = Timer.millis()
  log("I", "input", action)
  guarded("on_input", handle_input, action)
  hook_done("on_input:" .. tostring(action), t0)
end

local function tick(now)
  if not S.have_day then
    if now - S.t0 > NO_FRAME_MS then finish("map.exit;reason=no_journey") end
    prewarm_detail()
    return
  end

  -- Map only: pumping under the detail screen would re-show the map on top.
  if S.loading and S.view == "map" then
    pump_load(now)
    return
  end

  if S.view == "detail" then
    if auto_due(now) then
      log("I", "detail", "auto-advance into lesson ", S.d_idx)
      enter_lesson(S.auto_by_cap and "cap" or "auto")
      return
    end
    render_detail(now - S.d_t0)
    return
  end

  -- A lesson opens its detail screen, a reward its game; a finished day or a
  -- node that cannot open hands back to back's fallback. A reward node leaves
  -- for its game the moment the line ends (AUTO_REWARD_AFTER_SOUND_MS).
  local cur_pt = S.route and S.route[S.cur]
  local after_ms = (not S.all_done and cur_pt and is_reward(cur_pt))
                   and AUTO_REWARD_AFTER_SOUND_MS or nil
  if auto_due(now, after_ms) then
    local via = S.auto_by_cap and "cap" or "auto"
    if S.all_done then
      log("I", "map", "auto-advance, journey complete")
      finish("map.exit;reason=all_done", "none", via)
      return
    end
    log("I", "map", "auto-advance from node ", S.cur)
    open_point(S.cur, via)
    return
  end

  -- Normally shown by the tick that laid it out; this catches a layout the
  -- watchdog cut short.
  if not S.shown then
    reveal_map(now)
  else
    render_breath(now - S.t0)
  end
  span("map", now)
end

-- dt_ms is ignored: it is the configured period (a constant 33), so
-- accumulating it slows every animation when a frame overruns. Everything is
-- a function of the monotonic clock instead.
function on_tick(_dt_ms)
  local now = Timer.millis()
  if S.exiting then return end
  perf_tick(now)
  trace_frame(now)
  guarded("on_tick", tick, now)
  trace.tick_ms = Timer.millis() - now
end

-- HOME is back's way out of the journey: let it through.
function on_home() return false end

-- Nothing reclaims sprites inside a session, so every handle goes here.
-- Backdrops are hidden first so the destroys do not re-blend them, and
-- objects go roughly newest-first: lv_obj_delete memmoves every later sibling.
-- Creation order: lines, labels, theme, gop (game_start); pools and detail art
-- (pump_load); hero and bar (the first detail entry).
function game_end()
  -- Also reached without finish() when back stops the pack (HOME).
  local t0 = Timer.millis()
  session_report("stopped by host")
  if R.theme then R.theme.bg:set_visible(false) end
  if R.d and R.d.bg then R.d.bg:set_visible(false) end

  if R.d then
    for _, m in ipairs(R.d.cells) do m.spr:destroy() end
    for _, spr in ipairs(R.d.rails) do spr:destroy() end
    for _, m in ipairs(R.d.segs) do m.spr:destroy() end
    for _, m in pairs(R.d.hero) do m.spr:destroy() end
    if R.d.base then R.d.base.spr:destroy() end
    if R.d.bg then R.d.bg:destroy() end
  end

  for i = #(R.badges or {}), 1, -1 do R.badges[i].spr:destroy() end
  for _, pool in pairs(R.icon or {}) do
    for i = #pool, 1, -1 do pool[i].spr:destroy() end
  end

  if R.gop then
    R.gop.text:destroy()
    R.gop.pill.spr:destroy()
  end
  free_theme(R.theme)

  if R.d then
    for i = #DETAIL_LABELS, 1, -1 do
      local t = R.d[DETAIL_LABELS[i].key]
      if t then t:destroy() end
    end
  end
  for _, ln in ipairs(R.lines or {}) do ln:destroy() end

  R = {}
  trace_once("game_end", t0)
end
