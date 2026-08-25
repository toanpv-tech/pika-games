local M = {}

local language = "vi"

local TEXT = {
  en = {
    title = "PIKA  SPACE  WORDS",
    subtitle = "PLANET  JOURNEY",
    start_left = "PRESS",
    start_right = "TO START",
    flying_to = "FLYING TO ",
    round = "ROUND ",
    life_lost = "OUCH! -1 LIFE",
    journey_complete = "JOURNEY COMPLETE!",
    shield_used = "SHIELD!",
    shield_ready = "SHIELD READY",
    crystal = "ENERGY CRYSTAL +3",
    heart = "LIFE RESTORED",
    heart_full = "FULL LIVES +15",
    round_complete = "ROUND COMPLETE!",
    say_sentence = "SAY THE SENTENCE",
    sentence_correct = "CORRECT!",
    voice_unavailable = "VOICE OFF - PRESS STAR",
    magnet = "STAR MAGNET",
    shooting_star = "SHOOTING STAR +5",
    stars = "STARS ",
    lives = "LIVES ",
    shield = "SHIELD",
    score = "SCORE:",
  },
  vi = {
    title = "PIKA  DU HÀNH TỪ VỰNG",
    subtitle = "HÀNH TRÌNH HÀNH TINH",
    start_left = "NHẤN NÚT",
    start_right = "ĐỂ BẮT ĐẦU",
    flying_to = "ĐANG BAY TỚI ",
    round = "VÒNG ",
    life_lost = "VA CHẠM! -1 MẠNG",
    journey_complete = "HOÀN THÀNH HÀNH TRÌNH!",
    shield_used = "KHIÊN BẢO VỆ!",
    shield_ready = "ĐÃ CÓ KHIÊN",
    crystal = "TINH THỂ NĂNG LƯỢNG +3",
    heart = "HỒI PHỤC MỘT MẠNG",
    heart_full = "ĐẦY MẠNG +15",
    round_complete = "HOÀN THÀNH VÒNG!",
    say_sentence = "HÃY NÓI CẢ CÂU",
    sentence_correct = "CHÍNH XÁC!",
    voice_unavailable = "MIC LỖI - NHẤN NÚT SAO",
    magnet = "NAM CHÂM SAO",
    shooting_star = "SAO BĂNG +5",
    stars = "SAO ",
    lives = "MẠNG ",
    shield = "KHIÊN",
    score = "ĐIỂM:",
  },
}

local PLANETS_VI = {
  MERCURY = "SAO THỦY", VENUS = "SAO KIM",
  EARTH = "TRÁI ĐẤT", MARS = "SAO HỎA", JUPITER = "SAO MỘC",
  SATURN = "SAO THỔ", URANUS = "SAO THIÊN VƯƠNG", NEPTUNE = "SAO HẢI VƯƠNG",
}

local TOPICS_VI = {
  Weather = "Thời tiết", School = "Trường học", Clothes = "Quần áo",
  Fruits = "Trái cây", Home = "Ngôi nhà", Sports = "Thể thao",
  Nature = "Thiên nhiên", Technology = "Công nghệ", Transportation = "Giao thông",
  Animals = "Động vật", Hobby = "Sở thích", ["How I Feel"] = "Cảm xúc",
  ["Face Parts"] = "Khuôn mặt", Colours = "Màu sắc", Food = "Thức ăn",
  Toys = "Đồ chơi", Rooms = "Các phòng", Drinks = "Đồ uống",
  Vegetables = "Rau củ", ["Size Shape"] = "Kích thước và hình dạng",
  Games = "Trò chơi", ["Sweet Treats"] = "Đồ ăn ngọt",
  ["Sea Animals"] = "Động vật biển", Places = "Địa điểm",
}

function M.set_language(value)
  language = value == "vi" and "vi" or "en"
  return language
end

function M.language()
  return language
end

function M.t(key)
  return TEXT[language][key] or TEXT.en[key] or key
end

function M.planet(name)
  if language == "vi" then return PLANETS_VI[name] or name end
  return name
end

function M.topic(name)
  if language == "vi" then return TOPICS_VI[name] or name end
  return name
end

return M
