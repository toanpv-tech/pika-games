-- libs/rules — Word Maze simulation: pure logic, no engine calls
-- Resolve: require("libs/rules")
--
-- Everything here operates on plain numbers and tables so the whole game can be
-- driven headless by libs/testkit (DoD 5). Rendering, audio, LED and servo live in
-- scripts/main.lua; this layer only reports what happened through S.events.
--
-- Scoring, timing, monster pacing, telegraph, key placement and push-back are
-- ports of input/word_maze.html; see libs/config.lua for the constants.

local CFG = require("libs/config")
local Levels = require("libs/levels")
local Curriculum = require("libs/curriculum")
local Maze = require("libs/maze")

local M = {}

local floor, ceil, min, max, abs = math.floor, math.ceil, math.min, math.max, math.abs
local DIRS, OPP = CFG.DIRS, CFG.OPP

-- Scenes. Integer enums, never bare strings on the hot path.
M.SCENE_TITLE = 1
M.SCENE_INTRO = 2
M.SCENE_MAZE  = 3
M.SCENE_GATE  = 4
M.SCENE_CLEAR = 5
M.SCENE_OVER  = 6

-- Events the render/feedback layer reacts to. Emitted into S.events (a fixed
-- array with a count) so the logic never allocates to communicate.
M.EV_STEP     = 1
M.EV_CRUMB    = 2
M.EV_KEY      = 3
M.EV_KILL     = 4
M.EV_GATE     = 5
M.EV_HURT     = 6
M.EV_TIMEOUT  = 7
M.EV_OVER     = 8
M.EV_FIGHT    = 9
M.EV_LOCKED   = 10
M.EV_GROWL    = 11
M.EV_TICK     = 12
M.EV_NO_MATCH = 13
M.EV_MAP_READY = 14

local EV_MAX = 12   -- most events a single step can raise; drops beyond are noise

----------------------------------------------------------------------
-- Seeded xorshift32 RNG (deterministic; seed ~= 0)
----------------------------------------------------------------------
local rng_state = 0x9E3779B9

local function rng_seed(s)
  s = (s or 0) & 0xFFFFFFFF
  if s == 0 then s = 0x9E3779B9 end
  rng_state = s
end

local function rng_u32()
  local x = rng_state
  x = (x ~ (x << 13)) & 0xFFFFFFFF
  x = (x ~ (x >> 17)) & 0xFFFFFFFF
  x = (x ~ (x << 5)) & 0xFFFFFFFF
  rng_state = x
  return x
end

M.rng_seed = rng_seed

----------------------------------------------------------------------
-- State construction. Every pool is sized for the worst map and allocated once.
----------------------------------------------------------------------
function M.new_state()
  local S = {
    scene = M.SCENE_TITLE,
    maze = Maze.new(),

    -- run
    score = 0, level = 1, lives = CFG.MAX_LIVES, streak = 0,
    hiscore = 0, best_crumbs = 0,
    moves = 0, kills = 0, sent_hits = 0, timeouts = 0, crumbs_taken = 0,
    max_level = 0,

    -- map
    cols = 0, rows = 0, topic = 1,
    key_on = false, fog_on = false, chaser_on = false,
    rule_name = "", rule_hint = "",
    crumb = {},          -- [i] = true when a crumb sits on cell i
    key_i = 0,           -- 0 = no key on this map
    has_key = false, door_locked = false,

    -- mouse
    mx = 1, my = 1,
    glide_path = {}, glide_n = 0, glide_seg = 0, glide_k = 0,
    glide_dir = 0, glide_fx = 0, glide_fy = 0, gliding = false,

    -- choices offered at the current cell
    choices = {},        -- [k] = { dir, kind, word, core, mon }
    choice_n = 0,
    choice_rev = 0,      -- bumped by build_choices; view caches keyed on it
    dir_word = {},       -- [dir] = word, stable while standing on a cell
    dir_core = {},
    last_spoken = "",
    cell_attempts = 0,

    -- monsters
    mon = {},            -- fixed pool of CFG.MAX_MONSTERS
    mon_n = 0,
    mon_timer = 0, mon_step_ms = CFG.MON_STEP_BASE,
    fight = 0,           -- index of the monster being fought, 0 = none

    -- gate
    gate_sentence = "", gate_core = "",

    -- timers
    time_left = 0, time_max = 1,
    scene_timer = 0,
    iframe_ms = 0,
    match_lock_ms = 0,
    silence_ms = 0,
    last_tick_s = -1,

    -- voice/input mode
    voice_ok = false,

    -- learner model: exposures/hits/escapes/near per authored word, flat arrays
    learn_exp = {}, learn_hit = {}, learn_esc = {},

    -- outbound events
    events = {}, event_n = 0,
    msg = "", msg_ms = 0, msg_arg = nil,
  }

  for i = 1, CFG.MAX_MONSTERS do
    S.mon[i] = {
      x = 0, y = 0, alive = false, chaser = false, lunge = false,
      word = "", core = "", sentence = "",
      route_x = {}, route_y = {}, route_n = 0, ri = 1, rdir = 1,
    }
  end
  for i = 1, CFG.MAX_CELLS do S.crumb[i] = false end
  for i = 1, CFG.MAX_CHIPS do
    -- tx/ty: the cell this choice leads to. Declared here, with every other
    -- field, so the table keeps one shape and never rehashes on assignment.
    S.choices[i] = { dir = 0, kind = 0, word = "", core = "", mon = 0, tx = 0, ty = 0 }
  end
  for i = 1, CFG.MAX_COLS * CFG.MAX_ROWS do S.glide_path[i] = 0 end
  for i = 1, EV_MAX do S.events[i] = 0 end

  local total = Curriculum.COUNT * 6
  for i = 1, total do
    S.learn_exp[i] = 0
    S.learn_hit[i] = 0
    S.learn_esc[i] = 0
  end
  return S
end

M.CHOICE_WORD = 1
M.CHOICE_MONSTER = 2

local function emit(S, ev)
  local n = S.event_n
  if n >= EV_MAX then return end
  n = n + 1
  S.events[n] = ev
  S.event_n = n
end

function M.clear_events(S) S.event_n = 0 end

-- `key` is an i18n key, never display text: this module stays language-agnostic
-- so it keeps running headless under libs/testkit. `arg` carries the one
-- variable part a message can have (a bonus figure, a word to echo) and is
-- appended by the render layer AFTER the key is resolved -- concatenating here
-- would bake in one language's word order.
local function set_msg(S, key, ms, arg)
  S.msg = key
  S.msg_arg = arg
  S.msg_ms = ms or CFG.MSG_MS
end

----------------------------------------------------------------------
-- Learner model. Slot = (topic_index - 1) * 6 + word_index, so the whole
-- 24 x 6 table is 3 flat arrays and packs into well under State.save's 4096 B.
----------------------------------------------------------------------
local function learn_slot(topic_idx, word_idx)
  return (topic_idx - 1) * 6 + word_idx
end

local function word_index(S, core)
  local cores = Curriculum.CORES[S.topic]
  for j = 1, #cores do
    if cores[j] == core then return j end
  end
  return 0
end

local function learn_mark(S, core, hit)
  local j = word_index(S, core)
  if j == 0 then return end
  local slot = learn_slot(S.topic, j)
  S.learn_exp[slot] = min(255, S.learn_exp[slot] + 1)
  if hit then
    if S.cell_attempts == 0 then
      S.learn_hit[slot] = min(255, S.learn_hit[slot] + 1)
    end
  else
    S.learn_esc[slot] = min(255, S.learn_esc[slot] + 1)
  end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function goal_index(S) return S.cols * S.rows end   -- bottom-right cell

local function is_goal(S, x, y) return x == S.cols and y == S.rows end

function M.combo(S) return min(CFG.COMBO_MAX, 1 + floor(S.streak / CFG.COMBO_EVERY)) end

local function monster_at(S, x, y)
  for i = 1, S.mon_n do
    local m = S.mon[i]
    if m.alive and m.x == x and m.y == y then return i end
  end
  return 0
end

----------------------------------------------------------------------
-- Map setup
----------------------------------------------------------------------
local function scatter_crumbs(S)
  local mz = S.maze
  local goal = goal_index(S)
  for y = 1, S.rows do
    for x = 1, S.cols do
      local i = (y - 1) * S.cols + x
      if i == 1 or i == goal then
        S.crumb[i] = false
      else
        -- Dead ends always carry a crumb to bait exploration (more steps spoken).
        local dead = mz:open_count(x, y) <= 1
        S.crumb[i] = dead or (rng_u32() % 100) < CFG.CRUMB_CHANCE
      end
    end
  end
end

local function place_key(S)
  S.key_i = 0
  S.has_key = false
  S.door_locked = S.key_on
  if not S.key_on then return end
  -- Farthest cell from the start that does NOT require passing through the cage
  -- cell. Without the avoid argument the key can land behind the locked cage and
  -- deadlock the map (GDD 6.2b).
  local dist = S.maze:bfs_dist(1, 1, goal_index(S))
  local best, best_i = -1, 0
  local goal = goal_index(S)
  for i = 2, S.cols * S.rows do
    if i ~= goal and dist[i] > best then
      best = dist[i]
      best_i = i
    end
  end
  if best_i > 0 then
    S.key_i = best_i
    S.crumb[best_i] = false
  end
end

local function make_route(S, mi, x, y, range)
  local m = S.mon[mi]
  m.route_n = 1
  m.route_x[1], m.route_y[1] = x, y
  m.ri, m.rdir = 1, 1
  if range < 1 then return end
  local dirs, n = S.maze:open_dirs(x, y)
  if n == 0 then return end
  local d = dirs[(rng_u32() % n) + 1]
  local cx, cy = x, y
  for _ = 1, range do
    if S.maze:has_wall(cx, cy, d) then break end
    cx = cx + DIRS[d].dx
    cy = cy + DIRS[d].dy
    if is_goal(S, cx, cy) then break end   -- never patrol onto the cage
    m.route_n = m.route_n + 1
    m.route_x[m.route_n], m.route_y[m.route_n] = cx, cy
  end
end

-- Shuffle the topic's 6 word indices in place (Fisher-Yates over a scratch array).
local shuffle_buf = { 1, 2, 3, 4, 5, 6 }

local function shuffled_words()
  for i = 1, 6 do shuffle_buf[i] = i end
  for i = 6, 2, -1 do
    local j = (rng_u32() % i) + 1
    shuffle_buf[i], shuffle_buf[j] = shuffle_buf[j], shuffle_buf[i]
  end
  return shuffle_buf
end

local function place_monsters(S, count, chaser, mrange)
  S.mon_n = 0
  for i = 1, CFG.MAX_MONSTERS do S.mon[i].alive = false end
  local words = Curriculum.TOPICS[S.topic].words
  local order = shuffled_words()
  -- Hard pool guard: levels.cfg already clamps, but the pool is a fixed array and
  -- must never be indexed past its end.
  count = min(count, CFG.MAX_MONSTERS - (chaser and 1 or 0))
  local placed = 0
  local attempts = 0
  while placed < count and attempts < CFG.MON_PLACE_ATTEMPTS do
    attempts = attempts + 1
    local x = (rng_u32() % S.cols) + 1
    local y = (rng_u32() % S.rows) + 1
    -- Keep the spawn area and the cage clear (HTML placeMonsters guard).
    if not ((x <= 2 and y <= 2) or is_goal(S, x, y)) and monster_at(S, x, y) == 0 then
      placed = placed + 1
      S.mon_n = placed
      local m = S.mon[placed]
      local w = words[order[((placed - 1) % 6) + 1]]
      m.x, m.y = x, y
      m.alive = true
      m.chaser = false
      m.lunge = false
      m.word = w
      m.sentence, m.core = Curriculum.sentence(S.topic, w)
      make_route(S, placed, x, y, mrange)
    end
  end

  if chaser and S.mon_n < CFG.MAX_MONSTERS then
    -- Chaser starts as far from the spawn as the maze allows.
    local dist = S.maze:bfs_dist(1, 1)
    local best, bi = -1, 0
    local goal = goal_index(S)
    for i = 1, S.cols * S.rows do
      local x = ((i - 1) % S.cols) + 1
      local y = ((i - 1) // S.cols) + 1
      if not ((x <= 2 and y <= 2) or i == goal) and monster_at(S, x, y) == 0
         and dist[i] > best then
        best = dist[i]
        bi = i
      end
    end
    if bi > 0 then
      S.mon_n = S.mon_n + 1
      local m = S.mon[S.mon_n]
      local w = words[order[((S.mon_n - 1) % 6) + 1]]
      m.x = ((bi - 1) % S.cols) + 1
      m.y = ((bi - 1) // S.cols) + 1
      m.alive = true
      m.chaser = true
      m.lunge = false
      m.word = w
      m.sentence, m.core = Curriculum.sentence(S.topic, w)
      m.route_n = 1
      m.route_x[1], m.route_y[1] = m.x, m.y
      m.ri, m.rdir = 1, 1
    end
  end
end

-- Build the word/monster choices for the cell the mouse stands on.
-- `fresh` restarts the retry counter (a new cell), matching HTML buildChoices().
-- Snapshot of the open directions. maze:open_dirs returns a shared buffer that
-- the monster_at scans below would otherwise clobber, so copy it once into a
-- module-level array (4 entries, allocated at load, never regrown).
local dir_copy = { 0, 0, 0, 0 }

function M.build_choices(S, fresh)
  if fresh then S.cell_attempts = 0 end
  local dirs, dn = S.maze:open_dirs(S.mx, S.my)
  for k = 1, dn do dir_copy[k] = dirs[k] end

  local words = Curriculum.TOPICS[S.topic].words
  local cores = Curriculum.CORES[S.topic]
  local order = shuffled_words()

  local ci = 0
  local ai = 0
  for k = 1, dn do
    local d = dir_copy[k]
    local nx, ny = S.mx + DIRS[d].dx, S.my + DIRS[d].dy
    local mi = monster_at(S, nx, ny)
    ci = ci + 1
    if ci > CFG.MAX_CHIPS then break end
    local c = S.choices[ci]
    c.dir = d
    -- The cell the choice points at, for the renderer to label. Same value for
    -- both kinds: a monster choice targets the adjacent cell the monster stands
    -- on, a travel choice the adjacent cell the mouse would enter.
    c.tx, c.ty = nx, ny
    if mi > 0 then
      c.kind = M.CHOICE_MONSTER
      c.mon = mi
      c.word = ""
      c.core = S.mon[mi].core
    else
      -- Keep the sign stable while standing here, but never reuse the word just
      -- spoken (HTML fix 2 of 3 for the double-move bug) or a word that clashes
      -- with an adjacent monster's sentence target.
      local w = S.dir_word[d]
      local wc = S.dir_core[d]
      if not w or wc == S.last_spoken then
        w, wc = nil, nil
        for _ = 1, 6 do        -- bounded: at most one pass over the topic's words
          ai = ai + 1
          local idx = order[((ai - 1) % 6) + 1]
          local cand, cand_core = words[idx], cores[idx]
          local clash = (cand_core == S.last_spoken)
          if not clash then
            for j = 1, dn do
              local jd = dir_copy[j]
              local jmi = monster_at(S, S.mx + DIRS[jd].dx, S.my + DIRS[jd].dy)
              if jmi > 0 and S.mon[jmi].core == cand_core then
                clash = true
                break
              end
            end
          end
          if not clash then
            w, wc = cand, cand_core
            break
          end
        end
        if not w then
          w, wc = words[1], cores[1]
        end
        S.dir_word[d], S.dir_core[d] = w, wc
      end
      c.kind = M.CHOICE_WORD
      c.mon = 0
      c.word = w
      c.core = wc
    end
  end
  S.choice_n = ci
  -- Bumped on every rebuild so the view layer can cache the derived chip strings
  -- and still notice a change made deep inside step() (a monster moving next to
  -- the mouse flips a word chip to FIGHT without any scene change or input).
  S.choice_rev = S.choice_rev + 1
  -- Only a genuinely new target restarts the silence timer. Monster beats rebuild
  -- the choices several times a second; resetting here would stop the re-prompt
  -- from ever firing.
  if fresh then S.silence_ms = 0 end
end

function M.setup_level(S, fresh)
  local cfg = Levels.cfg(S.level)
  S.cols, S.rows = cfg.cols, cfg.rows
  S.key_on, S.fog_on, S.chaser_on = cfg.key, cfg.fog, cfg.chaser
  S.rule_name = Levels.rule_name(cfg)
  S.rule_hint = Levels.rule_hint(cfg)
  S.topic = Curriculum.topic_index(S.level)

  S.maze:generate(cfg.cols, cfg.rows, cfg.braid, rng_u32)
  scatter_crumbs(S)
  place_key(S)
  place_monsters(S, cfg.monsters, cfg.chaser, cfg.mrange)

  S.mx, S.my = 1, 1
  S.gliding = false
  S.glide_n, S.glide_seg, S.glide_k = 0, 0, 0
  S.fight = 0
  S.gate_sentence, S.gate_core = "", ""
  S.last_spoken = ""
  S.cell_attempts = 0
  for d = 1, 4 do
    S.dir_word[d] = nil
    S.dir_core[d] = nil
  end

  S.mon_step_ms = max(CFG.MON_STEP_MIN, CFG.MON_STEP_BASE - (S.level - 1) * CFG.MON_STEP_DEC)
  S.mon_timer = 0
  S.iframe_ms = 0
  S.last_tick_s = -1
  S.time_max = floor(CFG.TIME_BASE + cfg.cols * cfg.rows * cfg.time_k + 0.5)
  S.time_left = S.time_max
  if fresh then S.max_level = max(S.max_level, S.level) end

  S.scene = M.SCENE_INTRO
  S.scene_timer = CFG.INTRO_MS
  M.build_choices(S, false)
  emit(S, M.EV_MAP_READY)
end

function M.start_run(S)
  S.score = 0
  S.level = 1
  S.lives = CFG.MAX_LIVES
  S.streak = 0
  S.moves, S.kills, S.sent_hits, S.timeouts, S.crumbs_taken = 0, 0, 0, 0, 0
  S.max_level = 0
  -- Replay reuses this same S -- new_state() only runs once per VM, in
  -- game_start -- so the HUD's dedup cache has to be invalidated by hand. A run
  -- that ended on level 1 with score 0 restarts to identical values, the cache
  -- reports "nothing changed", and the icon restore inside render_hud never
  -- runs: the hearts and crumb hidden by the GAME OVER screen stay hidden.
  S.hud_secs, S.hud_score, S.hud_lives = nil, nil, nil
  S.hud_level, S.hud_has_key, S.hud_mult = nil, nil, nil
  M.setup_level(S, true)
end

----------------------------------------------------------------------
-- Pickups and movement
----------------------------------------------------------------------
local function collect_at(S, x, y)
  local i = (y - 1) * S.cols + x
  if S.crumb[i] then
    S.crumb[i] = false
    S.crumbs_taken = S.crumbs_taken + 1
    S.score = S.score + CFG.PTS_CRUMB * M.combo(S)
    S.last_pick_i = i
    emit(S, M.EV_CRUMB)
  end
  if S.key_i == i then
    S.key_i = 0
    S.has_key = true
    S.door_locked = false
    set_msg(S, "msg_key", 1000)
    emit(S, M.EV_KEY)
  end
end

-- Begin a glide along `dir`: run down a straight corridor, stopping at a junction,
-- before a monster, or on the cage cell (HTML startMove()).
function M.start_move(S, ci)
  local c = S.choices[ci]
  local d = c.dir
  local mz = S.maze
  S.moves = S.moves + 1
  S.streak = S.streak + 1
  S.score = S.score + CFG.PTS_STEP * S.level * M.combo(S)
  learn_mark(S, c.core, true)

  local n = 0
  local x, y = S.mx, S.my
  while true do
    if mz:has_wall(x, y, d) then break end
    local nx, ny = x + DIRS[d].dx, y + DIRS[d].dy
    if monster_at(S, nx, ny) > 0 then break end
    x, y = nx, ny
    n = n + 1
    S.glide_path[n] = (y - 1) * S.cols + x
    if is_goal(S, x, y) then break end
    -- Stop where the corridor branches sideways.
    local dirs, dn = mz:open_dirs(x, y)
    local perp = false
    for k = 1, dn do
      local od = dirs[k]
      if od ~= d and od ~= OPP[d] then
        perp = true
        break
      end
    end
    if perp then break end
    if monster_at(S, x + DIRS[d].dx, y + DIRS[d].dy) > 0 then break end
  end

  if n == 0 then
    M.build_choices(S, false)
    return false
  end

  for dd = 1, 4 do
    S.dir_word[dd] = nil
    S.dir_core[dd] = nil
  end
  S.glide_n = n
  S.glide_seg = 1
  S.glide_k = 0
  S.glide_dir = d
  S.glide_fx, S.glide_fy = S.mx, S.my
  S.gliding = true
  S.choice_n = 0
  S.choice_rev = S.choice_rev + 1
  emit(S, M.EV_STEP)
  return true
end

local function arrive(S)
  local last = S.glide_path[S.glide_n]
  local arrive_dir = S.glide_dir
  S.mx = ((last - 1) % S.cols) + 1
  S.my = ((last - 1) // S.cols) + 1
  S.gliding = false
  S.glide_n = 0

  if is_goal(S, S.mx, S.my) then
    if S.door_locked then
      set_msg(S, "msg_locked", 1200)
      -- Step back the way we came, not the first open direction: an unexpected
      -- sideways shove confuses young players (GDD 6.2b UX fix).
      S.mx = S.mx - DIRS[arrive_dir].dx
      S.my = S.my - DIRS[arrive_dir].dy
      emit(S, M.EV_LOCKED)
      M.build_choices(S, true)
      return
    end
    local words = Curriculum.TOPICS[S.topic].words
    local order = shuffled_words()
    local w = words[order[1]]
    S.gate_sentence, S.gate_core = Curriculum.sentence(S.topic, w)
    S.scene = M.SCENE_GATE
    S.silence_ms = 0
    -- The lock exists to swallow a stale repeat of the word just spoken; a new
    -- target in a new scene cannot be that echo, so do not make the child wait.
    S.match_lock_ms = 0
    set_msg(S, S.key_on and "msg_open_door" or "msg_open_cage", 1100)
    return
  end

  M.build_choices(S, true)
  for k = 1, S.choice_n do
    if S.choices[k].kind == M.CHOICE_MONSTER then
      emit(S, M.EV_GROWL)
      break
    end
  end
end

----------------------------------------------------------------------
-- Monsters
----------------------------------------------------------------------
local function push_back(S)
  -- Retreat to the adjacent cell furthest from the nearest live monster.
  local threat, td = 0, 1e9
  for i = 1, S.mon_n do
    local m = S.mon[i]
    if m.alive then
      local d = abs(m.x - S.mx) + abs(m.y - S.my)
      if d < td then
        td = d
        threat = i
      end
    end
  end
  if threat == 0 then return end
  local tm = S.mon[threat]
  local dirs, n = S.maze:open_dirs(S.mx, S.my)
  local best, bx, by = -1, 0, 0
  for k = 1, n do
    local d = dirs[k]
    local nx, ny = S.mx + DIRS[d].dx, S.my + DIRS[d].dy
    -- Never shove onto the cage: arrival is only ever detected at the end of a
    -- glide (arrive()), so a push that lands here would leave the mouse standing
    -- on the cheese in SCENE_MAZE with the gate never opening. Same exclusion
    -- make_route/place_monsters already apply to keep actors off the goal.
    if monster_at(S, nx, ny) == 0 and not is_goal(S, nx, ny) then
      local score = abs(nx - tm.x) + abs(ny - tm.y)
      if score > best then
        best = score
        bx, by = nx, ny
      end
    end
  end
  if best >= 0 then S.mx, S.my = bx, by end
end

local function hit_by_monster(S)
  if S.iframe_ms > 0 then return end
  S.lives = S.lives - 1
  S.timeouts = S.timeouts + 1
  S.iframe_ms = CFG.IFRAME_MS
  S.streak = 0
  S.fight = 0
  set_msg(S, "msg_hurt", 1100)
  emit(S, M.EV_HURT)
  push_back(S)
  if S.lives <= 0 then
    S.scene = M.SCENE_OVER
    emit(S, M.EV_OVER)
  else
    for d = 1, 4 do
      S.dir_word[d] = nil
      S.dir_core[d] = nil
    end
    M.build_choices(S, true)
  end
end

local function step_monsters(S)
  for i = 1, S.mon_n do
    local m = S.mon[i]
    if m.alive then
      if m.chaser then
        -- Do not pile on right after a hit (HTML checks invincibleUntil).
        if S.iframe_ms <= 0 then
          local nx, ny = S.maze:next_step(m.x, m.y, S.mx, S.my)
          if nx and nx == S.mx and ny == S.my and not S.gliding then
            -- One growl beat before the pounce, always.
            if not m.lunge then
              m.lunge = true
            else
              m.x, m.y = nx, ny
              m.lunge = false
              hit_by_monster(S)
              return
            end
          else
            m.lunge = false
            if nx and monster_at(S, nx, ny) == 0 then m.x, m.y = nx, ny end
          end
        end
      elseif m.route_n >= 2 then
        local ni = m.ri + m.rdir
        if ni < 1 or ni > m.route_n then
          m.rdir = -m.rdir
          ni = m.ri + m.rdir
        end
        local cx, cy = m.route_x[ni], m.route_y[ni]
        if monster_at(S, cx, cy) == 0 then
          if cx == S.mx and cy == S.my and not S.gliding then
            if not m.lunge then
              m.lunge = true
            else
              m.x, m.y, m.ri = cx, cy, ni
              m.lunge = false
              hit_by_monster(S)
              return
            end
          else
            m.lunge = false
            m.x, m.y, m.ri = cx, cy, ni
          end
        end
      end
    end
  end
  if S.scene == M.SCENE_MAZE and not S.gliding then M.build_choices(S, false) end
end

local function kill_monster(S, mi)
  local m = S.mon[mi]
  m.alive = false
  m.lunge = false
  S.kills = S.kills + 1
  S.streak = S.streak + 1
  S.score = S.score + CFG.PTS_KILL * S.level * M.combo(S)
  S.kill_x, S.kill_y = m.x, m.y
  learn_mark(S, m.core, true)
  emit(S, M.EV_KILL)
  M.build_choices(S, false)
end

local function open_gate(S)
  S.sent_hits = S.sent_hits + 1
  S.streak = S.streak + 1
  local bonus = (CFG.PTS_GATE * S.level + ceil(S.time_left) * CFG.PTS_GATE_TIME)
                * M.combo(S)
  S.score = S.score + bonus
  learn_mark(S, S.gate_core, true)
  S.gate_sentence, S.gate_core = "", ""
  S.scene = M.SCENE_CLEAR
  S.scene_timer = CFG.CLEAR_MS
  set_msg(S, "msg_cheese", CFG.CLEAR_MS, bonus)
  emit(S, M.EV_GATE)
end

local function timeout(S)
  S.timeouts = S.timeouts + 1
  S.lives = S.lives - 1
  S.streak = 0
  if S.gate_core ~= "" then
    learn_mark(S, S.gate_core, false)
  end
  emit(S, M.EV_TIMEOUT)
  if S.lives <= 0 then
    S.scene = M.SCENE_OVER
    emit(S, M.EV_OVER)
  else
    M.setup_level(S, false)
  end
end

----------------------------------------------------------------------
-- Voice / input resolution
----------------------------------------------------------------------
-- Try to consume `keyword` as a command. Returns true when it matched something.
function M.submit(S, keyword)
  if keyword == "" then return false end
  if S.match_lock_ms > 0 then return false end

  if S.scene == M.SCENE_GATE then
    if keyword == Curriculum.clean(S.gate_sentence) then
      S.match_lock_ms = CFG.MATCH_LOCK_MS
      open_gate(S)
      return true
    end
    return false
  end

  if S.scene ~= M.SCENE_MAZE or S.gliding then return false end

  if S.fight > 0 then
    local m = S.mon[S.fight]
    if keyword == Curriculum.clean(m.sentence) then
      S.match_lock_ms = CFG.MATCH_LOCK_MS
      local mi = S.fight
      S.fight = 0
      kill_monster(S, mi)
      return true
    end
    -- Escaping a fight by naming another direction is allowed.
    for k = 1, S.choice_n do
      local c = S.choices[k]
      if c.kind == M.CHOICE_WORD and c.core == keyword then
        S.match_lock_ms = CFG.MATCH_LOCK_MS
        S.last_spoken = c.core
        S.fight = 0
        M.start_move(S, k)
        return true
      end
    end
    return false
  end

  -- "fight" enters a battle with an adjacent monster.
  if keyword == CFG.FIGHT_KEYWORD then
    for k = 1, S.choice_n do
      local c = S.choices[k]
      if c.kind == M.CHOICE_MONSTER then
        -- Entering a fight switches the target from a word to a sentence, so a
        -- stale echo cannot match it; do not stall the child behind the lock.
        S.match_lock_ms = 0
        S.fight = c.mon
        S.silence_ms = 0
        set_msg(S, "msg_say_sentence", 900)
        emit(S, M.EV_FIGHT)
        return true
      end
    end
    return false
  end

  for k = 1, S.choice_n do
    local c = S.choices[k]
    if c.kind == M.CHOICE_WORD and c.core == keyword then
      S.match_lock_ms = CFG.MATCH_LOCK_MS
      S.last_spoken = c.core
      M.start_move(S, k)
      return true
    end
  end

  -- Heard something, matched nothing: count the retry so the learner model can
  -- tell a first-try hit from a recovered one.
  S.cell_attempts = S.cell_attempts + 1
  return false
end

-- M.submit() above is the ONLY way to act on the maze. The button paths that
-- used to live here (M.choose for picking a chip, M.gate_bypass for opening the
-- cage without speaking) were removed with the button controls: every target,
-- word and sentence alike, is now resolved by voice only.
--
----------------------------------------------------------------------
-- Fixed-step simulation
----------------------------------------------------------------------
function M.step(S, dt_ms)
  if S.match_lock_ms > 0 then S.match_lock_ms = max(0, S.match_lock_ms - dt_ms) end
  if S.iframe_ms > 0 then S.iframe_ms = max(0, S.iframe_ms - dt_ms) end
  if S.msg_ms > 0 then
    S.msg_ms = S.msg_ms - dt_ms
    if S.msg_ms <= 0 then
      S.msg = ""
      S.msg_ms = 0
      -- Cleared with the key, not left behind: the render layer only reads
      -- msg_arg while msg is set, but a stale arg would silently attach itself
      -- to the next message that happens to take none.
      S.msg_arg = nil
    end
  end

  local scene = S.scene

  if scene == M.SCENE_INTRO then
    S.scene_timer = S.scene_timer - dt_ms
    if S.scene_timer <= 0 then
      S.scene = M.SCENE_MAZE
      M.build_choices(S, true)
    end
    return
  end

  if scene == M.SCENE_CLEAR then
    S.scene_timer = S.scene_timer - dt_ms
    if S.scene_timer <= 0 then
      S.level = S.level + 1
      M.setup_level(S, true)
    end
    return
  end

  if scene ~= M.SCENE_MAZE and scene ~= M.SCENE_GATE then return end

  -- The clock stops during a fight so reading the sentence is never rushed.
  if S.fight == 0 then
    S.time_left = S.time_left - dt_ms / 1000
    if S.time_left <= CFG.TICK_THRESHOLD_S then
      local s = floor(S.time_left)
      if s ~= S.last_tick_s then
        S.last_tick_s = s
        if s >= 0 then emit(S, M.EV_TICK) end
      end
    end
    if S.time_left <= 0 then
      S.time_left = 0
      timeout(S)
      return
    end
  end

  -- Monsters hold still while the mouse glides or a fight is open.
  if not S.gliding and S.fight == 0 then
    S.mon_timer = S.mon_timer + dt_ms
    if S.mon_timer >= S.mon_step_ms then
      S.mon_timer = 0
      step_monsters(S)
    end
  end

  if S.scene == M.SCENE_MAZE and S.gliding then
    S.glide_k = S.glide_k + CFG.GLIDE_SPEED * dt_ms / 1000
    while S.gliding and S.glide_k >= 1 do
      S.glide_k = S.glide_k - 1
      local i = S.glide_path[S.glide_seg]
      collect_at(S, ((i - 1) % S.cols) + 1, ((i - 1) // S.cols) + 1)
      S.glide_seg = S.glide_seg + 1
      if S.glide_seg > S.glide_n then arrive(S) end
    end
  end

  -- Re-prompt after prolonged silence. Replaces the demo's near-miss hint, which
  -- needed a transcript the keyword-spotting backend does not provide (Q4).
  --
  -- Held off during a fight for the same reason the clock is (see above): the
  -- sentence is the longest thing the child has to read, so the beat that most
  -- needs patience must not be the one that nags every NO_MATCH_MS.
  if not S.gliding and S.fight == 0
     and (S.scene == M.SCENE_MAZE or S.scene == M.SCENE_GATE) then
    S.silence_ms = S.silence_ms + dt_ms
    if S.silence_ms >= CFG.NO_MATCH_MS then
      S.silence_ms = 0
      -- Actually re-prompt, which is what the event is named for: silence means
      -- the child does not know what to say, so name one thing to say.
      --
      -- Only in SCENE_MAZE with no monster in reach. The gate already shows its
      -- sentence permanently, and a monster already shows the FIGHT hint, both
      -- at a higher panel precedence than S.msg -- setting a message for those
      -- would be invisible duplication of what is on screen.
      if S.scene == M.SCENE_MAZE then
        local word = nil
        for k = 1, S.choice_n do
          local c = S.choices[k]
          if c.kind == M.CHOICE_MONSTER then
            word = nil
            break
          end
          word = word or c.word
        end
        if word then set_msg(S, "msg_say_lead", CFG.MSG_MS, word:upper()) end
      end
      emit(S, M.EV_NO_MATCH)
    end
  end
end

-- Mouse position in cell units, interpolated while gliding (for rendering).
function M.mouse_pos(S)
  if not S.gliding or S.glide_n == 0 then return S.mx, S.my end
  local seg = S.glide_seg
  local fx, fy
  if seg <= 1 then
    fx, fy = S.glide_fx, S.glide_fy
  else
    local p = S.glide_path[seg - 1]
    fx = ((p - 1) % S.cols) + 1
    fy = ((p - 1) // S.cols) + 1
  end
  local t = S.glide_path[min(seg, S.glide_n)]
  local tx = ((t - 1) % S.cols) + 1
  local ty = ((t - 1) // S.cols) + 1
  local k = S.glide_k
  return fx + (tx - fx) * k, fy + (ty - fy) * k
end

return M
