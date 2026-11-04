-- libs/curriculum — Pre-A1 vocabulary, word normalisation and sentence targets
-- Resolve: require("libs/curriculum")
--
-- TOPICS is carried verbatim from input/word_maze.html CURRICULUM (24 topics x 6
-- words). `pat` and the per-word `core` are precomputed at build time with the
-- same rules as the demo's norm()/core()/patternTokens(), so no string work
-- happens at runtime:
--   norm():  lowercase, expand it's/that's/what's/let's/i'm, drop punctuation
--   core():  norm() minus a leading article ("a ruler" -> "ruler")
--
-- The demo's `pat` field is deliberately absent: its sentMatch() looked for the
-- pattern AND the core inside a free-form transcript, but this backend does
-- keyword spotting and returns one whole matched keyword, so a sentence target is
-- registered as a single keyword and compared directly.

local M = {}

M.TOPICS = {
  { topic = "Weather", disp = "It is", words = { "sunny", "rainy", "windy", "cloudy", "snowy", "foggy" } },
  { topic = "School Objects", disp = "This is", words = { "a ruler", "an eraser", "a book", "a pencil", "a bag", "a crayon" } },
  { topic = "Clothes", disp = "I have", words = { "a hat", "a T-shirt", "a jacket", "a dress", "trousers", "shoes" } },
  { topic = "Fruits", disp = "I like", words = { "a banana", "an apple", "an orange", "a mango", "a lime", "a coconut" } },
  { topic = "Home", disp = "This is", words = { "a bed", "a fridge", "a desk", "a lamp", "a window", "a door" } },
  { topic = "Sports", disp = "I like", words = { "football", "basketball", "badminton", "swimming", "cycling", "running" } },
  { topic = "Nature", disp = "I see", words = { "a lake", "a river", "a forest", "a beach", "a mountain", "a desert" } },
  { topic = "Technology", disp = "It is", words = { "a radio", "a camera", "a speaker", "a smartphone", "a laptop", "a keyboard" } },
  { topic = "Transportation", disp = "It's", words = { "a bike", "a plane", "a bus", "a car", "a boat", "a truck" } },
  { topic = "Animals", disp = "That is", words = { "a cat", "a dog", "a mouse", "a bear", "a lion", "a monkey" } },
  { topic = "Hobby", disp = "I like", words = { "drawing", "singing", "dancing", "reading", "cooking", "shopping" } },
  { topic = "How I Feel", disp = "I am", words = { "happy", "sad", "tired", "hungry", "fine", "sick" } },
  { topic = "Face Parts", disp = "This is my", words = { "nose", "mouth", "ear", "eye", "hair", "face" } },
  { topic = "Classroom Colours", disp = "My pen is", words = { "red", "blue", "green", "yellow", "orange", "black" } },
  { topic = "Food I Like", disp = "I like", words = { "rice", "noodles", "soup", "sausage", "eggs", "cake" } },
  { topic = "Toys I Like", disp = "I like", words = { "dolls", "toy cars", "kites", "balls", "robots", "balloons" } },
  { topic = "Rooms", disp = "This is the", words = { "kitchen", "bathroom", "bedroom", "living room", "dining room", "garden" } },
  { topic = "Drinks I Like", disp = "I like", words = { "water", "milk", "juice", "tea", "juice milk", "soda" } },
  { topic = "Vegetables", disp = "This is a", words = { "carrot", "potato", "tomato", "cucumber", "corn", "onion" } },
  { topic = "Size & Shape", disp = "It is", words = { "big", "small", "long", "short", "round", "square" } },
  { topic = "Games I Like", disp = "I like", words = { "hide and seek", "tag", "racing", "chess", "skipping", "catching" } },
  { topic = "Sweet Treats", disp = "I am eating", words = { "candy", "cake", "chocolate", "ice cream", "cookies", "popcorn" } },
  { topic = "Sea Animals", disp = "It is", words = { "a fish", "a shark", "a dolphin", "a turtle", "a crab", "a whale" } },
  { topic = "Places to Go", disp = "Let's go to", words = { "the park", "the zoo", "the beach", "the school", "the shop", "the library" } },
}

-- Strip a leading article, matching the demo's core(). Applied to authored words
-- only (at load), never to a runtime keyword: the backend returns bare keywords.
local ARTICLES = { ["a "] = true, ["an "] = true, ["the "] = true }

function M.core(word)
  local s = word:lower():gsub("[^%a' ]", " "):gsub("'", " "):gsub("%s+", " ")
  s = s:match("^%s*(.-)%s*$")
  for art in pairs(ARTICLES) do
    if s:sub(1, #art) == art then return s:sub(#art + 1) end
  end
  return s
end

-- Normalise a keyword coming back from the voice backend so it can be compared
-- with a precomputed core.
function M.clean(s)
  if type(s) ~= "string" then return "" end
  s = s:lower():gsub("[^%a' ]", " "):gsub("'", " "):gsub("%s+", " ")
  return (s:match("^%s*(.-)%s*$"))
end

-- Display sentence + its match key for a fight/gate target, matching the demo's
-- sentenceTarget(): topic pattern + the word, keeping curriculum grammar intact.
function M.sentence(topic_idx, word)
  local t = M.TOPICS[topic_idx]
  return t.disp .. " " .. word, M.core(word)
end

M.COUNT = #M.TOPICS

-- Cores per topic, precomputed once at load. Indexed [topic_idx][word_idx] so the
-- hot path never calls string functions.
M.CORES = {}
for i = 1, M.COUNT do
  local t = M.TOPICS[i]
  local cores = {}
  for j = 1, #t.words do
    cores[j] = M.core(t.words[j])
  end
  M.CORES[i] = cores
end

-- HTML topicOf(): topics cycle so play past map 24 keeps working.
function M.topic_index(level)
  return ((level - 1) % M.COUNT) + 1
end

return M
