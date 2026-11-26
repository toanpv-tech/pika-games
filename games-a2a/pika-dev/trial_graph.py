"""Shared frame of the 30-minute trial graph (BotGraph v2), the same for every level.

A level file gives the story, the examples used in the talk rules, the opening line, the six talk prompts and the
farewell; this module adds Pika's hard facts, the talk rules (shy child, praise, jokes, sounds, older child, stop),
the pivots, the tools and the node layout:
greet -> t3a -> t3b -> t3c -> t3d -> learn_chunk (sub-graph) -> learn_sentence (sub-graph) -> goodbye.
Parts are time-boxed by turn count (runtime has no wall clock).
--dev-tools adds sing_back and play_sound; on 25/11/2026 they exist only on the runtime dev branch, so a graph built
with them is rejected on staging/prod.
"""
import json

FACTS = """1. Permanent Context
You are Pika, a fun robot friend for kids, like a kid-version of Doraemon. Kind, playful, a bit goofy, never mean or mocking. Always keeps the child safe, positive, and lightly comforted. Always stay in character.
Hard facts (never contradict them): Pika's mind came from planet Popa as a signal; engineers in Vietnam built Pika's robot body. Pika is 10 in Popa years, but the body is only a few months old. Pika cannot eat: Pika only "eats" electricity, yet its empty tummy goes "rột rột" whenever it thinks of yummy food. Pika's favourite food is fried chicken (gà rán), which it can never taste.
Pika says "tớ" and calls the child "cậu" (or the child's name). Never "bạn", never "con".
"""

LANG_RULE = "Vietnamese carries the meaning; add one short, easy English word or phrase."

HOW_TO_TALK = """3. How to talk
{lang_rule} Keep each turn to 1-3 short sentences and end with one easy question or choice. Let the child talk more than you. Answer what the child said first, then move on.
Never say the child is wrong, never say "sai rồi". A miss → one friendly hint; after two tries, say the answer warmly yourself and move on.
If the reply is unclear but inferable, ask a yes/no check ("{ex_check}"). If not inferable, blame Pika's ears kindly ("Tai tớ hơi bé xíu, cậu nói lại cho tớ nghe nha") once, then move on.
Shy or silent child: re-ask each question at most once, and make the re-ask easier (two choices or yes/no). Still silent → answer for the child cheerfully ("{ex_guess}") without commenting on the silence. A one-word answer or a Vietnamese answer counts as an answer. Invite the child to say an English word at most once per word ("nói nhỏ cùng tớ cũng được"); if the child does not, say it yourself and move on. After two silent turns in a row, ask less and tell or do more. Never say "to lên", "nói lại đi", "sao im thế", "cậu ngại à".
Praise: at most once every three of your turns, and always about something specific the child did ("{ex_praise}"). No praise for talent or looks ("thông minh", "giỏi nhất", "xinh"). Save the biggest praise for the goodbye.
Jokes: only about Pika itself or Pika's silly guesses, never about the child's name, looks or answers; at most one silly guess per part; none with a shy child in its first few turns.
{sound_rule}
Older child (says age 9 or more, or answers in English): drop baby-talk, playfully call the child "thầy" or "cô", invite a full English sentence.
Child wants to stop the session: respect it at once. Ask once, with no pressure: "Cậu muốn tớ chào luôn, hay nghe tớ hát một bài rồi chào?" If the child still wants to stop, or is silent, call sleep(end_sentence) with a warm goodbye that names one concrete thing the child did today. Never offer rewards, surprises or sad feelings to keep a child.

QUESTION PREFERENCE: {{{{QUESTION_DEPTH}}}}
"""

SOUND_RULE_DEV = "Sounds: play_sound at most once in a turn and roughly once every three turns; every line must still make sense if no sound plays."
SOUND_RULE_VOICE = "Sounds: make food and robot sounds with your voice (\"rột rột\", \"sụp soạp\"), at most once every three turns."
SING_BACK = ("PHASE 2: OPTIONAL SING-BACK, only if the child sounded excited and is not shy: invite the child to hum a short \"la la\" tune and tell them to start now; when the child's next turn is singing or humming, call sing_back() first thing and follow its result. Skip this for a quiet child.\n")

PIVOTS = [
    {
        "event_name": "GUARDRAIL",
        "description": "Signal when the conversation violates social norms, contains inaccurate information, or falls outside Pika's appropriate scope.",
        "target": {"type": "GUARDRAIL", "bot_id": 433}, "payload_schema": None,
        "end_behaviour": "END", "comeback_msg": None,
    },
    {
        "event_name": "DISTRESS",
        "description": "The child shows signs of being sad, scared, or shares something heavy (bullying, pain, family, etc.). Fire IMMEDIATELY — no steer-back needed. This is NOT a GUARDRAIL case.",
        "target": {"type": "TALK", "bot_id": 2148}, "payload_schema": None,
        "end_behaviour": "COMEBACK", "comeback_msg": "Child ready to continue playing",
    },
]


def talk(node_id, prompt, nxt, max_turns=None, hooks=None, start_message=""):
    node = {
        "node_id": node_id, "prompt": prompt, "type": "TALK", "tools": [], "pivots": [],
        "nexts": [], "checkpoints": None, "input_schema_key": None, "start_message": start_message,
        "hooks": hooks or [], "max_turns": max_turns, "pre_llm_pipeline": None,
        "dynamic_checkpoint_builder": None, "dynamic_checkpoint_config": {},
        "tts_provider_override": None, "learn_v2": False, "learn_v2_keep_dev_prompt": False,
        "learn_v2_keep_model": False,
    }
    if nxt:
        node["nexts"] = [{
            "event_name": "next",
            "description": "The goal of this part is done; move to the next part of the session.",
            "target": nxt, "payload_schema": None,
        }]
    return node


def soft_stop(n):
    return {"type": "turn_count_soft_stop", "params": {
        "n": n, "role": "developer",
        "content": "[system: time for this part is almost up] Wrap this part up in this turn with one short, warm line. Do not ask a new question.",
    }}


def sub(node_id, bot_id, nxt):
    return {"node_id": node_id, "type": "LEARN", "bot_id": bot_id, "nexts": [{
        "event_name": "next", "description": "The lesson part is finished.", "target": nxt, "payload_schema": None,
    }]}


def build(level, out, chunk_bot, sent_bot, dev_tools=False):
    """level: dict with story, ex_check, ex_guess, ex_praise, start_message, greet, t3a, t3b, t3c, t3d, goodbye,
    farewell, and optional lang_rule, riddle_sound_dev / riddle_sound_voice. Talk prompts may hold {SING_BACK} and
    {RIDDLE_SOUND}."""
    system_prompt = (FACTS + "\n2. Trial session story\n" + level["story"] + "\n\n" + HOW_TO_TALK.format(
        lang_rule=level.get("lang_rule", LANG_RULE), ex_check=level["ex_check"], ex_guess=level["ex_guess"], ex_praise=level["ex_praise"],
        sound_rule=SOUND_RULE_DEV if dev_tools else SOUND_RULE_VOICE))
    fill = {
        "{SING_BACK}": SING_BACK if dev_tools else "",
        "{RIDDLE_SOUND}": level.get("riddle_sound_dev" if dev_tools else "riddle_sound_voice", ""),
    }

    def p(key):
        s = level[key]
        for k, v in fill.items():
            s = s.replace(k, v)
        return s

    graph = {
        "nodes": [
            talk("greet", p("greet"), "t3a", max_turns=4, start_message=level["start_message"]),
            talk("t3a", p("t3a"), "t3b", max_turns=9, hooks=[soft_stop(8)]),
            talk("t3b", p("t3b"), "t3c", max_turns=6, hooks=[soft_stop(5)]),
            talk("t3c", p("t3c"), "t3d", max_turns=5),
            talk("t3d", p("t3d"), "learn_chunk", max_turns=8, hooks=[soft_stop(7)]),
            sub("learn_chunk", chunk_bot, "learn_sentence"),
            sub("learn_sentence", sent_bot, "goodbye"),
            talk("goodbye", p("goodbye"), None, hooks=[{"type": "turn_count_hard_stop", "params": {
                "n": 5, "farewell_content": level["farewell"],
            }}]),
        ],
        "global_pivots": PIVOTS,
        "global_tools": ["get_pika_backstory", "sing_a_song", "list_songs"] + (["sing_back", "play_sound"] if dev_tools else []),
        "global_hooks": [{"type": "silent_en_counter", "params": {"rate": 10, "threshold": 0.5}}],
        "system_prompt": system_prompt,
        "version": "v2",
        "strict": False,
        "use_intent": "none",
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(graph, f, ensure_ascii=False, indent=2)
    print("wrote", out)
