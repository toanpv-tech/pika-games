-- Egg reward (to-do journey, mid reward): three eggs drop in, the child picks one,
-- it hatches into gems that pour into their backpack while the week total counts
-- up; Pika then reads the server's cp-5/cp-6 lines (gems received, new total)
-- before the bag leaves. The numbers, the backpack and those two lines come from
-- the journey frame (on_pack_cmd); without one the scene still plays, with every
-- number hidden and no lines.
--
-- Port of the v3 demo (screen/map-lab.html). The engine refuses rotate/scale on
-- sprites over 96px, so the egg wobble, shake and the bag squashes are movement
-- instead; Text has no scale or opacity, so labels appear and go in one frame.
--
-- Every sprite is built once (game_start, then build_tail) and reused; the tick
-- functions only move, fade, scale and show, and allocate nothing.
--
-- Serial log: one line per event, "egg.<event> key=value ..." (grep "egg[.:]").
--
-- Telemetry (game.tel): three milestones a play - egg.frame (what the journey
-- frame gave, when the tail is built), pick, egg.done (before Engine.exit: calls
-- from game_end are refused). Three fit the head's 3-per-5-s window even when the
-- child picks during the drop, so none is ever refused for rate.
local CFG = require("libs/config")
local tel = require("libs/tel")

local DROP, BROWSE, GATHER, SHAKE, OPEN = "drop", "browse", "gather", "shake", "open"
local BAG_IN, POUR, BAG_OUT, DONE = "bag_in", "pour", "bag_out", "done"

-- Voice aliases name the vi file; the head plays assets/au/en_<file> instead when
-- the robot speaks another language. The reminders exist in Vietnamese only.
local VOICE_1, VOICE_2 = "voice_1", "voice_2"
local REMIND = { "remind_1", "remind_2" }
local SELECT = "select" -- the cursor reached another egg (one 0.4 s tick for all)
local BAG_STATES = { "closed", "open", "full" }
-- Server narration read after "pour", in this order: theme_meta.audio.dynamic[]
-- name -> manifest "remote" alias (the URL is installed from the journey frame).
local OUTRO = { { name = "cp-5", alias = "cp_5" }, { name = "cp-6", alias = "cp_6" } }

-- Build with the default bag if no journey frame has arrived by then.
local FRAME_WAIT_MS = 3000

local state = {
  scene = DROP,
  t0 = 0,            -- when the current scene began
  sel = 2,           -- cursor, 1-based; starts on the middle egg
  chosen = nil,
  opt_idx = nil,     -- 1-based option behind the chosen egg (the last one past #options)
  chosen_dx = nil,   -- how far the chosen egg has travelled to the centre
  hop_t0 = nil,
  last_input = 0,
  reminded = false,
  start_ms = 0,
  -- Journey frame. gems / week_before are stand-ins until it arrives.
  gems = CFG.DEFAULT.GEMS,
  week_before = CFG.DEFAULT.WEEK_TOTAL,
  milestone = nil,
  options = nil,     -- reward_options.options, first frame only
  week_known = false,
  show_num = false,  -- the chosen egg has an amount AND the total is known
  locked = false,    -- egg chosen: later frames are ignored
  bag = CFG.DEFAULT.BAG,
  tail_built = false,
  tail_due = false,  -- a frame was handled: build now, do not wait
  -- The drop waits for the screen: "wait" (tail not built) -> "showing"
  -- (Engine.show() asked, the screen goes up after that tick) -> "up".
  held = false,      -- Engine.show(false) holds the host's loading animation
  reveal = "wait",
  fallback = false,  -- the frame's bag failed to load: default bag shown
  -- What the journey frame gave, for the egg.frame telemetry event.
  frame_seen = false,
  frame_reason = nil, -- "no_checkpoints" | "no_options" when it had no options
  item_ok = false,   -- equipped_item_id is a known bag
  url_n = 0,         -- cp-5/cp-6 lines with a URL installed
  outro_n = 0,       -- of those, lines actually played
  -- Voice: "off" | "v1" | "gap" (waiting to play VOICE_2) | "v2" | "remind".
  voice = "off",
  voice_t0 = 0,      -- when the current line started
  gap_t0 = 0,
  quiet_t0 = 0,      -- when the intro lines were over
  lang_vi = true,
  remind_n = 0,
  playing = nil,     -- alias of our last play still on the speaker
  tick_t0 = nil,     -- when the last select tick was played
  tick_skip = 0,     -- moves left silent by the debounce
  pick_t0 = nil,     -- "pick" was refused (play cooldown): retried until PICK_RETRY_MS
  pour_said = false,
  outro_i = 0,       -- OUTRO line on the speaker (0 = "pour" not over yet)
  outro_t0 = 0,      -- when it started
  outro_url = {},    -- alias -> true once its URL is installed
  leave_t0 = nil,    -- when the bag started to slide away
  -- Week total.
  shown = 0,         -- the value counted up to
  drawn = nil,       -- the value on the label (set only when it changes)
  count_w = 0,       -- its width in px
  bump_t0 = nil,
  icon_t0 = nil,
}

local R = { sprites = {}, eggs = {}, bag = {}, gems = {},
            cave = nil, spot = nil, ring = nil, rays = nil,
            flash = nil, spark = nil, reward = nil, icon = nil }
local count_txt = nil -- week total
local plus_txt = nil  -- "+N" under the big gem
local elapsed = 0
local load_failed = 0

local function now()
  return (Timer and Timer.millis) and Timer.millis() or elapsed
end

-- On the robot a newer play does NOT replace the current one: game sounds are all
-- HIGH and HIGH does not preempt HIGH, so it queues behind (log 07/10: ticks
-- played seconds late, then "pick" was refused on a full queue). So every play
-- first stops ours by its request. Never stop_all beside a play: it is drained at
-- the end of the tick, after the play, and clears the queue with it.
local function hush()
  local a = state.playing
  state.playing = nil
  if a and Speaker and Speaker.stop then Speaker.stop(a) end
end

local function sound(alias)
  hush()
  if Speaker and Speaker.play and Speaker.play(alias) then
    state.playing = alias
    return true
  end
  return false
end

local function keep(s)
  R.sprites[#R.sprites + 1] = s
  return s
end

local function round(v)
  return math.floor(v + 0.5)
end

-- Telemetry refuses a whole event when one number is outside int32, and
-- amounts come from the server: clamp the ones that do.
local function i32(v)
  if v > 2147483647 then return 2147483647 end
  if v < -2147483648 then return -2147483648 end
  return v
end

-- Sprite.image answers (nil, msg) when the file is missing or PSRAM runs out, so
-- a pack over budget silently loses whatever was created last. Count and name
-- every failure.
local function image(path)
  if not (Sprite and Sprite.image) then return nil end
  local s, err = Sprite.image(path)
  if not s then
    load_failed = load_failed + 1
    print("egg.asset result=fail path=" .. path .. " err=" .. tostring(err) ..
          " failed=" .. load_failed)
    return nil
  end
  s:set_visible(false)
  return keep(s)
end

local function raw_image(path, w, h)
  if not (Sprite and Sprite.new) then return nil end
  local s, err = Sprite.new(path, w, h)
  if not s then
    load_failed = load_failed + 1
    print("egg.asset result=fail path=" .. path .. " err=" .. tostring(err) ..
          " failed=" .. load_failed)
    return nil
  end
  return keep(s)
end

-- Sprite record with cached setters: an LVGL call only when the value changes.
-- Every cached field starts at a value no caller produces, so the first set lands.
local function mk(s)
  if not s then return nil end
  return { s = s, x = -1, y = -1, opa = -1, vis = false, scl = -1 }
end

local function put(rec, x, y)
  if not rec then return end
  x, y = round(x), round(y)
  if rec.x ~= x or rec.y ~= y then
    rec.x, rec.y = x, y
    rec.s:set_pos(x, y)
  end
end

local function fade(rec, opa)
  if not rec then return end
  opa = round(opa)
  if opa < 0 then opa = 0 elseif opa > 255 then opa = 255 end
  if rec.opa ~= opa then
    rec.opa = opa
    rec.s:set_opacity(opa)
  end
end

local function show(rec, v)
  if rec and rec.vis ~= v then
    rec.vis = v
    rec.s:set_visible(v)
  end
end

-- k is the ratio (1.0 = art size). set_scale answers false on sprites over 96px,
-- and engines built without it get a no-op instead of a nil call in on_tick.
local function scale(rec, k)
  if not rec or not rec.s.set_scale then return end
  local v = round(k * 256)
  if v < 1 then v = 1 end
  if rec.scl ~= v then
    rec.scl = v
    rec.s:set_scale(v)
  end
end

-- Text label on the numbers face, hidden, with the same cached setters. If
-- set_font fails the label keeps the default face, which still draws digits.
local function mk_text(px, color)
  if not (Text and Text.new) then return nil end
  local t, err = Text.new("", 0, 0)
  if not t then
    print("egg.asset result=fail path=text err=" .. tostring(err))
    return nil
  end
  local _, ferr = t:set_font(CFG.FONT_NUM, px)
  if ferr then print("egg.asset result=fail path=" .. CFG.FONT_NUM .. " err=" .. tostring(ferr)) end
  t:set_color(color)
  t:show(false)
  return { t = t, str = nil, dx = nil, dy = nil, vis = false }
end

local function text_set(rec, str)
  if rec and rec.str ~= str then
    rec.str = str
    rec.t:set(str)
  end
end

-- Offsets from the screen centre, as Text:align("center", dx, dy) takes them.
local function text_at(rec, dx, dy)
  if not rec then return end
  dx, dy = round(dx), round(dy)
  if rec.dx ~= dx or rec.dy ~= dy then
    rec.dx, rec.dy = dx, dy
    rec.t:align("center", dx, dy)
  end
end

local function text_show(rec, v)
  if rec and rec.vis ~= v then
    rec.vis = v
    rec.t:show(v)
  end
end

-- Piecewise-linear walk through a demo keyframe list.
local function keyframes(p, ks, vs, v0, vend)
  if p <= 0 then return v0 end
  local prev_k, prev_v = 0, v0
  for i = 1, #ks do
    if p < ks[i] then
      return prev_v + (vs[i] - prev_v) * (p - prev_k) / (ks[i] - prev_k)
    end
    prev_k, prev_v = ks[i], vs[i]
  end
  if p >= 1 then return vend end
  return prev_v + (vend - prev_v) * (p - prev_k) / (1 - prev_k)
end

local function enter(scene, t)
  state.scene, state.t0 = scene, t
  print("egg.scene name=" .. scene .. " ms=" .. (t - state.start_ms))
end

local function egg_box_x(i)
  return CFG.EGG_CX[i] - CFG.EGG_BOX / 2
end

local function egg_body_x(i)
  return CFG.EGG_CX[i] + CFG.EGG_LECH[i]
end

-- ---------------------------------------------------------------- lifecycle

local function load_bag(name)
  local ok = true
  for _, st in ipairs(BAG_STATES) do
    R.bag[st] = mk(image("assets/runtime/bag_" .. name .. "_" .. st .. ".png"))
    ok = ok and R.bag[st] ~= nil
  end
  return ok
end

-- The topmost layers: backpack, flying gems, sparkle, gem icon, labels. Deferred
-- because the bag art depends on the journey frame, which arrives after
-- game_start; built last, they stay on top without set_z. Idempotent.
local function build_tail()
  if state.tail_built then return end
  state.tail_built = true
  local t0 = now()

  local fallback = 0
  if not load_bag(state.bag) and state.bag ~= CFG.DEFAULT.BAG then
    for _, rec in pairs(R.bag) do rec.s:destroy() end -- idempotent: game_end may repeat it
    R.bag, state.bag, fallback = {}, CFG.DEFAULT.BAG, 1
    load_bag(state.bag)
  end

  -- Same art as the big gem: one shared decoded buffer.
  for i = 1, CFG.GEM.N do
    R.gems[i] = mk(image("assets/runtime/v3_popa.png"))
  end
  R.spark = mk(image("assets/runtime/v3_fx_spark.png"))
  R.icon = mk(image(CFG.ICON.FILE))

  plus_txt = mk_text(CFG.PLUS.PX, CFG.PLUS.COLOR)
  text_set(plus_txt, "+0")
  text_at(plus_txt, 0, CFG.PLUS.CY - CFG.SCREEN_H / 2)
  count_txt = mk_text(CFG.COUNT.PX, CFG.COUNT.COLOR)

  state.fallback = fallback == 1
  print("egg.tail bag=" .. state.bag .. " fallback=" .. fallback ..
        " failed=" .. load_failed .. " ms=" .. (now() - t0))

  -- The scene commits to its data here, so this is what the child gets.
  local result = state.options and "ok" or (state.frame_seen and "no_data" or "missing")
  local sent = tel.event("egg.frame", {
    result = result, reason = state.frame_reason,
    opts = state.options and #state.options or 0, week = state.week_known,
    item_ok = state.item_ok, url = state.url_n, failed = load_failed,
  }, result ~= "ok" and { level = "warn" } or nil)
  print("egg.tel ev=egg.frame result=" .. result .. " sent=" .. tostring(sent))
end

function game_start(params)
  params = params or {}
  -- back's params carry only milestone_index; the rest comes from the frame.
  state.milestone = tonumber(params.milestone_index)
  state.lang_vi = params.language == nil or params.language == "vi"
  state.gems, state.week_before = CFG.DEFAULT.GEMS, CFG.DEFAULT.WEEK_TOTAL
  state.options, state.week_known = nil, false
  state.show_num, state.locked = false, false
  state.bag, state.tail_built, state.tail_due = CFG.DEFAULT.BAG, false, false
  state.fallback, state.frame_seen, state.frame_reason = false, false, nil
  state.item_ok, state.url_n, state.outro_n = false, 0, 0
  state.start_ms = now()
  -- build_tail decodes ~250 ms of art in one tick (log 12/10): run mid-drop it
  -- froze the screen and the eggs jumped. Keep the loading animation up until
  -- the tail is built; the engine shows the screen anyway after 3 s.
  state.held = Engine ~= nil and Engine.show ~= nil and Engine.show(false) == true
  state.reveal = "wait"

  -- Creation order IS stacking order (set_z reorders unpredictably while sprites
  -- are still being created): cave, spot, ring, rays, egg bottoms, gem, egg tops
  -- (the gem rises from between the halves), flash, then build_tail's layers.
  R.cave = mk(raw_image(CFG.CAVE.FILE, CFG.CAVE.W, CFG.CAVE.H))
  show(R.cave, true) -- created visible; sync the cache so the later hide lands
  fade(R.cave, 255)
  R.spot = mk(image("assets/runtime/v3_fx_spot.png"))
  R.ring = mk(image("assets/runtime/v3_fx_ring.png"))
  R.rays = mk(image("assets/runtime/v3_fx_rays.png"))
  for i, e in ipairs(CFG.EGGS) do
    R.eggs[i] = { cfg = e, bot = mk(image("assets/runtime/v3_egg_" .. e.name .. "_bottom.png")) }
  end
  R.reward = mk(image("assets/runtime/v3_popa.png"))
  for i, e in ipairs(CFG.EGGS) do
    R.eggs[i].top = mk(image("assets/runtime/v3_egg_" .. e.name .. "_top.png"))
  end
  R.flash = mk(image("assets/runtime/v3_fx_flash.png"))

  state.scene, state.t0, state.chosen, state.chosen_dx = DROP, now(), nil, nil
  state.opt_idx, state.pick_t0 = nil, nil
  state.sel, state.hop_t0 = 2, nil
  state.last_input, state.reminded = now(), false
  state.shown, state.drawn, state.count_w = state.week_before, nil, 0
  state.bump_t0, state.icon_t0, state.pour_said, state.leave_t0 = nil, nil, false, nil
  state.outro_i, state.outro_t0, state.outro_url = 0, 0, {}
  state.voice, state.gap_t0, state.quiet_t0, state.remind_n = "off", 0, 0, 0
  state.playing, state.tick_t0, state.tick_skip = nil, nil, 0
  if sound(VOICE_1) then state.voice, state.voice_t0 = "v1", now() end
  print("egg.start milestone=" .. tostring(state.milestone) ..
        " lang=" .. tostring(params.language) .. " voice=" .. state.voice ..
        " failed=" .. load_failed)
end

function game_end()
  for i = 1, #R.sprites do R.sprites[i]:destroy() end
  R.sprites, R.eggs, R.bag, R.gems = {}, {}, {}, {}
  R.cave, R.spot, R.ring, R.rays = nil, nil, nil, nil
  R.flash, R.spark, R.reward, R.icon = nil, nil, nil, nil
  -- Text slots are a pool of 8 shared across the VM: hand them back explicitly.
  if count_txt then count_txt.t:destroy(); count_txt = nil end
  if plus_txt then plus_txt.t:destroy(); plus_txt = nil end
  state.playing = nil
  if Speaker and Speaker.stop_all then Speaker.stop_all() end
end

-- ------------------------------------------------------------------- layout

-- dx/dy move the whole egg (drop, bob, shake, hop, lift); the top_/bot_ offsets
-- carry the halves apart when it opens.
local function place(egg, i, dx, dy, top_dx, top_dy, bot_dy)
  local ox = egg_box_x(i) + dx
  local oy = CFG.EGG_TOP + dy
  local c = egg.cfg
  put(egg.bot, ox + c.bot.dx, oy + c.bot.dy + (bot_dy or 0))
  put(egg.top, ox + c.top.dx + (top_dx or 0), oy + c.top.dy + (top_dy or 0))
end

local function show_egg(egg, v)
  show(egg.bot, v)
  show(egg.top, v)
end

local function fade_egg(egg, opa)
  fade(egg.bot, opa)
  fade(egg.top, opa)
end

local function place_focus(i, visible)
  local bx = egg_body_x(i)
  put(R.spot, bx + CFG.FX_SPOT.DX, CFG.FX_SPOT.Y)
  show(R.spot, visible)
  put(R.ring, bx + CFG.FX_RING.DX, CFG.FX_RING.Y)
  show(R.ring, visible)
end

-- ------------------------------------------------------------------- scenes

local function tick_drop(t)
  local dt = t - state.t0
  local all_done = true
  for i, egg in ipairs(R.eggs) do
    local k = (dt - CFG.DROP.DELAY - (i - 1) * CFG.DROP.STAGGER) / CFG.DROP.MS
    if k < 0 then
      show_egg(egg, false)
      all_done = false
    else
      if k < 1 then all_done = false end
      place(egg, i, 0, keyframes(math.min(1, k), CFG.DROP.K, CFG.DROP.V, CFG.DROP.FROM, 0))
      fade_egg(egg, 255)
      show_egg(egg, true)
    end
  end
  -- The focus cue appears only once everything has landed.
  place_focus(state.sel, false)
  if all_done then
    enter(BROWSE, t)
    state.last_input = t
  end
end

-- Browse is paint-bound, not Lua-bound: a still frame costs nothing, every
-- moved or faded layer repaints its area through all the layers below. So the
-- selected egg moves every frame; at most one other egg moves per frame (a
-- late one catches up next frame); the ring steps and rests during a hop.
local function tick_browse(t)
  local moved_other = false
  for i, egg in ipairs(R.eggs) do
    local sel = i == state.sel
    local period = sel and CFG.WOBBLE.PERIOD or CFG.WOBBLE.OTHER_PERIOD
    local p = (t + (i - 1) * period / 3) % period
    local dy = -CFG.WOBBLE.AMP * math.sin(2 * math.pi * p / period)
    if sel then
      dy = dy - CFG.SEL_LIFT
      if state.hop_t0 then
        local hk = (t - state.hop_t0) / CFG.HOP.MS
        if hk >= 1 then
          state.hop_t0 = nil
        else
          dy = dy - CFG.HOP.PX * math.sin(math.pi * hk)
        end
      end
    end
    -- Same rounding as place() -> put(): does this egg move this frame?
    local moves = egg.bot ~= nil and
                  round(CFG.EGG_TOP + dy + egg.cfg.bot.dy) ~= egg.bot.y
    if sel or not moves or not moved_other then
      place(egg, i, 0, dy)
      if moves and not sel then moved_other = true end
    end
    fade_egg(egg, 255)
    show_egg(egg, true)
  end

  place_focus(state.sel, true)
  -- The demo pulses the ring's scale; at 162px it is over the cap, so opacity.
  if not state.hop_t0 then
    local step = CFG.FX_RING.STEP_MS
    local ph = ((t - t % step) % CFG.FX_RING.PERIOD) / CFG.FX_RING.PERIOD
    local k = 0.5 - 0.5 * math.cos(2 * math.pi * ph)
    fade(R.ring, CFG.FX_RING.MIN + (CFG.FX_RING.MAX - CFG.FX_RING.MIN) * k)
  end
  fade(R.spot, 255)
end

-- The chosen egg slides to the centre by its body; the other two slide off.
local function tick_gather(t)
  local k = math.min(1, (t - state.t0) / CFG.T.GATHER)
  local ease = 1 - (1 - k) * (1 - k) * (1 - k)
  for i, egg in ipairs(R.eggs) do
    if i == state.chosen then
      local dx = (CFG.CENTER_X - egg_body_x(i)) * ease
      place(egg, i, dx, -CFG.SEL_LIFT)
      state.chosen_dx = dx
    else
      local side = (i < state.chosen) and -1 or 1
      place(egg, i, side * CFG.GATHER_OUT.DX * ease, CFG.GATHER_OUT.DY * ease)
      if ease >= 1 then show_egg(egg, false) end
    end
  end
  -- The focus FX ride along and fade as the egg commits.
  local bx = egg_body_x(state.chosen) + state.chosen_dx
  put(R.spot, bx + CFG.FX_SPOT.DX, CFG.FX_SPOT.Y)
  put(R.ring, bx + CFG.FX_RING.DX, CFG.FX_RING.Y)
  fade(R.ring, 255 * (1 - ease))
  fade(R.spot, 255 * (1 - ease))
end

local function tick_shake(t)
  local p = (t - state.t0) % CFG.SHAKE.PERIOD
  local dx = CFG.SHAKE.AMP * math.sin(2 * math.pi * p / CFG.SHAKE.PERIOD)
  place(R.eggs[state.chosen], state.chosen, state.chosen_dx + dx, -CFG.SEL_LIFT)
  show(R.spot, false)
  show(R.ring, false)
end

local function tick_open(t)
  local egg = R.eggs[state.chosen]
  local dt = t - state.t0
  local k = math.min(1, dt / CFG.OPEN.MS)
  local ease = 1 - (1 - k) * (1 - k) * (1 - k)

  -- Top half thrown clear, bottom dropped, both fading: only the gem remains.
  place(egg, state.chosen, state.chosen_dx, -CFG.SEL_LIFT,
        CFG.OPEN.TOP_DX * ease, CFG.OPEN.TOP_DY * ease, CFG.OPEN.BOT_DY * ease)
  fade(egg.top, 255 * (1 - ease))
  fade(egg.bot, 255 * (1 - ease))

  -- The gem arrives small and overshoots its full size.
  local P = CFG.POPA_IN
  local rk = math.min(1, dt / P.MS)
  local sk
  if rk < P.PEAK_AT then
    sk = P.FROM + (P.PEAK - P.FROM) * (rk / P.PEAK_AT)
  else
    sk = P.PEAK + (1 - P.PEAK) * ((rk - P.PEAK_AT) / (1 - P.PEAK_AT))
  end
  local half = CFG.REWARD.ART / 2
  put(R.reward, CFG.REWARD.CX - half, CFG.REWARD.CY - half)
  scale(R.reward, sk * CFG.REWARD_K.BIG)
  fade(R.reward, 255 * math.min(1, dt / 150))
  show(R.reward, true)

  -- "+N" cannot grow with the gem, so it waits for the overshoot peak.
  if rk >= P.PEAK_AT and state.show_num then text_show(plus_txt, true) end

  if R.cave and R.cave.vis then
    local ck = dt / CFG.CAVE.DIM_MS
    if ck >= 1 then show(R.cave, false) else fade(R.cave, 255 * (1 - ck)) end
  end

  local F = CFG.FX_FLASH
  local fk = dt / F.MS
  if fk <= 1 then
    local a = (fk < F.PEAK_AT) and (fk / F.PEAK_AT) or (1 - (fk - F.PEAK_AT) / (1 - F.PEAK_AT))
    put(R.flash, F.X, F.Y)
    fade(R.flash, 255 * a)
    show(R.flash, true)
  else
    show(R.flash, false)
  end

  -- Rays burst out, then breathe.
  local Y = CFG.FX_RAYS
  put(R.rays, Y.X, Y.Y)
  if dt < Y.IN_MS then
    fade(R.rays, Y.BASE * (dt / Y.IN_MS))
  else
    local ph = ((dt - Y.IN_MS) % Y.BREATH_PERIOD) / Y.BREATH_PERIOD
    local w = 0.5 - 0.5 * math.cos(2 * math.pi * ph)
    fade(R.rays, Y.BASE + (Y.DIP - Y.BASE) * w)
  end
  show(R.rays, true)
end

-- -------------------------------------------------------------- backpack beat

local function bag_state(which)
  for st, rec in pairs(R.bag) do show(rec, st == which) end
end

-- The gem bobs the whole time it is on screen.
local function popa_float(t)
  local P = CFG.POPA
  return -P.FLOAT_PX * math.sin(2 * math.pi * (t % P.FLOAT_PERIOD) / P.FLOAT_PERIOD)
end

local function bag_x(k)
  return CFG.BAG.X + CFG.BAG.OFF_X * (1 - k)
end

-- Sets the week total's label only when the number changed (no per-frame string).
local function count_refresh()
  if state.drawn ~= state.shown then
    state.drawn = state.shown
    local str = tostring(state.shown)
    state.count_w = #str * CFG.COUNT.DIGIT_W
    text_set(count_txt, str)
  end
end

local function cue_pour(to_land)
  if not state.pour_said and to_land <= CFG.POUR_SOUND.LEAD_MS then
    state.pour_said = true
    sound("pour")
  end
end

local function tick_bag_in(t)
  local dt = t - state.t0
  local ease = 1 - (1 - math.min(1, dt / CFG.BAG.SLIDE_MS)) ^ 3
  for _, rec in pairs(R.bag) do put(rec, bag_x(ease), CFG.BAG.Y) end
  bag_state("closed")
  cue_pour(CFG.T_BAG.SLIDE_IN + CFG.T_BAG.OPEN_HOLD + CFG.GEM.FLIGHT_MS - dt)

  show(R.flash, false)
  fade(R.rays, CFG.FX_RAYS.BASE * (1 - ease))
  if ease >= 1 then show(R.rays, false) end

  -- The gem lifts and shrinks, clearing the centre for the total; it stays, as
  -- the source the flying gems leave from.
  local pe = 1 - (1 - math.min(1, dt / CFG.POPA_PARK.MS)) ^ 3
  local half = CFG.REWARD.ART / 2
  put(R.reward, CFG.REWARD.CX - half, CFG.REWARD.CY - half + CFG.POPA_PARK.DY * pe + popa_float(t))
  fade(R.reward, 255)
  scale(R.reward, CFG.REWARD_K.BIG + (CFG.REWARD_K.PARKED - CFG.REWARD_K.BIG) * pe)

  -- "+N" goes, the total drops in on an easeOutBack.
  text_show(plus_txt, false)
  if state.show_num then
    local C = CFG.COUNT
    local k = math.min(1, dt / C.IN_MS) - 1
    local back = 1 + 2.70158 * k * k * k + 1.70158 * k * k
    count_refresh()
    text_at(count_txt, 0, C.CY - CFG.SCREEN_H / 2 - C.IN_DY * (1 - back))
    text_show(count_txt, true)
  end
end

-- The week total from the first gem's landing until the bag leaves: counting,
-- a lift per step, then the gem icon at its head. `out` (0..1) takes it away.
local function tick_count(t, dt, out)
  local C, I = CFG.COUNT, CFG.ICON
  local target = state.week_before + state.gems

  -- Count evenly from the first landing to the last, never under SPAN_MIN_MS, one
  -- unit a step unless steps would come faster than a frame.
  if dt and dt >= CFG.GEM.FLIGHT_MS and state.shown < target then
    local span = math.max((CFG.GEM.N - 1) * CFG.GEM.STAGGER_MS, C.SPAN_MIN_MS)
    local step_ms = math.max(C.STEP_MIN_MS, span / state.gems)
    local step = math.ceil(state.gems / (span / step_ms))
    local steps = math.floor((dt - CFG.GEM.FLIGHT_MS) / step_ms) + 1
    local v = math.min(target, state.week_before + steps * step)
    if v ~= state.shown then
      state.shown, state.bump_t0 = v, t
      if v >= target then state.icon_t0 = t end
    end
  end
  if not state.show_num then return end
  count_refresh()

  -- The number moves right to make room for the icon.
  local shift = 0
  if state.icon_t0 then
    local k = math.min(1, (t - state.icon_t0) / I.SHIFT_MS)
    shift = (I.W - I.OVERLAP) / 2 * (1 - (1 - k) * (1 - k))
  end
  local lift = 0
  if state.bump_t0 then
    local k = (t - state.bump_t0) / C.BUMP_MS
    if k >= 1 then state.bump_t0 = nil else lift = C.BUMP_PX * math.sin(math.pi * k) end
  end
  text_at(count_txt, shift, C.CY - CFG.SCREEN_H / 2 - lift)
  text_show(count_txt, out == nil)

  if R.icon and state.icon_t0 then
    local num_left = CFG.CENTER_X + shift - state.count_w / 2
    put(R.icon, num_left + I.OVERLAP - I.W, C.CY - I.W / 2 + I.DY)
    if out then
      scale(R.icon, 1 + (I.OUT_K - 1) * out)
      fade(R.icon, 255 * (1 - out))
      if out >= 1 then show(R.icon, false) end
    else
      local k = math.min(1, (t - state.icon_t0) / I.IN_MS)
      local sk = (k < I.PEAK_AT) and (I.PEAK * k / I.PEAK_AT)
                 or (I.PEAK + (1 - I.PEAK) * (k - I.PEAK_AT) / (1 - I.PEAK_AT))
      scale(R.icon, sk)
      fade(R.icon, 255 * math.min(1, k / 0.3)) -- leads the scale: still fades in without set_scale
      show(R.icon, true)
    end
  end
end

local function gem_pos(t01)
  local x0, y0 = CFG.GEM.FROM_X, CFG.GEM.FROM_Y
  local x1, y1 = CFG.BAG.MOUTH_X, CFG.BAG.MOUTH_Y
  local cx = (x0 + x1) / 2 + 50
  local cy = math.min(y0, y1) - CFG.GEM.ARC
  local u = 1 - t01
  return u * u * x0 + 2 * u * t01 * cx + t01 * t01 * x1,
         u * u * y0 + 2 * u * t01 * cy + t01 * t01 * y1
end

local function tick_pour(t)
  local dt = t - state.t0
  local half = CFG.REWARD.ART / 2
  local landed = 0
  for i = 1, CFG.GEM.N do
    local rec = R.gems[i]
    local k = (dt - (i - 1) * CFG.GEM.STAGGER_MS) / CFG.GEM.FLIGHT_MS
    if k >= 1 then
      landed = landed + 1
      show(rec, false)
    elseif k > 0 then
      -- t*t*(2-t) tracks the demo's cubic-bezier(.5,0,.75,1) within a pixel.
      local e = k * k * (2 - k)
      local x, y = gem_pos(e)
      put(rec, x - half, y - half)
      scale(rec, (CFG.GEM.K_FROM + (CFG.GEM.K_TO - CFG.GEM.K_FROM) * e) * CFG.REWARD_K.FLY)
      fade(rec, 255)
      show(rec, true)
    else
      show(rec, false)
    end
  end

  -- The source gem drains as the gems land, then darts into the bag and goes.
  local k_now = CFG.REWARD_K.PARKED * (1 - landed / CFG.GEM.N * 0.7)
  local gk = (dt - ((CFG.GEM.N - 1) * CFG.GEM.STAGGER_MS + CFG.POPA_GONE.AT_MS)) / CFG.POPA_GONE.MS
  if gk > 0 then
    local e = math.min(1, gk) ^ 2
    put(R.reward, CFG.REWARD.CX - half + CFG.POPA_GONE.DX * e,
        CFG.REWARD.CY - half + CFG.POPA_PARK.DY + CFG.POPA_GONE.DY * e)
    scale(R.reward, k_now + (CFG.REWARD_K.GONE - k_now) * e)
    fade(R.reward, 255 * (1 - e))
    if e >= 1 then show(R.reward, false) end
  else
    put(R.reward, CFG.REWARD.CX - half, CFG.REWARD.CY - half + CFG.POPA_PARK.DY + popa_float(t))
    scale(R.reward, k_now)
    fade(R.reward, 255)
  end

  -- One channel and a 150ms cooldown rule out a sound per gem (95ms apart), so
  -- "pour" is one file with a ting per gem. Normally already cued in tick_bag_in.
  cue_pour(CFG.GEM.FLIGHT_MS - dt)

  local full = landed >= CFG.GEM.N
  bag_state(full and "full" or "open")
  if full and R.spark then
    local S = CFG.FX_SPARK
    local sk = (dt - ((CFG.GEM.N - 1) * CFG.GEM.STAGGER_MS + CFG.GEM.FLIGHT_MS)) / S.MS
    if sk >= 0 and sk <= 1 then
      local a = (sk < S.PEAK_AT) and (sk / S.PEAK_AT) or (1 - (sk - S.PEAK_AT) / (1 - S.PEAK_AT))
      put(R.spark, S.X, S.Y)
      fade(R.spark, 230 * a)
      show(R.spark, true)
    else
      show(R.spark, false)
    end
  end

  tick_count(t, dt)
end

-- Plays the next OUTRO line that has a URL and is accepted; a line without one
-- (url null, not in this frame, refused) is skipped. With the numbers hidden the
-- lines are skipped too: Pika would read numbers the screen does not show. Past
-- the last, the bag leaves. by = how the previous sound ended.
local function outro_next(t, dt, by)
  local i = state.outro_i + 1
  while i <= #OUTRO do
    local line = OUTRO[i]
    local result
    if not state.show_num then
      result = "hidden"
    elseif not state.outro_url[line.alias] then
      result = "no_url"
    else
      result = sound(line.alias) and "ok" or "refused"
    end
    local ok = result == "ok"
    print("egg.outro line=" .. line.name .. " result=" .. result ..
          " prev_by=" .. by .. " ms=" .. dt)
    if ok then
      state.outro_i, state.outro_t0 = i, t
      state.outro_n = state.outro_n + 1
      return
    end
    i = i + 1
  end
  state.outro_i = #OUTRO + 1
  state.leave_t0 = t
  print("egg.leave by=" .. by .. " ms=" .. dt)
end

-- The bag stays shut and the total on show until the cheer at the end of "pour"
-- is over (or CHEER_MAX_MS: its end event lost), then through cp-5 and cp-6, and
-- only then both leave: exiting earlier would cut the applause or the lines.
local function tick_bag_out(t)
  local dt = t - state.t0
  bag_state("closed")
  show(R.spark, false)
  if not state.leave_t0 and dt >= CFG.T_BAG.CLOSE_OUT then
    if state.outro_i == 0 then
      local over = state.playing ~= "pour"
      if over or dt >= CFG.T_BAG.CHEER_MAX_MS then
        outro_next(t, dt, over and "sound_end" or "cap")
      end
    else
      local line = OUTRO[state.outro_i]
      local over = state.playing ~= line.alias
      if over or t - state.outro_t0 >= CFG.OUTRO.LINE_MAX_MS then
        outro_next(t, dt, over and "sound_end" or "cap")
      end
    end
  end
  if state.leave_t0 then
    local lt = t - state.leave_t0
    local k = math.min(1, lt / CFG.BAG.SLIDE_MS)
    for _, rec in pairs(R.bag) do put(rec, bag_x(1 - k), CFG.BAG.Y) end
    local ok = math.min(1, lt / CFG.COUNT.OUT_MS)
    tick_count(t, nil, ok * ok)
  else
    tick_count(t, nil)
  end
end

-- ---------------------------------------------------------------------- voice

local function talking()
  local v = state.voice
  return v == "v1" or v == "v2" or v == "remind"
end

-- Pika is still on the intro: a line playing, or VOICE_2 still to come. The idle
-- clocks wait for it.
local function intro_busy()
  local v = state.voice
  return v == "v1" or v == "gap" or v == "v2"
end

local function voice_over(t)
  if intro_busy() then state.quiet_t0 = t end
  state.voice = "off"
end

local function play_line(alias, mode, t)
  if sound(alias) then
    state.voice, state.voice_t0 = mode, t
    return true
  end
  return false
end

-- A left/right press cuts whatever Pika is saying and drops the line still to
-- come. sound(cue) stops the line before the press's own tick; with no tick (at
-- the ends), the line is stopped alone.
local function press_cuts_voice(cue, t)
  local was = talking()
  voice_over(t)
  if not (cue and sound(cue)) and was then hush() end
end

local function tick_voice(t)
  if state.voice == "gap" then
    if t - state.gap_t0 >= CFG.VOICE.GAP_MS and not play_line(VOICE_2, "v2", t) then
      voice_over(t)
    end
  elseif talking() and t - state.voice_t0 >= CFG.VOICE.MAX_MS then
    print("egg.voice result=timeout line=" .. state.voice .. " ms=" .. (t - state.voice_t0))
    voice_over(t)
  end
end

function on_sound_end(alias, reason)
  -- STOPPED comes only from hush(), which already let go of it; ignoring it keeps
  -- a replay of the same alias tracked.
  if alias == state.playing and reason ~= Speaker.REASON_STOPPED then state.playing = nil end
  local v, t = state.voice, now()
  if v == "v1" and alias == VOICE_1 then
    if reason == Speaker.REASON_COMPLETED then
      state.voice, state.gap_t0 = "gap", t
    else
      voice_over(t)
    end
  elseif (v == "v2" and alias == VOICE_2)
      or (v == "remind" and (alias == REMIND[1] or alias == REMIND[2])) then
    voice_over(t)
  end
end

-- The finish ring overflowed: our line's end may be among the lost events.
function on_sound_lost(count)
  print("egg.voice result=lost count=" .. tostring(count) .. " line=" .. state.voice)
  if talking() then voice_over(now()) end
end

-- ---------------------------------------------------------------------- hooks

-- From here the gift is given: later frames cannot change it. i is the 1-based
-- egg. It indexes options[] (the wire index is one less), except past the end:
-- the scene always shows three eggs, so with fewer options the extra eggs share
-- the last one rather than send an index the server answers with a 400.
local function choose(i, by)
  build_tail()
  state.chosen, state.locked = i, true
  -- sound() stops any voice line first, even when "pick" itself is refused.
  state.voice = "off"
  if not sound("pick") then state.pick_t0 = now() end

  local n = state.options and #state.options or 0
  state.opt_idx = (n > 0 and i > n) and n or i
  local opt = state.options and state.options[state.opt_idx]
  local amount = type(opt) == "table" and tonumber(opt.amount) or nil
  state.show_num = false
  if amount and amount >= 1 and state.week_known then
    state.gems, state.show_num = math.floor(amount), true
    text_set(plus_txt, "+" .. state.gems)
  end
  print("egg.choose idx=" .. (i - 1) .. " by=" .. by .. " opts=" .. n ..
        " gems=" .. (state.show_num and state.gems or 0) ..
        " week=" .. (state.week_known and state.week_before or -1) ..
        " tick_skip=" .. state.tick_skip ..
        (n > 0 and i > n and " result=out_of_range mapped=" .. (n - 1) or ""))

  local sent = tel.event("pick", {
    item = state.opt_idx - 1, via = (by == "press") and "enter" or "auto", opts = n,
    gems = i32(state.show_num and state.gems or 0), remind = state.remind_n,
    dur_ms = now() - state.start_ms, mapped = n > 0 and i > n,
  })
  print("egg.tel ev=pick sent=" .. tostring(sent))
end

-- Report BEFORE exit: report_result does not end the session, exit does. A failed
-- report means back's reward POST has no selected index (400, play rolled back).
local function finish(event)
  local ok, err = "no_engine", nil
  if Engine and Engine.report_result then ok, err = Engine.report_result({ event = event }) end
  print("egg.report result=" .. (ok and "ok" or "fail") .. " err=" .. tostring(err) ..
        " event=" .. event)
  -- error level: a failed report means back's reward POST fails (400).
  local reported = ok == true
  local sent = tel.event("egg.done", {
    item = state.opt_idx - 1, score = i32(state.show_num and state.gems or 0),
    outro = state.outro_n, report = reported, dur_ms = now() - state.start_ms,
    failed = load_failed, fallback = state.fallback,
  }, not reported and { level = "error" } or nil)
  print("egg.tel ev=egg.done sent=" .. tostring(sent))
  if Engine and Engine.exit then Engine.exit("egg.opened") end
end

function on_tick(dt_ms)
  elapsed = elapsed + (dt_ms or 33)
  local t = now()
  local s = state.scene
  if not state.tail_built and (state.tail_due or t - state.start_ms >= FRAME_WAIT_MS) then
    build_tail()
  end
  -- The drop clock starts on the first tick with the game screen up, so the
  -- egg falls are all on screen.
  if state.reveal == "showing" or (state.reveal == "wait" and state.tail_built and not state.held) then
    state.reveal = "up"
    if s == DROP then state.t0 = t end -- a press while held may have skipped it
    print("egg.show scene=" .. s .. " ms=" .. (t - state.start_ms))
  elseif state.reveal == "wait" and state.tail_built then
    state.held = false
    Engine.show()
    state.reveal = "showing"
  end
  if not state.locked then tick_voice(t) end
  if state.pick_t0 then
    local ok = sound("pick")
    if ok or t - state.pick_t0 >= CFG.PICK_RETRY_MS then
      print("egg.pick retry=" .. (ok and "ok" or "gave_up") .. " ms=" .. (t - state.pick_t0))
      state.pick_t0 = nil
    end
  end

  if s == DROP then
    if state.reveal == "up" then tick_drop(t) end
  elseif s == BROWSE then
    tick_browse(t)
    -- v3 wait_choice: the clocks run once the intro is over, from the later of
    -- its end and the last press. The reminder does not restart them; a press
    -- clears `reminded`, so each quiet spell gets one.
    if not intro_busy() then
      local idle = t - math.max(state.last_input, state.quiet_t0)
      if not state.reminded and idle >= CFG.IDLE.REMIND_MS then
        state.reminded = true
        if state.lang_vi then
          state.remind_n = state.remind_n + 1
          local line = REMIND[(state.remind_n - 1) % #REMIND + 1]
          local ok = play_line(line, "remind", t)
          print("egg.voice line=" .. line .. " result=" .. (ok and "ok" or "refused"))
        end
      end
      if idle >= CFG.IDLE.AUTO_MS then
        choose(state.sel, "auto")
        enter(GATHER, t)
      end
    end
  elseif s == GATHER then
    tick_gather(t)
    if t - state.t0 >= CFG.T.GATHER then
      enter(SHAKE, t)
      sound("shake")
    end
  elseif s == SHAKE then
    tick_shake(t)
    if t - state.t0 >= CFG.T.OPEN - CFG.T.GATHER then
      enter(OPEN, t)
      sound("hatch")
    end
  elseif s == OPEN then
    tick_open(t)
    if t - state.t0 >= CFG.T.SETTLE then enter(BAG_IN, t) end
  elseif s == BAG_IN then
    tick_bag_in(t)
    if t - state.t0 >= CFG.T_BAG.SLIDE_IN + CFG.T_BAG.OPEN_HOLD then enter(POUR, t) end
  elseif s == POUR then
    tick_pour(t)
    local pour_ms = (CFG.GEM.N - 1) * CFG.GEM.STAGGER_MS + CFG.GEM.FLIGHT_MS
    if t - state.t0 >= pour_ms + CFG.T_BAG.FULL_HOLD then enter(BAG_OUT, t) end
  elseif s == BAG_OUT then
    tick_bag_out(t)
    if state.leave_t0 and t - state.leave_t0 >= CFG.BAG.SLIDE_MS then
      enter(DONE, t)
      -- Backend contract (docs/to-do-journey/map-flows.md): selected_option_index
      -- is 0-based and resolves the reward; score is the gem count the child saw,
      -- 0 when the numbers were hidden. Must stay under 255 bytes.
      finish('{"ev":"egg.opened","result":{"selected_option_index":' ..
             (state.opt_idx - 1) .. ',"score":' .. (state.show_num and state.gems or 0) .. '}}')
    end
  end
end

-- Called once per input event (PRESS, RELEASE, REPEAT), possibly several times in
-- one frame, so it acts on the event itself rather than on Input.just_pressed.
-- During the drop any press skips to the eggs; while browsing, left/right move
-- the cursor (stopping at the ends) and confirm opens the egg.
function on_input(action, phase)
  if phase ~= Input.PRESS then return end
  local t = now()
  print("egg.input action=" .. tostring(action) .. " scene=" .. state.scene .. " sel=" .. state.sel)

  if state.scene == DROP then
    for i, egg in ipairs(R.eggs) do
      place(egg, i, 0, 0)
      fade_egg(egg, 255)
      show_egg(egg, true)
    end
    enter(BROWSE, t)
    state.last_input = t
    if action ~= "confirm" then press_cuts_voice(nil, t) end
    return
  end
  if state.scene ~= BROWSE then return end

  if action == "confirm" then
    choose(state.sel, "press")
    enter(GATHER, t)
    return
  end
  local step = (action == "left" and -1) or (action == "right" and 1) or 0
  if step == 0 then return end
  state.last_input, state.reminded = t, false
  local to = state.sel + step
  local moved = to >= 1 and to <= #CFG.EGGS
  if moved then state.sel, state.hop_t0 = to, t end
  -- Debounce the tick, not the cursor: inside the gap the tick already playing
  -- carries on, and the voice is still cut.
  local tick = moved and (not state.tick_t0 or t - state.tick_t0 >= CFG.SELECT_SFX.GAP_MS)
  if tick then
    state.tick_t0 = t
  elseif moved then
    state.tick_skip = state.tick_skip + 1
  end
  press_cuts_voice(tick and SELECT or nil, t)
end

-- Journey frame (op "journey"), sent right after STARTED. Only the first one
-- counts and none once the egg is chosen: B re-randomizes reward_options on every
-- call, so a later frame would not match what the server stored for these eggs.
function on_pack_cmd(cmd)
  if type(cmd) ~= "table" or cmd.op ~= "journey" then return end
  state.tail_due = true
  state.frame_seen = true
  if state.locked or state.options then
    print("egg.frame result=ignored reason=" .. (state.locked and "chosen" or "duplicate"))
    return
  end
  local data = type(cmd.args) == "table" and cmd.args.data or nil
  local cps = type(data) == "table" and data.checkpoints or nil
  if type(cps) ~= "table" then
    state.frame_reason = "no_checkpoints"
    print("egg.frame result=no_data reason=no_checkpoints")
    return
  end

  -- This launch's node: the TODO mid reward that carries options.
  local node
  for _, cp in ipairs(cps) do
    if type(cp) == "table" and cp.category == "MID_REWARD" and cp.status == "TODO"
       and type(cp.reward_options) == "table"
       and (state.milestone == nil or cp.milestone_index == state.milestone) then
      node = cp
      break
    end
  end
  local opts = node and node.reward_options.options
  if type(opts) ~= "table" or #opts == 0 then
    state.frame_reason = "no_options"
    print("egg.frame result=no_data reason=no_options milestone=" .. tostring(state.milestone))
    return
  end

  -- total_xp is the child's current total, the same on every option.
  local xp
  for _, o in ipairs(opts) do
    xp = type(o) == "table" and tonumber(o.total_xp) or nil
    if xp then break end
  end
  local eq = node.reward_options.equipped_item_id
  local bag = type(eq) == "string" and CFG.BAGS[eq] or nil
  if bag and not state.tail_built then state.bag = bag end
  state.options, state.item_ok, state.frame_reason = opts, bag ~= nil, nil
  if xp and xp >= 0 then
    state.week_before = math.floor(xp)
    state.shown = state.week_before
    state.week_known = true
  end

  -- cp-5/cp-6 come in the same response as these options (BE removes them when
  -- the current node is not this TODO mid reward), so they say this frame's
  -- amount. url null = no audio yet: leave the alias empty, the line is skipped.
  local tm = data.theme_meta
  local audio = type(tm) == "table" and tm.audio or nil
  local dyn = type(audio) == "table" and audio.dynamic or nil
  for _, line in ipairs(OUTRO) do
    local url
    if type(dyn) == "table" then
      for _, e in ipairs(dyn) do
        if type(e) == "table" and e.name == line.name then
          url = e.url
          break
        end
      end
    end
    local ok = type(url) == "string" and Speaker and Speaker.set_url
               and Speaker.set_url(line.alias, url) or false
    state.outro_url[line.alias] = ok
    if ok then state.url_n = state.url_n + 1 end
    print("egg.outro_url line=" .. line.name .. " result=" ..
          (ok and "ok" or (type(url) == "string" and "rejected" or "missing")) ..
          " len=" .. (type(url) == "string" and #url or 0))
  end

  local amounts = {}
  for i, o in ipairs(opts) do
    amounts[i] = type(o) == "table" and tostring(o.amount) or "?"
  end
  -- The prefix is documented in docs/to-do-journey/journey-data-flow.md: keep it.
  print("egg: journey frame ok milestone=" .. tostring(state.milestone) ..
        " amounts=" .. table.concat(amounts, "/") .. " total_xp=" .. tostring(xp) ..
        " item=" .. tostring(eq) .. " bag=" .. state.bag ..
        (state.tail_built and bag and bag ~= state.bag and " result=bag_too_late" or ""))
end
