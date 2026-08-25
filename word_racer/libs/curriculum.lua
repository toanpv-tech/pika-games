local M = {}

local TOPICS = {
  {
    name = "Weather", pattern = "it is",
    words = { "sunny", "rainy", "windy", "cloudy", "snowy", "foggy" },
  },
  {
    name = "School", pattern = "this is",
    words = { "a ruler", "an eraser", "a book", "a pencil", "a bag", "a crayon" },
  },
  {
    name = "Clothes", pattern = "i have",
    words = { "a hat", "a t-shirt", "a jacket", "a dress", "trousers", "shoes" },
  },
  {
    name = "Fruits", pattern = "i like",
    words = { "a banana", "an apple", "an orange", "a mango", "a lime", "a coconut" },
  },
  {
    name = "Home", pattern = "this is",
    words = { "a bed", "a fridge", "a desk", "a lamp", "a window", "a door" },
  },
  {
    name = "Sports", pattern = "i like",
    words = { "football", "basketball", "badminton", "swimming", "cycling", "running" },
  },
  {
    name = "Nature", pattern = "i see",
    words = { "a lake", "a river", "a forest", "a beach", "a mountain", "a desert" },
  },
  {
    name = "Technology", pattern = "it is",
    words = { "a radio", "a camera", "a speaker", "a smartphone", "a laptop", "a keyboard" },
  },
  {
    name = "Transportation", pattern = "it is",
    words = { "a bike", "a plane", "a bus", "a car", "a boat", "a truck" },
  },
  {
    name = "Animals", pattern = "that is",
    words = { "a cat", "a dog", "a mouse", "a bear", "a lion", "a monkey" },
  },
  {
    name = "Hobby", pattern = "i like",
    words = { "drawing", "singing", "dancing", "reading", "cooking", "shopping" },
  },
  {
    name = "How I Feel", pattern = "i am",
    words = { "happy", "sad", "tired", "hungry", "fine", "sick" },
  },
  {
    name = "Face Parts", pattern = "this is my",
    words = { "nose", "mouth", "ear", "eye", "hair", "face" },
  },
  {
    name = "Colours", pattern = "my pen is",
    words = { "red", "blue", "green", "yellow", "orange", "black" },
  },
  {
    name = "Food", pattern = "i like",
    words = { "rice", "noodles", "soup", "sausage", "eggs", "cake" },
  },
  {
    name = "Toys", pattern = "i like",
    words = { "dolls", "toy cars", "kites", "balls", "robots", "balloons" },
  },
  {
    name = "Rooms", pattern = "this is the",
    words = { "kitchen", "bathroom", "bedroom", "living room", "dining room", "garden" },
  },
  {
    name = "Drinks", pattern = "i like",
    words = { "water", "milk", "juice", "tea", "juice milk", "soda" },
  },
  {
    name = "Vegetables", pattern = "this is a",
    words = { "carrot", "potato", "tomato", "cucumber", "corn", "onion" },
  },
  {
    name = "Size Shape", pattern = "it is",
    words = { "big", "small", "long", "short", "round", "square" },
  },
  {
    name = "Games", pattern = "i like",
    words = { "hide and seek", "tag", "racing", "chess", "skipping", "catching" },
  },
  {
    name = "Sweet Treats", pattern = "i am eating",
    words = { "candy", "cake", "chocolate", "ice cream", "cookies", "popcorn" },
  },
  {
    name = "Sea Animals", pattern = "it is",
    words = { "a fish", "a shark", "a dolphin", "a turtle", "a crab", "a whale" },
  },
  {
    name = "Places", pattern = "lets go to",
    words = { "the park", "the zoo", "the beach", "the school", "the shop", "the library" },
  },
}

local function clean(s)
  s = string.lower(tostring(s or ""))
  s = string.gsub(s, "it's", "it is")
  s = string.gsub(s, "that's", "that is")
  s = string.gsub(s, "what's", "what is")
  s = string.gsub(s, "let's", "lets")
  s = string.gsub(s, "i'm", "i am")
  s = string.gsub(s, "[^a-z' ]", " ")
  s = string.gsub(s, "'", " ")
  s = string.gsub(s, "%s+", " ")
  return string.gsub(s, "^%s*(.-)%s*$", "%1")
end

function M.clean(s)
  return clean(s)
end

function M.core(s)
  s = clean(s)
  s = string.gsub(s, "^a ", "")
  s = string.gsub(s, "^an ", "")
  s = string.gsub(s, "^the ", "")
  return s
end

function M.count()
  return #TOPICS
end

function M.topic(round, cursor)
  local base = tonumber(cursor) or 1
  local idx = ((base + round - 2) % #TOPICS) + 1
  return TOPICS[idx], idx
end

function M.boss_phrase(topic, word)
  return clean(topic.pattern .. " " .. word)
end

function M.build_keywords(topic)
  local out, seen = {}, {}
  local function add(s)
    s = clean(s)
    if s ~= "" and not seen[s] then
      seen[s] = true
      out[#out + 1] = s
    end
  end

  if not topic then return out end
  for i = 1, 3 do add(M.core(topic.words[i])) end
  for i = 4, 6 do add(M.boss_phrase(topic, topic.words[i])) end
  return out
end

return M
