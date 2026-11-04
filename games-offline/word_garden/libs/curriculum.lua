local M = {}

local T = {
 {name="Weather",pattern="it is",words={"sunny","rainy","windy","cloudy","snowy","foggy"}},
 {name="School Objects",pattern="this is",words={"a ruler","an eraser","a book","a pencil","a bag","a crayon"}},
 {name="Clothes",pattern="i have",words={"a hat","a t-shirt","a jacket","a dress","trousers","shoes"}},
 {name="Fruits",pattern="i like",words={"a banana","an apple","an orange","a mango","a lime","a coconut"}},
 {name="Home",pattern="this is",words={"a bed","a fridge","a desk","a lamp","a window","a door"}},
 {name="Sports",pattern="i like",words={"football","basketball","badminton","swimming","cycling","running"}},
 {name="Nature",pattern="i see",words={"a lake","a river","a forest","a beach","a mountain","a desert"}},
 {name="Technology",pattern="it is",words={"a radio","a camera","a speaker","a smartphone","a laptop","a keyboard"}},
 {name="Transportation",pattern="it is",words={"a bike","a plane","a bus","a car","a boat","a truck"}},
 {name="Animals",pattern="that is",words={"a cat","a dog","a mouse","a bear","a lion","a monkey"}},
 {name="Hobby",pattern="i like",words={"drawing","singing","dancing","reading","cooking","shopping"}},
 {name="How I Feel",pattern="i am",words={"happy","sad","tired","hungry","fine","sick"}},
 {name="Face Parts",pattern="this is my",words={"nose","mouth","ear","eye","hair","face"}},
 {name="Classroom Colours",pattern="my pen is",words={"red","blue","green","yellow","orange","black"}},
 {name="Food I Like",pattern="i like",words={"rice","noodles","soup","sausage","eggs","cake"}},
 {name="Toys I Like",pattern="i like",words={"dolls","toy cars","kites","balls","robots","balloons"}},
 {name="Rooms",pattern="this is the",words={"kitchen","bathroom","bedroom","living room","dining room","garden"}},
 {name="Drinks I Like",pattern="i like",words={"water","milk","juice","tea","juice milk","soda"}},
 {name="Vegetables",pattern="this is a",words={"carrot","potato","tomato","cucumber","corn","onion"}},
 {name="Size Shape",pattern="it is",words={"big","small","long","short","round","square"}},
 {name="Games I Like",pattern="i like",words={"hide and seek","tag","racing","chess","skipping","catching"}},
 {name="Sweet Treats",pattern="i am eating",words={"candy","cake","chocolate","ice cream","cookies","popcorn"}},
 {name="Sea Animals",pattern="it is",words={"a fish","a shark","a dolphin","a turtle","a crab","a whale"}},
 {name="Places to Go",pattern="lets go to",words={"the park","the zoo","the beach","the school","the shop","the library"}},
}

function M.clean(s)
 s=string.lower(tostring(s or ""));s=string.gsub(s,"it's","it is");s=string.gsub(s,"that's","that is")
 s=string.gsub(s,"what's","what is");s=string.gsub(s,"let's","lets");s=string.gsub(s,"i'm","i am")
 s=string.gsub(s,"[^a-z' ]"," ");s=string.gsub(s,"'"," ");s=string.gsub(s,"%s+"," ")
 return string.gsub(s,"^%s*(.-)%s*$","%1")
end

function M.core(s)
 s=M.clean(s);s=string.gsub(s,"^a ","");s=string.gsub(s,"^an ","");s=string.gsub(s,"^the ","");return s
end

function M.topic(level)
 local i=((level-1)%#T)+1;return T[i],i
end

function M.topic_at(i) return T[((i-1)%#T)+1] end
function M.count() return #T end

function M.phrase(plot,level)
 local lead=level>=4 and "go away " or ""
 return M.clean(lead..plot.pattern.." "..plot.word)
end

function M.keywords(plots,level)
 local out,seen={},{}
 local function add(v) v=M.clean(v);if v~="" and not seen[v] then seen[v]=true;out[#out+1]=v end end
 for _,p in ipairs(plots) do add(p.core) end
 for _,p in ipairs(plots) do add(M.phrase(p,level)) end
 return out
end

return M
