-- End-of-day chest (P14/P15): hold the star, the chest opens, today's jigsaw
-- piece rises out of it and flies into the backpack. Port of
-- game_ruong_refined/demo.html: same phases, timings and physics.
--
-- Data: back launches with {"milestone_index":-1}, then sends the journey frame
-- (on_pack_cmd). From it: theme_id picks the chest (libs/chests.lua),
-- checkpoints[FINAL_REWARD].final_reward gives pieces_owned and the backpack,
-- theme_meta.audio gives the cp-4 narration url. The backpack drawn is the
-- set's prize (reward_item_id, when reward_type is SHOP_ITEM), else the one
-- the child wears (equipped_item_id), else GEO.DEFAULT; ids map to art via
-- libs/geometry.lua BAGS, as in 01_mid_reward_egg.
-- A set is always 6 pieces (the game's contract with the server): pieces_total
-- is only logged. pieces_owned is the count BEFORE this open, so piece
-- owned+1 is in the chest, and the set completes when that piece is the 6th.
-- No frame within FRAME_WAIT_MS: default chest and backpack, piece 1; a frame
-- arriving later still swaps in its chest and backpack while the star has not
-- been touched. A launch without milestone_index (menu, ASSIGN_GAME) gets no
-- frame: defaults at once.
-- Report: {"ev":"balo.opened"} (back completes the reward on "*.opened"), or
-- "balo.load_failed;..." when the art cannot load (the reward stays open).
--
-- Voice (as 01_mid_reward_egg): once the chest shows, Pika says VOICE[1]; with
-- no press, VOICE[2] follows GAP_MS after it. The robot's language picks the
-- vi or en_ file. A press cuts the line and drops the one still to come. The
-- auto-open clock runs from the end of the intro.
--
-- Robot vs browser (art by tools/egg-assets/convert_ruong_refined.py, sounds by
-- sfx_ruong_refined.py; the backpacks by convert_game_reward_01.py):
--   * Nothing is scaled or rotated (each costs 1.5-6x a plain draw). The gift
--     rises and fades in instead of growing, the flight and fall do not tilt,
--     the backpack does not squash, the lock swings sideways and drops without
--     turning, and at 6/6 the pieces cross-fade into the bigger uncut picture.
--   * What covers a large area changes in a few steps, not every frame (each
--     step is a redraw of that area): the beam, the chest dimming and hiding,
--     the backpack fading in, the 6/6 glow. The chest hides as the piece
--     leaves it instead of sliding down. Motion runs on the real clock, so a
--     slow frame skips ahead instead of slowing the scene down.
--   * The engine plays one sound at a time and refuses a play within 150ms of
--     the last: a refused cue is retried for SFX_RETRY_MS. A newer play does
--     not replace the current one on the robot, it queues, so every play stops
--     ours first (hush). The hold notes (one per 1/9 of the bar, 133 ms apart)
--     are pre-mixed: hold_k is notes k..8, started on press, stopped on release.
--   * Robot-only: the bar fills by itself after IDLE_OPEN_MS without progress;
--     cp-4 plays after the landing, once the fanfare is over.
--
-- Telemetry (game.tel): three milestones a play - balo.frame (what the frame
-- gave, once the chest and set are loaded), reward.open (the lock opens),
-- balo.done (before Engine.exit: calls from game_end are refused). They never
-- come three within 5 s, the head's rate window.

local GEO = require("libs/geometry")
local LAY = require("libs/layout")
local CHEST = require("libs/chests")
local tel = require("libs/tel")

-- ---------------------------------------------------------------- constants

local FLOOR = 276                 -- backpack's foot
local MOUTH_X = 240               -- gift centre in the chest (y per chest)
local RISE_X, RISE_Y = 240, 118   -- gift centre once risen (y overridable per chest)

local G, REST, HOP, K, C = 900, 0.38, 0.34, 700, 14
local FALL_V0 = 40
local HOLD_S, DECAY = 1.2, 0.6
local HOLD_NOTES = 8              -- one note per 1/9 of the bar
local UNTIE_S, OPEN_AT = 0.6, 0.45
local BEAM_S = 0.6
local RISE_S, RISE_END = 1.6, 3.2   -- afloat until 3.2 s
local RISE_FADE = 0.3               -- of RISE_S: the piece fades in as it rises
local DIM = { { 1.1, 0.8 }, { 1.5, 0.55 } }   -- chest dims in two steps while the gift rises
local DIM_TO = 0.55
local MOVE_S = 1.2
local HIDE_S = 0.3                -- chest out / backpack in, at the start of the flight
local FINAL_SWAP_S = 0.45         -- 6/6: pieces -> uncut picture, in thirds
local GLOW_IN_S, GLOW_PULSE_S = 1.1, 0.7
local MAX_DT = 0.25               -- a long frame skips ahead at most this much
local SUB_DT = 0.016              -- integration step (the K spring needs it small)
local DUST_N, SPARK_N = 12, 12
local SPARK_EVERY_RISE, SPARK_EVERY_FINAL = 0.12, 0.15

local FRAME_WAIT_MS = 3000
local LOAD_BUDGET_MS = 25         -- asset loading per tick
local IDLE_OPEN_MS = 10000
local DONE_HOLD_MS = 2500
local NARR = "cp-4"
local NARR_RETRY_MS = 1000
local NARR_CAP_MS = 15000         -- from cp-4's own start (fetch + speech)
local SFX_RETRY_MS = 300
local HOLD_GAP_MS = 300           -- hold notes start at most this often (star mashing)
local FANFARE_CAP_MS = 5500       -- fanfare.mp3 is ~4.9 s
local FINAL_TAIL_MS = 2000
local TWINKLE_MIN_MS, TWINKLE_SPAN_MS = 450, 650
local VOICE_GAP_MS, VOICE_MAX_MS = 3000, 15000

local TWINKLES = { "twinkle1", "twinkle2", "twinkle3" }

local S = {}   -- game state
local R = {}   -- sprites and the load queue

-- ---------------------------------------------------------------- helpers

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(v) return math.floor(v + 0.5) end

-- v in 0..1 rounded down to n steps: a fade that redraws n times, not per frame.
local function steps(v, n) return math.floor(clamp(v, 0, 1) * n + 1e-6) / n end

local function out3(p) return 1 - (1 - p) ^ 3 end
local function in2(p) return p * p end
local function io3(p)
  if p < 0.5 then return 4 * p * p * p end
  return 1 - (-2 * p + 2) ^ 3 / 2
end
local function back(p) return 1 + 2.5 * (p - 1) ^ 3 + 1.5 * (p - 1) ^ 2 end

-- Serial log: "ruong.<event> key=value ..." (docs/LOGGING.md), t = ms since start.
local function log(msg)
  print("ruong." .. msg .. " t=" .. (Timer.millis() - (S.t0 or 0)))
end

-- ---------------------------------------------------------------- sprites

-- A sprite plus the last value sent to each setter: a setter only reaches the
-- engine when its value changes.
local function obj(spr)
  if not spr then return nil end
  spr:set_visible(false)
  return { s = spr, vis = false }
end

local function load_img(path)
  local spr, err = Sprite.image(path)
  if not spr then
    log("load result=fail path=" .. path .. " err=" .. tostring(err))
    R.load_failed = R.load_failed + 1
    return nil
  end
  local o = obj(spr)
  o.w, o.h = spr:get_size()
  return o
end

local function show(o, v)
  if o and o.vis ~= v then o.vis = v; o.s:set_visible(v) end
end

local function pos(o, x, y)
  if not o then return end
  x, y = round(x), round(y)
  if o.x ~= x or o.y ~= y then o.x, o.y = x, y; o.s:set_pos(x, y) end
end

local function opa(o, a)
  if not o then return end
  a = clamp(round(a * 255), 0, 255)
  if o.opa ~= a then o.opa = a; o.s:set_opacity(a) end
  show(o, a > 0)
end

-- Centre an object on (x, y).
local function place(o, x, y)
  if o then pos(o, x - o.w / 2, y - o.h / 2) end
end

local function front(o) if o then o.s:to_front() end end

-- ---------------------------------------------------------------- sound

-- On the robot a newer play does NOT replace the current one: game sounds are all
-- HIGH and HIGH does not preempt HIGH, so it queues behind the one playing
-- (01_mid_reward_egg's robot log 07/10).
-- Stopping a playing sound is what costs: the head parks its pipeline for a
-- cleanup that only runs when the speaker has been quiet for 3 s, and with 5
-- parked every further stop blocks the caller for 2 s, past the 1.5 s Lua
-- watchdog (log 09/10 00:27: 8 stops in one open, killed at the landing). So a
-- cue never stops another: it queues (the cues are cut to end before the next
-- one), or it only plays when the speaker is free (bounces, twinkles). Only
-- two stops are left per open: Pika cut by the first press, and the hold notes
-- cut by the unlock. Never stop_all beside a play: it is drained at the end of
-- the tick, after the play, and clears the queue with it.
local function hush()
  local a = S.playing
  S.playing = nil
  if a then
    Speaker.stop(a)
    S.stops = S.stops + 1
  end
end

local function play(alias)
  if Speaker.play(alias) then
    S.playing = alias
    return true
  end
  return false
end

-- Nothing of ours is playing and the speaker is free.
local function quiet()
  return not S.playing and not Speaker.is_busy()
end

-- A refused play (150ms gate) is kept and retried from on_tick; the newest wins.
-- It queues behind a sound still playing.
local function sound(alias)
  if play(alias) then
    S.snd_pend = nil
  else
    S.snd_pend, S.snd_until = alias, Timer.millis() + SFX_RETRY_MS
  end
end

local function retry_sound(now)
  local a = S.snd_pend
  if not a then return end
  if now > S.snd_until then
    log("sound result=dropped alias=" .. a)
    S.snd_pend = nil
  elseif play(a) then
    S.snd_pend = nil
  end
end

-- A cue that may be left out: only when the speaker is free, never retried.
local function sound_if_quiet(alias)
  if quiet() then
    play(alias)
  else
    S.sfx_skip = S.sfx_skip + 1
  end
end

-- Hold notes: on press, the notes still ahead on the bar, when the speaker is
-- free (or right after the press cut Pika: they queue behind her line's stop).
-- A release lets them ring out: stopping them would cost the head a pipeline.
-- A press within HOLD_GAP_MS of the last notes stays silent (star mashing).
local function hold_sound(on)
  if not on then return end
  local k = math.floor(S.level * (HOLD_NOTES + 1) + 1e-6) + 1
  local now = Timer.millis()
  if k > HOLD_NOTES then return end
  if now - (S.hold_ms or -HOLD_GAP_MS) < HOLD_GAP_MS or not (S.voice_cut or quiet()) then
    S.hold_skip = S.hold_skip + 1
    return
  end
  S.voice_cut = false
  S.hold_ms = now
  sound("hold_" .. k)
end

-- ---------------------------------------------------------------- voice

-- Pika is still on the intro: a line playing, or VOICE[2] still to come.
local function intro_busy()
  local v = S.voice
  return v == "v1" or v == "gap" or v == "v2"
end

local function voice_over(now)
  if intro_busy() then S.idle_ms = math.max(S.idle_ms, now) end
  S.voice = "off"
end

local function voice_line(i, mode, now)
  if play(S.voices[i]) then
    S.voice, S.voice_t0 = mode, now
    log("voice line=" .. S.voices[i] .. " result=ok")
    return true
  end
  log("voice line=" .. S.voices[i] .. " result=refused")
  return false
end

local function tick_voice(now)
  local v = S.voice
  if v == "gap" then
    if now - S.gap_t0 >= VOICE_GAP_MS and not voice_line(2, "v2", now) then
      voice_over(now)
    end
  elseif (v == "v1" or v == "v2") and now - S.voice_t0 >= VOICE_MAX_MS then
    log("voice result=timeout line=" .. v)
    voice_over(now)
  end
end

-- ---------------------------------------------------------------- narration

-- cp-4 when the frame gave it a url; retried while the play gate refuses it.
-- Nothing pending may preempt it.
local function try_narration(now)
  if S.narr_state ~= "wait" then return end
  if play(NARR) then
    S.narr_state, S.snd_pend, S.narr_t0 = "playing", nil, now
    log("narr result=play")
  elseif now - S.narr_from >= NARR_RETRY_MS then
    S.narr_state = "over"
    log("narr result=refused")
  end
end

local function start_narration(now)
  if S.narr_state then return end
  S.narr_from = now
  S.narr_state = S.narr_ready and "wait" or "over"
  try_narration(now)
end

local function finish(event, piece)
  log("exit ev=" .. event .. " piece=" .. tostring(piece) .. "/" .. tostring(S.total) ..
      " stops=" .. tostring(S.stops) .. " sfx_skip=" .. tostring(S.sfx_skip))
  local ok, err = Engine.report_result({ event = event })
  if not ok then log("report result=fail err=" .. tostring(err)) end
  local opened = event:sub(1, 16) ~= "balo.load_failed"
  local reported = ok == true
  local sent = tel.event("balo.done", {
    result = opened and "opened" or "load_failed", piece = piece, complete = S.complete,
    narr = S.narr_t0 ~= nil, report = reported, dur_ms = Timer.millis() - S.t0,
    failed = R.load_failed, stops = S.stops,
  }, not (opened and reported) and { level = "error" } or nil)
  log("tel ev=balo.done sent=" .. tostring(sent))
  S.phase = "exit"
  Engine.exit(event)
end

-- ---------------------------------------------------------------- loading

-- Draw order is creation order, and the set is only known once the frame has
-- landed, so the layers are re-stacked into the demo's z order after each load
-- stage. The rising gift sits between the open lid and the chest's front, or
-- over the rim once a chest's `over` point is passed.
local function restack()
  local order = { R.bg, R.glow, R.shadow, R.dong, R.mo, R.beam, R.mouth }
  local function add(o) order[#order + 1] = o or false end
  if not S.inner_over then add(R.halo_in); add(R.inner) end
  add(R.front)
  add(R.khoa)
  if S.inner_over then add(R.halo_in); add(R.inner) end
  for i = 1, GEO.PIECES do
    if i == S.n then add(R.halo_top) end
    add(R.pieces[i])
  end
  add(R.closed)
  for _, p in ipairs(R.dust) do add(p.o) end
  for _, p in ipairs(R.spark) do add(p.o) end
  add(R.cta)
  add(R.track)
  for i = 1, #LAY.HOLD_SEG_RGB565 do add(R.seg[i]) end
  for i = 1, #order do
    if order[i] then order[i].s:to_front() end
  end
end

local function queue(fn) R.jobs[#R.jobs + 1] = fn end

-- Ahead of what game_start queued (particles), in call order.
local function queue_next(fn)
  R.ins = math.max(R.ins or 0, R.job_i)
  table.insert(R.jobs, R.ins, fn)
  R.ins = R.ins + 1
end

local function pump()
  local t0 = Timer.millis()
  while R.job_i <= #R.jobs and S.phase ~= "exit" do
    local fn = R.jobs[R.job_i]
    R.jobs[R.job_i] = false
    R.job_i = R.job_i + 1
    fn()
    if Timer.millis() - t0 >= LOAD_BUDGET_MS then break end
  end
end

local function kill(o) if o then o.s:destroy() end end

-- A backpack id with art, or nil.
local function bag_art(id)
  local name = type(id) == "string" and GEO.BAGS[id] or nil
  return (name and GEO.SETS[name]) and name or nil
end

-- The set's prize when it is a backpack we have art for, else the backpack the
-- child wears, else DEFAULT. A prize that is not a backpack (or CRYSTAL) is
-- normal; an unknown worn id is logged as before.
local function pick_set(F)
  local name = F.reward_type == "SHOP_ITEM" and bag_art(F.reward_item) or nil
  if name then return name, "reward" end
  name = bag_art(F.equipped)
  if name then return name, "equipped" end
  if F.equipped ~= nil then log("fallback what=bag value=" .. tostring(F.equipped)) end
  return GEO.DEFAULT, "default"
end

-- Everything the chest and the set need, from the frame fields F (theme_id,
-- owned, reward_type, reward_item, equipped). Pure: nothing is drawn or loaded.
local function plan(F)
  local key = F.theme_id
  local ch = type(key) == "string" and CHEST.CHESTS[key] or nil
  if not ch then
    if key ~= nil then log("fallback what=theme value=" .. tostring(key)) end
    key = CHEST.DEFAULT
    ch = CHEST.CHESTS[key]
  end
  local slug, src = pick_set(F)
  local set = GEO.SETS[slug]
  local have = F.owned or 0
  local P = { ch = ch, ch_key = key, slug = slug, bag_src = src, set = set,
              full = have >= GEO.PIECES }
  P.n = P.full and GEO.PIECES or (have + 1)
  -- A set is always 6 pieces (the game's contract with the server).
  P.complete = P.n == GEO.PIECES
  -- Backpack box centred on x=240, foot on FLOOR.
  local left, top = 240 - set.box_w / 2, FLOOR - GEO.DISP_H
  P.geo = {}
  for i, p in ipairs(set.pieces) do
    P.geo[i] = { cx = left + p.off_x + p.w / 2, cy = top + p.off_y + p.h / 2,
                 top = top + p.off_y }
  end
  -- Top-row pieces drop from lower so they stay on screen.
  P.hover = -math.min(110, P.geo[P.n].top - 14)
  return P
end

local function apply_plan(P)
  S.ch, S.ch_key, S.mouth_y = P.ch, P.ch_key, P.ch.mouth_y
  S.slug, S.bag_src, S.box_w, S.closed_def = P.slug, P.bag_src, P.set.box_w, P.set.closed
  S.full, S.n, S.complete, S.geo, S.hover = P.full, P.n, P.complete, P.geo, P.hover
end

-- The chest shows once, whole: closed chest, lock, the hold prompt and bar in
-- one tick, then Pika's line. Loads what the open needs first, so nothing
-- appears late on the chest.
local function reveal()
  local dir = "assets/runtime/"
  R.beam = R.beam or load_img(dir .. "beam.png")
  R.mouth = R.mouth or load_img(dir .. "mouth.png")
  restack()
  S.chest_ready = true
  local now = Timer.millis()
  S.idle_ms = now   -- the auto-open clock, held while Pika speaks
  S.reveal_ms = now
  local held = S.held
  if held then
    S.held = false
    Engine.show()   -- the screen goes up after this hook, all in one frame
  end
  log("reveal chest=" .. tostring(S.ch_key) .. " lock=" .. tostring(R.khoa ~= nil) ..
      " open_layers=" .. tostring(R.mo ~= nil and R.front ~= nil) ..
      " load_failed=" .. R.load_failed .. " held=" .. tostring(held))
  if not S.pressed then voice_line(1, "v1", now) end
end

-- Chest layers into dst (R, or a staging table for a late frame), each job
-- added with `add`.
local function queue_chest_loads(P, dst, add)
  local dir = "assets/runtime/chests/" .. P.ch_key .. "/"
  for _, k in ipairs({ "dong", "khoa", "mo", "front" }) do
    add(function () dst[k] = load_img(dir .. P.ch[k].file) end)
  end
  if dst == R then add(reveal) end
end

local function queue_set_loads(P, dst)
  local def, n = P.set, P.n
  local pn = def.pieces[n]
  local dir = "assets/runtime/"
  for i = 1, n do
    queue(function () dst.pieces[i] = load_img(dir .. def.pieces[i].file) end)
  end
  -- A second copy of piece n rises inside the chest, and the halo has a copy
  -- per layer (in the chest, then over the backpack).
  queue(function () dst.inner = load_img(dir .. pn.file) end)
  queue(function ()
    local f = dir .. "halo.png"
    dst.halo_in, dst.halo_top = load_img(f), load_img(f)
  end)
  if P.complete then
    queue(function () dst.glow = load_img(dir .. "glow.png") end)
    queue(function () dst.closed = load_img(dir .. def.closed.file) end)
  end
end

local CHEST_KEYS = { "dong", "khoa", "mo", "front" }
local SET_KEYS = { "inner", "halo_in", "halo_top", "closed", "glow" }

local function kill_chest(t)
  for _, k in ipairs(CHEST_KEYS) do kill(t[k]); t[k] = nil end
end

local function kill_set(t)
  for _, k in ipairs(SET_KEYS) do kill(t[k]); t[k] = nil end
  for i = 1, GEO.PIECES do kill((t.pieces or {})[i]) end
  t.pieces = {}
end

local function queue_set()
  S.set_queued = true
  local P = plan(S)
  apply_plan(P)
  queue_chest_loads(P, R, queue_next)
  queue_set_loads(P, R)
  queue(function ()
    restack()
    -- The scene has committed to its data: this is what the child gets (a late
    -- frame may still swap it before the star is touched; reward.open says so).
    local result = S.frame_result or "ok"
    local sent = tel.event("balo.frame", {
      result = result, theme_ok = type(S.theme_id) == "string" and CHEST.CHESTS[S.theme_id] ~= nil,
      bag_src = S.bag_src, owned = S.owned, piece = S.n, narr = S.narr_ready == true,
      failed = R.load_failed,
    }, (result ~= "ok" and result ~= "no_journey") and { level = "warn" } or nil)
    log("tel ev=balo.frame result=" .. result .. " sent=" .. tostring(sent))
    if not (R.pieces[S.n] and R.inner and R.dong) then
      finish("balo.load_failed;set=" .. S.slug .. ";piece=" .. S.n, S.n)
      return
    end
    S.ready = true
    log("ready chest=" .. S.ch_key .. " set=" .. S.slug .. " owned=" .. tostring(S.owned) ..
        " total=" .. tostring(S.total) .. " piece=" .. S.n ..
        " complete=" .. tostring(S.complete) .. " load_failed=" .. R.load_failed)
  end)
end

-- The star has not been touched: the chest and set on screen may still change.
local function untouched()
  return S.phase == "idle" and S.best == 0 and not S.holding and not S.auto
end

-- A frame that came after the defaults were queued. While the star is
-- untouched, its chest and set load beside the ones on screen (no blank frame,
-- at the cost of both in PSRAM for a moment) and are swapped in at once; once
-- the child has started, the screen stays as it is.
local function late_frame(F)
  if not untouched() then
    log("frame result=ignored reason=late bag_too_late=1")
    return
  end
  local P = plan(F)
  local new_chest = P.ch_key ~= S.ch_key
  local new_set = P.slug ~= S.slug or P.n ~= S.n or P.complete ~= S.complete
  if not (new_chest or new_set) then
    S.owned, S.total = F.owned, F.total
    log("frame result=ignored reason=late same=1")
    return
  end
  local St = { pieces = {} }
  if new_chest then queue_chest_loads(P, St, queue) end
  if new_set then queue_set_loads(P, St) end
  log("frame result=late_rebuild chest=" .. P.ch_key .. " bag=" .. P.slug ..
      " bag_src=" .. P.bag_src .. " piece=" .. P.n)
  queue(function ()
    local loaded = (not new_chest or (St.dong and St.khoa)) and
                   (not new_set or (St.pieces[P.n] and St.inner))
    if not untouched() or not loaded then
      kill_chest(St); kill_set(St)
      log("frame result=late_dropped why=" .. (loaded and "started" or "load_fail"))
      return
    end
    if new_chest then
      kill_chest(R)
      for _, k in ipairs(CHEST_KEYS) do R[k] = St[k] end
    end
    if new_set then
      kill_set(R)
      R.pieces = St.pieces
      for _, k in ipairs(SET_KEYS) do R[k] = St[k] end
    end
    apply_plan(P)
    S.theme_id, S.equipped, S.reward_type, S.reward_item = F.theme_id, F.equipped,
        F.reward_type, F.reward_item
    S.owned, S.total = F.owned, F.total
    S.late = true
    restack()
    log("frame result=late_applied chest=" .. S.ch_key .. " bag=" .. S.slug ..
        " bag_src=" .. S.bag_src .. " piece=" .. S.n .. " complete=" .. tostring(S.complete))
  end)
end

-- ---------------------------------------------------------------- particles

local function spawn(pool, x, y, vx, vy, max)
  for _, q in ipairs(pool) do
    if not q.live and q.o then
      q.live, q.x, q.y, q.vx, q.vy, q.life, q.max = true, x, y, vx, vy, 0, max
      return
    end
  end
end

local function dust(speed)
  for i = 1, DUST_N do
    local side = (i % 2 == 1) and 1 or -1
    local sp = (120 + math.random() * 260) * (speed / 1450)
    spawn(R.dust, 240 + side * (S.box_w * 0.28 + math.random() * 18),
          FLOOR - 2 - math.random() * 6, side * sp, -(40 + math.random() * 140),
          0.45 + math.random() * 0.35)
  end
end

local function sparkle(x, y, rad)
  local a = math.random() * math.pi * 2
  spawn(R.spark, x + math.cos(a) * rad * 1.15, y + math.sin(a) * rad * 0.85, 0, -12,
        0.7 + math.random() * 0.5)
end

local function step_particles(dt)
  for _, q in ipairs(R.dust) do
    if q.live then
      q.life = q.life + dt
      if q.life > q.max then q.live = false
      else
        q.vy = q.vy + 520 * dt; q.vx = q.vx * 0.985
        q.x = q.x + q.vx * dt; q.y = q.y + q.vy * dt
      end
    end
  end
  for _, q in ipairs(R.spark) do
    if q.live then
      q.life = q.life + dt
      if q.life > q.max then q.live = false
      else
        q.vy = q.vy * 0.99
        q.x = q.x + q.vx * dt; q.y = q.y + q.vy * dt
      end
    end
  end
end

local function any_particles()
  for _, q in ipairs(R.dust) do if q.live then return true end end
  for _, q in ipairs(R.spark) do if q.live then return true end end
  return false
end

-- ---------------------------------------------------------------- simulation

local function go(phase) S.phase = phase; S.t = 0 end

local function impact(speed)
  go("hop")
  S.has_stack = true
  S.gv = -speed * HOP; S.gy = 0
  S.sqv = S.sqv + speed * 0.0021
  S.shake = 3
  dust(speed)
  sound("thud_hit")
  log("land v=" .. round(speed))
end

local function step(dt)
  S.t = S.t + dt
  local ph = S.phase
  if S.open then S.beamT = S.beamT + dt end

  if ph == "idle" then
    local on = (S.holding or S.auto) and S.chest_ready
    if on ~= S.notes_on then S.notes_on = on; hold_sound(on) end
    if on then S.level = math.min(1, S.level + dt / HOLD_S)
    else S.level = math.max(0, S.level - DECAY * dt) end
    if S.level >= 1 then
      go("untie"); S.chSqv = S.chSqv + 1.2
      -- The hold notes would run past the unlock: the one stop of the open.
      if S.playing and S.playing:sub(1, 5) == "hold_" then hush() end
      S.snd_pend = nil
      sound("unlock")
      log("open by=" .. (S.auto and "auto" or "hold") .. " hold_skip=" .. S.hold_skip)
      local sent = tel.event("reward.open", {
        item = S.slug, piece = S.n, auto_open = S.auto,
        dur_ms = Timer.millis() - (S.reveal_ms or S.t0), hold_skip = S.hold_skip, late = S.late,
      })
      log("tel ev=reward.open sent=" .. tostring(sent))
    end

  elseif ph == "untie" then
    local p = clamp(S.t / UNTIE_S, 0, 1)
    S.khoaY = S.ch.drop * in2(p); S.khoaA = 1 - steps(p, 4)
    if S.t > OPEN_AT then
      S.open = true; S.chSqv = S.chSqv - 2.2
      go("open")
    end

  elseif ph == "open" then
    S.khoaA = 0
    -- The gift waits for its art; the light keeps glowing meanwhile.
    if S.t > 0.35 and S.ready then
      go("rise")
      sound("sparkle")
    end

  elseif ph == "rise" then
    local p = clamp(S.t / RISE_S, 0, 1)
    local e = back(p)
    S.px = MOUTH_X + (RISE_X - MOUTH_X) * e
    S.py = S.mouth_y + ((S.ch.rise_y or RISE_Y) - S.mouth_y) * e
    S.pA = steps(out3(clamp(p / RISE_FADE, 0, 1)), 3)
    S.chA = 1
    for _, d in ipairs(DIM) do if S.t >= d[1] then S.chA = d[2] end end
    if S.ch.over and p >= S.ch.over and not S.inner_over then
      -- Over the rim: only the gift and its halo change layer.
      S.inner_over = true
      front(R.halo_in); front(R.inner)
      for _, q in ipairs(R.spark) do front(q.o) end
    end
    S.sparkT = S.sparkT + dt
    if S.sparkT > SPARK_EVERY_RISE then S.sparkT = 0; sparkle(S.px, S.py, 40 + 30 * p) end
    if S.t > RISE_END then go("move") end

  elseif ph == "move" then
    local p = clamp(S.t / MOVE_S, 0, 1)
    local e = io3(p)
    if not S.m0x then
      S.m0x, S.m0y = S.px, S.py
      sound("woosh")   -- cut to end before the landing thud
    end
    local g = S.geo[S.n]
    S.px = S.m0x + (g.cx - S.m0x) * e
    S.py = S.m0y + (g.cy + S.hover - S.m0y) * e
    -- The chest goes and the backpack comes, in three steps, as the gift leaves.
    local h = steps(S.t / HIDE_S, 3)
    S.chA = DIM_TO * (1 - h); S.stackA = h
    if p >= 1 then
      S.fy = S.hover; S.fv = FALL_V0; S.has_stack = S.n > 1
      go("fall")
    end

  elseif ph == "fall" then
    S.fv = S.fv + G * dt; S.fy = S.fy + S.fv * dt
    if S.fy >= 0 then S.fy = 0; impact(S.fv) end

  elseif ph == "hop" or ph == "settle" then
    S.gv = S.gv + G * dt; S.gy = S.gy + S.gv * dt
    if S.gy >= 0 and S.gv > 0 then
      S.gy = 0
      if S.gv > 110 then
        sound_if_quiet("thud_hop")
        S.sqv = S.sqv + S.gv * 0.0016
        S.gv = -S.gv * REST
        if S.gv > -140 then S.shake = math.max(S.shake, 1) end
      else
        S.gv = 0
        if ph == "hop" then go("settle") end
      end
    end
    if S.phase == "settle" and S.gv == 0 and math.abs(S.sq) < 0.004 and S.t > 0.15 then
      go(S.complete and "final" or "done")
      S.done_ms = Timer.millis()
      sound("fanfare"); S.fanfare_on = true   -- every piece, not only 6/6; queues behind a thud
      log("settled phase=" .. S.phase)
    end

  elseif ph == "final" then
    S.finalT = S.finalT + dt
    S.zoom = steps(S.finalT / FINAL_SWAP_S, 3)   -- pieces -> uncut picture
    S.glow = S.finalT < GLOW_IN_S and steps(S.finalT / GLOW_IN_S, 4)
             or ((math.floor(S.finalT / GLOW_PULSE_S) % 2 == 0) and 1 or 0.88)
    S.sparkT = S.sparkT + dt
    if S.sparkT > SPARK_EVERY_FINAL then
      S.sparkT = 0; sparkle(240, 150, 90 + math.random() * 70)
    end
  end

  -- Springs: chest bounce, and the backpack squash. The squash is not drawn
  -- (pieces cannot scale); it still times the settle as in the demo.
  S.sqv = S.sqv + (-K * S.sq - C * S.sqv) * dt
  S.sq = clamp(S.sq + S.sqv * dt, -0.1, 0.16)
  S.chSqv = S.chSqv + (-380 * S.chSq - 16 * S.chSqv) * dt
  S.chSq = S.chSq + S.chSqv * dt
  S.shake = math.max(0, S.shake - dt * 12)
  -- Accumulated phase: the lock swings faster while held without jumping.
  S.sway_ph = S.sway_ph + dt * (2 * math.pi / 2.2) * (1 + S.level * 2.5)
  step_particles(dt)
end

-- ---------------------------------------------------------------- render

-- A chest layer, offset the way the demo's jitter (a turn about the chest's
-- foot) and squash would move its centre.
local function chest_layer(o, x, y, h, T, extra_y, alpha)
  if not o then return end
  local cy = y + h / 2
  pos(o, x + T.jr * (T.foot - cy), y + (cy - T.foot) * (T.sy - 1) + extra_y)
  opa(o, alpha)
end

local function render_chest()
  local ch = S.ch
  if not (ch and S.chest_ready) then return end
  local L, idle = S.level, S.phase == "idle"
  local jit = (idle and L > 0) and (math.random() - 0.5) * 5 * L * L or 0
  local T = { jr = math.rad(jit), sy = 1 - S.chSq * 0.12, foot = ch.dong.y + ch.dong.h }
  local chA = S.chA
  local d, m, f = ch.dong, ch.mo, ch.front

  chest_layer(R.dong, d.x, d.y, d.h, T, 0, S.open and 0 or chA)
  chest_layer(R.mo, m.x, m.y, m.h, T, 0, S.open and chA or 0)
  chest_layer(R.front, f.x, f.y, f.h, T, 0, S.open and chA or 0)
  local beam = steps(S.beamT / BEAM_S, 3)
  chest_layer(R.beam, ch.beam.x, ch.beam.y, LAY.BEAM.h, T, 0, beam * chA)
  chest_layer(R.mouth, ch.mouth.x, ch.mouth.y, 70, T, 0, beam * 0.85 * chA)

  -- The lock swings sideways about where it hangs; the swing fades as it drops.
  local k = ch.khoa
  if R.khoa then
    local sway = math.sin(S.sway_ph) * (3 + L * 6) * ch.sway * (1 - S.khoaY / ch.drop)
    local dx = math.rad(sway) * ch.arm
    chest_layer(R.khoa, k.x + dx, k.y, k.h, T, S.khoaY, chA * S.khoaA)
  end
end

local function render_hold()
  local idle = S.phase == "idle" and S.chest_ready
  show(R.cta, idle)
  show(R.track, idle)
  local n = #LAY.HOLD_SEG_RGB565
  local lit = idle and round(S.level * n) or 0
  for i = 1, n do show(R.seg[i], i <= lit) end
end

local function render_pieces(ox, oy)
  if not S.ready then return end
  local ph, n = S.phase, S.n
  local landed = ph == "hop" or ph == "settle" or ph == "done" or ph == "final"
  local stackA = (ph == "move") and S.stackA or ((S.has_stack or landed) and 1 or 0)

  -- The backpack (pieces 1..n-1, plus n once landed) on its foot; at 6/6 it
  -- cross-fades into the uncut picture at WHOLE_K size.
  local z = S.zoom
  local joined = landed and n or (n - 1)
  for i = 1, joined do
    local g = S.geo[i]
    place(R.pieces[i], g.cx + ox, g.cy + S.gy + oy)
    opa(R.pieces[i], stackA * (1 - z))
  end
  if R.closed then
    local c = S.closed_def
    pos(R.closed, 240 - c.box_w / 2 + c.off_x + ox,
        FLOOR - c.box_h + (GEO.WHOLE_K - 1) * -40 + S.gy + c.off_y + oy)
    opa(R.closed, z)
  end

  -- The travelling piece: the in-chest copy while it rises, then the top copy.
  -- It keeps full opacity while the chest dims; the halo follows it.
  local top, hi, ht = R.pieces[n], R.halo_in, R.halo_top
  show(R.inner, ph == "rise")
  show(hi, ph == "rise")
  show(ht, ph == "move")
  if ph == "rise" then
    place(R.inner, S.px, S.py); opa(R.inner, S.pA)
    place(hi, S.px, S.py); opa(hi, S.pA)
    show(top, false)
  elseif ph == "move" then
    place(top, S.px + ox, S.py + oy); opa(top, 1)
    place(ht, S.px + ox, S.py + oy); opa(ht, 1)
  elseif ph == "fall" then
    local g = S.geo[n]
    place(top, g.cx + ox, g.cy + S.fy + oy); opa(top, 1)
  elseif not landed then
    show(top, false)
  end

  -- Contact shadow, from the fall on: fades with height, in four steps.
  local h
  if ph == "fall" then h = S.has_stack and 0 or -S.fy
  elseif landed then h = -S.gy end
  if h and R.shadow then
    local k = math.max(0.25, 1 - h / 160)
    pos(R.shadow, LAY.SHADOW.x + ox, LAY.SHADOW.y + oy)
    opa(R.shadow, steps(0.35 + 0.65 * k, 4))
  else
    show(R.shadow, false)
  end
end

local function render_glow()
  if R.glow then
    pos(R.glow, LAY.GLOW.x, LAY.GLOW.y)
    opa(R.glow, S.glow)
  end
end

-- Fixed-size particles; opacity in quarters.
local function render_particles(ox, oy)
  for _, q in ipairs(R.dust) do
    if q.live then
      pos(q.o, q.x - LAY.DUST / 2 + ox, q.y - LAY.DUST / 2 + oy)
      opa(q.o, steps((1 - q.life / q.max) * 0.8, 4))
    else
      show(q.o, false)
    end
  end
  for _, q in ipairs(R.spark) do
    if q.live then
      place(q.o, q.x + ox, q.y + oy)
      opa(q.o, steps(math.sin(q.life / q.max * math.pi), 4))
    else
      show(q.o, false)
    end
  end
end

local function render()
  local ox, oy = 0, 0
  if S.shake > 0.01 then
    ox = (math.random() - 0.5) * S.shake * 2
    oy = (math.random() - 0.5) * S.shake * 2
  end
  render_glow()
  render_chest()
  render_hold()
  render_pieces(ox, oy)
  render_particles(ox, oy)
end

-- ---------------------------------------------------------------- frame data

local function find_final_reward(data)
  if type(data.checkpoints) ~= "table" then return nil end
  for _, cp in ipairs(data.checkpoints) do
    if type(cp) == "table" and cp.category == "FINAL_REWARD"
       and type(cp.final_reward) == "table" then
      return cp.final_reward
    end
  end
  return nil
end

-- A missing or null url is normal (TTS not ready yet): play without it.
local function install_narration(data)
  if S.narr_ready then return end
  local meta = data.theme_meta
  local audio = type(meta) == "table" and meta.audio or nil
  if type(audio) == "table" then
    for _, list in ipairs({ audio.dynamic, audio.static }) do
      for _, item in ipairs(type(list) == "table" and list or {}) do
        if type(item) == "table" and item.name == NARR then
          if type(item.url) ~= "string" or item.url == "" then
            log("narr result=no_url")
          elseif Speaker.set_url(NARR, item.url) then
            S.narr_ready = true
          else
            log("narr result=set_url_fail")
          end
          return
        end
      end
    end
  end
  log("narr result=not_offered")
end

-- The frame fields the scene uses. owned is kept within the 6-piece set;
-- pieces_total is only logged (a set is always 6 pieces).
local function read_frame(data)
  local F = { theme_id = data.theme_id }
  local fr = find_final_reward(data)
  if type(fr) == "table" then
    F.equipped, F.reward_type, F.reward_item =
        fr.equipped_item_id, fr.reward_type, fr.reward_item_id
    local owned, total = tonumber(fr.pieces_owned), tonumber(fr.pieces_total)
    if owned and total and total > 0 and owned >= 0 then
      F.total = math.floor(total)
      F.owned = math.min(math.floor(owned), GEO.PIECES)
      if F.total ~= GEO.PIECES then log("fallback what=total value=" .. F.total) end
    else
      F.reason = "bad_count"
      log("frame result=default reason=bad_count owned=" .. tostring(fr.pieces_owned) ..
          " total=" .. tostring(fr.pieces_total))
    end
  else
    F.reason = "no_final_reward"
    log("frame result=default reason=no_final_reward")
  end
  return F
end

-- Journey frame. The first one picks the chest and backpack; a later one
-- (refetch, or after the FRAME_WAIT_MS fallback) swaps them while the star is
-- untouched (late_frame), and can always still bring the cp-4 url.
function on_pack_cmd(cmd)
  if type(cmd) ~= "table" or cmd.op ~= "journey" then return end
  local data = type(cmd.args) == "table" and cmd.args.data or nil
  if type(data) ~= "table" then
    log("frame result=ignored reason=no_data")
    return
  end
  install_narration(data)
  local F = read_frame(data)
  if S.set_queued then
    late_frame(F)
    return
  end
  S.theme_id, S.equipped, S.reward_type, S.reward_item = F.theme_id, F.equipped,
      F.reward_type, F.reward_item
  S.owned, S.total = F.owned, F.total
  S.frame_result = F.reason or "ok"
  queue_set()
  log("frame result=ok theme=" .. tostring(S.theme_id) .. " equipped=" ..
      tostring(S.equipped) .. " owned=" .. tostring(S.owned) .. " total=" ..
      tostring(S.total) .. " narr=" .. tostring(S.narr_ready) .. " bag=" .. S.slug ..
      " bag_src=" .. S.bag_src .. " reward_item=" .. tostring(S.reward_item))
end

-- ---------------------------------------------------------------- ending

-- The fanfare is still playing (its end event, or FANFARE_CAP_MS if none comes).
local function fanfare_busy(now)
  if S.fanfare_on and now - S.done_ms >= FANFARE_CAP_MS then
    log("fanfare result=no_end_event")
    S.fanfare_on = false
  end
  return S.fanfare_on
end

-- cp-4 whose end event never comes counts as over NARR_CAP_MS after it began.
local function narr_capped(now)
  if S.narr_state == "playing" and now - S.narr_t0 >= NARR_CAP_MS then
    log("narr result=capped")
    S.narr_state = "over"
  end
end

-- done: fanfare, then cp-4; hold DONE_HOLD_MS, longer while they play.
local function done_over(now)
  if fanfare_busy(now) then return false end
  start_narration(now)
  try_narration(now)
  narr_capped(now)
  return now - S.done_ms >= DONE_HOLD_MS and S.narr_state == "over"
end

-- final: fanfare, then cp-4, then the demo's ambient twinkle until FINAL_TAIL_MS
-- after both are over.
local function final_over(now)
  if fanfare_busy(now) then return false end
  start_narration(now)
  try_narration(now)
  narr_capped(now)
  if S.narr_state ~= "over" then return false end
  S.quiet_ms = S.quiet_ms or now
  if now >= (S.twinkle_ms or 0) then
    sound_if_quiet(TWINKLES[math.random(1, #TWINKLES)])
    S.twinkle_ms = now + TWINKLE_MIN_MS + math.random() * TWINKLE_SPAN_MS
  end
  return now - S.quiet_ms >= FINAL_TAIL_MS
end

-- ---------------------------------------------------------------- hooks

function game_start(params)
  local now = Timer.millis()
  -- The prompt and Pika's lines follow the robot's language (absent = vi, as
  -- firmware defaults); any other language gets en.
  local lang = type(params) == "table" and params.language or "vi"
  local vi = lang == nil or lang == "vi"
  local cta = LAY.CTA[lang] or LAY.CTA.en
  S = {
    phase = "idle", t = 0, t0 = now, last_ms = now,
    level = 0, best = 0, idle_ms = now, holding = false, auto = false, notes_on = false,
    hold_skip = 0, sfx_skip = 0, stops = 0, voice_cut = false,
    pressed = false, voice = "off", voice_t0 = 0, gap_t0 = 0,
    voices = vi and { "voice_1", "voice_2" } or { "en_voice_1", "en_voice_2" },
    open = false, beamT = 0, chA = 1, chSq = 0, chSqv = 0,
    khoaY = 0, khoaA = 1, sway_ph = 0,
    mouth_y = 232, px = MOUTH_X, py = 232, pA = 0, stackA = 0,
    gy = 0, gv = 0, sq = 0, sqv = 0, shake = 0, zoom = 0, glow = 0,
    finalT = 0, sparkT = 0, has_stack = false,
    frame_result = nil, late = false, reveal_ms = nil,   -- telemetry
  }
  R = { pieces = {}, seg = {}, dust = {}, spark = {}, jobs = {}, job_i = 1, load_failed = 0 }

  -- The journey frame only arrives after start, so the loading animation is
  -- held until reveal() has the chest, lock, prompt and bar up (Engine.show),
  -- as the map packs do. The background is shown now regardless: firmware
  -- without Engine.show, or the engine's 3 s hold limit, would otherwise show
  -- black.
  S.held = Engine.show ~= nil and Engine.show(false)
  local dir = "assets/runtime/"
  R.bg = obj(Sprite.solid(480, 320, LAY.BG_RGB565))
  pos(R.bg, 0, 0); show(R.bg, true)
  R.cta = load_img(dir .. cta.file)
  pos(R.cta, cta.x, cta.y)
  R.track = load_img(dir .. "hold_track.png")
  pos(R.track, LAY.HOLD.x, LAY.HOLD.y)
  local n = #LAY.HOLD_SEG_RGB565
  for i = 1, n do
    local o
    if i == 1 then o = load_img(dir .. "hold_cap_l.png")
    elseif i == n then o = load_img(dir .. "hold_cap_r.png")
    else o = obj(Sprite.solid(LAY.HOLD.seg_w, LAY.HOLD.h, LAY.HOLD_SEG_RGB565[i])) end
    R.seg[i] = o
    pos(o, LAY.HOLD.x + (i - 1) * LAY.HOLD.seg_w, LAY.HOLD.y)
  end

  queue(function () R.shadow = load_img(dir .. "shadow.png") end)
  for i = 1, DUST_N do
    queue(function () R.dust[i] = { o = load_img(dir .. "dust.png") } end)
  end
  for i = 1, SPARK_N do
    local f = (i % 2 == 1) and "spark.png" or "spark_s.png"
    queue(function () R.spark[i] = { o = load_img(dir .. f) } end)
  end
  queue(restack)

  local journey = type(params) == "table" and params.milestone_index ~= nil
  log("start lang=" .. tostring(lang) .. " cta=" .. cta.file .. " journey=" .. tostring(journey) ..
      " voice=" .. S.voices[1] .. " held=" .. tostring(S.held))
  if not journey then
    log("frame result=default reason=no_journey")
    S.frame_result = "no_journey"
    queue_set()
  end
  render()
end

function on_tick(dt_ms)
  if S.phase == "exit" then return end
  local now = Timer.millis()

  pump()
  if S.phase == "exit" then return end
  if not S.set_queued and now - S.t0 >= FRAME_WAIT_MS then
    log("frame result=default reason=timeout ms=" .. FRAME_WAIT_MS)
    S.frame_result = "timeout"
    queue_set()
  end

  -- dt_ms is the engine's fixed period, not the elapsed time.
  local real = now - S.last_ms
  S.last_ms = now
  local dt = clamp((real > 0 and real or (tonumber(dt_ms) or 33)) / 1000, 0, MAX_DT)

  retry_sound(now)

  if S.phase == "idle" then
    S.holding = S.chest_ready and Input.is_down("confirm") or false
    if S.holding and not S.pressed then
      -- The first press cuts Pika and drops the line still to come; the hold
      -- notes queue behind her stop.
      S.pressed = true
      if intro_busy() then log("voice result=cut line=" .. S.voice) end
      if (S.voice == "v1" or S.voice == "v2") and S.playing == S.voices[S.voice == "v1" and 1 or 2] then
        hush()
        S.voice_cut = true
      end
      voice_over(now)
    end
    tick_voice(now)
    -- Only a new high on the bar re-arms the auto-open, so taps that never
    -- gain ground still let the chest open by itself.
    if S.level > S.best + 0.001 then S.best = S.level; S.idle_ms = now end
    if not S.auto and S.chest_ready and not intro_busy() and now - S.idle_ms >= IDLE_OPEN_MS then
      S.auto = true
    end
  end

  local over = false
  if S.phase == "done" then
    -- Nothing moves any more: draw once and stop rendering.
    if not S.parked and not any_particles() and S.shake <= 0.01 then
      render()
      S.parked = true
    end
    over = done_over(now)
  elseif S.phase == "final" then
    over = final_over(now)
  end
  if over then
    finish('{"ev":"balo.opened"}', S.full and S.owned or S.n)
    return
  end
  if S.parked then return end

  local sub = math.max(1, math.ceil(dt / SUB_DT))
  for _ = 1, sub do step(dt / sub) end
  render()
end

function on_sound_end(alias, reason)
  -- STOPPED comes only from hush(), which already let go of it; ignoring it keeps
  -- a replay of the same alias tracked.
  if alias == S.playing and reason ~= Speaker.REASON_STOPPED then S.playing = nil end
  local now = Timer.millis()
  if S.voice == "v1" and alias == S.voices[1] then
    if reason == Speaker.REASON_COMPLETED then
      S.voice, S.gap_t0 = "gap", now
    else
      voice_over(now)
    end
  elseif S.voice == "v2" and alias == S.voices[2] then
    voice_over(now)
  end
  if alias == "fanfare" then
    S.fanfare_on = false
  elseif alias == NARR and S.narr_state == "playing" then
    log("narr result=end reason=" .. tostring(reason))
    S.narr_state = "over"
  end
end

-- The finish ring overflowed: an end we wait on may be among the lost events.
-- Waiting on it would hold the finished scene silent until its cap.
function on_sound_lost(count)
  log("sound result=lost count=" .. tostring(count) .. " narr=" .. tostring(S.narr_state) ..
      " fanfare=" .. tostring(S.fanfare_on) .. " voice=" .. tostring(S.voice))
  S.playing = nil
  S.fanfare_on = false
  if S.narr_state == "playing" then S.narr_state = "over" end
  voice_over(Timer.millis())
end

function game_end()
  kill_chest(R)
  kill_set(R)
  for _, k in ipairs({ "bg", "beam", "mouth", "cta", "track", "shadow" }) do
    kill(R[k])
  end
  for i = 1, #LAY.HOLD_SEG_RGB565 do kill((R.seg or {})[i]) end
  for _, pool in ipairs({ R.dust or {}, R.spark or {} }) do
    for _, q in ipairs(pool) do kill(q.o) end
  end
  Speaker.stop_all()
  R = {}
end
