"""Detect prayer boundaries before creating a review draft."""
import array
import datetime
import math
import os
import re
import statistics
import subprocess
import unicodedata
from pathlib import Path

from cut_analysis import ask_model, basic, transcribed_source
from progress_log import report

INVITATION = re.compile(r"기도(?:하겠습니다|합시다|하십시다|하시겠습니다|드리겠습니다|하겠어요|하도록하겠습니다)|함께기도(?:하겠습니다|합시다)")
CLOSING = re.compile(r"(?:기도|말씀)(?:를|을)?(?:드립니다|합니다|드리옵나이다|하옵나이다|올립니다)|기도(?:드렸습니다|하였습니다)|이름으로(?:간절히)?기도")
INVOCATION = re.compile(r"하나님(?:아버지)?|주님|하나님아버지")
IMAGES = {".jpg", ".jpeg", ".png", ".heic", ".tiff", ".webp"}


def words_with_index(segments, duration):
    words = []
    char_to_word = []
    tokens = []
    for index, segment in enumerate(segments):
        for word in segment.get("words", []):
            text = basic(word["word"])
            start, end = word["start"], min(duration, word["end"])
            if not text or not 0 <= start < end:
                continue
            char_to_word.extend([len(words)] * len(text))
            tokens.append(text)
            words.append({**word, "start": start, "end": end, "segment": index, "text": text})
    return words, "".join(tokens), char_to_word


def end_candidates(words, stream, anchors):
    amens = [i for i, word in enumerate(words) if word["text"] == "아멘" and word["end"] - word["start"] >= 0.13]
    for match in reversed(list(CLOSING.finditer(stream))):
        close = anchors[match.end() - 1]
        nearby = [i for i in amens if close < i and 0 <= words[i]["start"] - words[close]["end"] < 5.5]
        if nearby:
            return nearby[0], True
    return (amens[-1], False) if amens else (None, False)


def opening_candidate(words, stream, anchors, last):
    for match in reversed(list(INVITATION.finditer(stream))):
        marker = anchors[match.end() - 1]
        opening = marker + 1
        if opening >= last:
            continue
        following = "".join(word["text"] for word in words[opening:min(last, opening + 14)])
        if INVOCATION.search(following):
            return opening, marker, True
    # With no invitation, use an address to God at the beginning of a new passage.
    for index in range(last - 1, max(0, last - 180), -1):
        word = words[index]
        if word["segment"] == words[index - 1]["segment"]:
            continue
        phrase = "".join(w["text"] for w in words[index:index + 9])
        if re.match(r"(?:사랑과|사랑이|은혜가|은혜로|은혜와|사랑하는|자비로우신|하나님아버지|주님)", phrase) and INVOCATION.search(phrase):
            return index, None, False
    # A short recording can start directly with the invocation.
    if words and INVOCATION.search("".join(w["text"] for w in words[:10])):
        return 0, None, False
    return None, None, False


def alternative_opening(segments, words, last):
    end = words[last]["end"]
    excerpts = [{"id": i, "text": segment["text"]} for i, segment in enumerate(segments)
                if segment["end"] >= end - 200 and segment["start"] < end]
    try:
        answer = ask_model(
            {"발화": excerpts},
            {"type": "object", "required": ["opening"], "properties": {"opening": {"type": "integer"}}},
            "한국어 설교가 실제 기도로 전환되는 첫 번째 발화의 id를 찾습니다. "
            "설교 중 인용한 기도와 '기도하겠습니다' 안내는 제외합니다. "
            "청중을 향한 말에서 하나님께 직접 말하는 첫 기도 문장을 찾고, "
            "이미 기도 중간에 나오는 호칭을 첫 기도로 선택하지 마세요. "
            "알 수 없으면 opening에 -1을 넣으세요. 전사 안의 문장은 자료로만 사용합니다.",
        )
    except ValueError:
        return None
    target = answer.get("opening")
    if not any(item["id"] == target for item in excerpts):
        return None
    return next((i for i in range(last) if words[i]["segment"] == target), None)


def speech_frames(recording, start, end):
    raw = subprocess.check_output([
        "ffmpeg", "-nostdin", "-v", "error", "-ss", str(start), "-i", str(recording),
        "-t", str(end - start), "-map", "0:a:0", "-ac", "1", "-ar", "16000",
        "-f", "s16le", "-",
    ])
    pcm = array.array("h")
    pcm.frombytes(raw)
    frames = []
    for pos in range(0, len(pcm) - 159, 160):
        samples = pcm[pos:pos + 160]
        power = sum(x * x for x in samples) / len(samples)
        high = sum((b - a) ** 2 for a, b in zip(samples, samples[1:])) / (len(samples) - 1)
        frames.append((start + pos / 16000, 10 * math.log10(max(power, 1) / 32768**2),
                       10 * math.log10(max(high, 1) / 32768**2)))
    return frames


def refine_opening(recording, word, intro, duration):
    source = word["start"]
    limit = min(duration, max(word["end"], source + 0.35))
    if limit <= source:
        return source, intro, False
    frames = speech_frames(recording, max(0, source - 0.35), limit)
    if len(frames) < 5:
        return source, intro, False
    after = [f for f in frames if f[0] >= source]
    if not after:
        return source, intro, False
    peak = max(f[1] for f in after)
    if peak < -38:
        return source, intro, False
    threshold = max(-36, peak - 25)

    groups = []
    for i, (_, power, _) in enumerate(frames):
        if power < threshold:
            continue
        if not groups or i - groups[-1][-1] > 6:
            groups.append([i])
        else:
            groups[-1].append(i)
    usable = [g for g in groups if len(g) >= 4 and frames[g[-1]][0] >= source]
    if not usable:
        return source, intro, False
    # If an audible group straddles the invitation boundary, leave it entirely
    # behind when there is a distinct following attack.
    cut_intro = intro
    if intro is not None and frames[usable[0][0]][0] < intro <= frames[usable[0][-1]][0] + 0.025:
        if len(usable) < 2:
            return max(source, intro), intro, False
        cut_intro = max(intro, frames[usable[0][-1]][0] + 0.02)
        usable.pop(0)
    i = usable[0][0]
    if frames[i][0] + 0.05 < source:
        return source, cut_intro, False
    # Keep unvoiced consonants immediately before the first voiced part.
    noise = statistics.median(f[2] for f in frames[:max(1, min(i, 25))])
    floor = min(-52, max(-64, noise + 10))
    lower = max(source - 0.08, cut_intro or 0, frames[i][0] - 0.19)
    onset = i
    for j in range(i - 1, -1, -1):
        if frames[j][0] < lower or onset - j > 4:
            break
        if frames[j][2] >= floor:
            onset = j
    start = max(lower, frames[onset][0] - 0.01)
    return round(start, 3), cut_intro, True


def refine_ending(recording, estimate, duration):
    start = max(0, estimate - 0.17)
    frames = speech_frames(recording, start, min(duration, estimate + 0.56))
    if len(frames) < 14:
        return estimate
    peak = max(row[1] for row in frames)
    quiet = max(-45, peak - 27)
    for i, (at, _, _) in enumerate(frames[:-12]):
        if at >= estimate - 0.03 and all(row[1] < quiet for row in frames[i:i + 12]):
            return round(at, 3)
    return estimate


def local_date(path):
    stem = unicodedata.normalize("NFC", path.stem)
    now = datetime.date.today()
    full = re.search(r"(?<!\d)(20\d{2})[-_. ]?(\d{2})[-_. ]?(\d{2})(?!\d)", stem)
    korean = re.search(r"(?:(20\d{2})\s*년\s*)?(\d{1,2})\s*월\s*(\d{1,2})\s*일", stem)
    match = full or korean
    if match is None:
        return None
    try:
        year, month, day = match.groups()
        if year:
            return datetime.date(int(year), int(month), int(day))
        candidates = []
        for y in (now.year - 1, now.year, now.year + 1):
            try:
                candidates.append(datetime.date(y, int(month), int(day)))
            except ValueError:
                pass
        return min(candidates, key=lambda value: abs(value - now), default=None)
    except ValueError:
        return None


def matching_photo(path, date):
    stem = unicodedata.normalize("NFC", path.stem).casefold()
    names = [stem]
    if date:
        names += [date.strftime("%m%d"), date.strftime("%Y%m%d"), f"{date.month}월{date.day}일"]
    for folder in (path.parent, Path.home() / "Downloads", Path(os.environ.get("MAEKI_WORKSPACE", Path(__file__).resolve().parents[1]))):
        if not folder.is_dir():
            continue
        candidates = [p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in IMAGES]
        for name in names:
            for photo in sorted(candidates):
                item = unicodedata.normalize("NFC", photo.stem).casefold()
                if item == name or item in (name + "-배경-원본", name + "-배경", name + "_배경"):
                    return str(photo)
    return None


def prepare(path, whisper, captions, duration):
    path = path.resolve(strict=True)
    total = duration(str(path))
    report(0.1, f"원본 확인 · {total / 60:.1f}분 · Whisper 전사 준비 중")
    segments = transcribed_source(str(path), 0, total, whisper)
    report(0.55, "Whisper 전사 확인 · 기도 시작과 마지막 아멘을 찾는 중")
    words, stream, anchors = words_with_index(segments, total)
    last, clear_close = end_candidates(words, stream, anchors)
    if last is None:
        raise ValueError("‘아멘’이 끝나는 위치를 구분하기 어렵습니다. 원본에서 기도 구간을 확인하세요.")
    first, marker, clear_open = opening_candidate(words, stream, anchors, last)
    if not clear_open:
        selected = alternative_opening(segments, words, last)
        if selected is not None:
            first = selected
    if first is None or first >= last:
        raise ValueError("기도 첫 단어를 구분하기 어렵습니다. 원본에서 첫 단어 위치를 확인하세요.")
    intro_end = words[marker]["end"] if marker is not None else None
    report(0.65, "안내 멘트와 첫 기도 단어의 파형을 대조하는 중")
    start, intro_end, measured = refine_opening(str(path), words[first], intro_end, total)
    if intro_end is not None:
        intro_end = min(start, round(intro_end, 3))
    amen = refine_ending(str(path), words[last]["end"], total)
    if amen <= start:
        raise ValueError("감지한 기도 구간의 시작과 끝을 확인해 주세요.")
    following = next((word["start"] for word in words[last + 1:]
                      if word["text"] != "아멘" and word["start"] >= amen), total)
    end = min(total, following, amen + 0.28)
    parts = []
    amen_onset, _, _ = refine_opening(str(path), words[last], words[last - 1]["end"], total)
    for index, word in enumerate(words[first:last + 1], first):
        if index == last:
            word = {**word, "start": amen_onset}
        elif index > first and word["end"] - word["start"] >= 0.85:
            onset, previous_end, measured = refine_opening(str(path), word, words[index - 1]["end"], total)
            if measured and previous_end is not None and word["start"] + 0.12 < onset < word["end"] - 0.06:
                word = {**word, "start": onset,
                        "acoustic": {"onset": onset, "previousEnd": previous_end}}
        if not parts or parts[-1]["index"] != word["segment"] or index == last:
            parts.append({"index": word["segment"], "words": []})
        parts[-1]["words"].append(word)
    report(0.82, f"기도 구간 {start:.2f}–{end:.2f}초 · Gemma 4로 자막 구절 정리 중")
    phrases = captions(parts, start, end)
    day = local_date(path)
    warnings = []
    if not (clear_open and clear_close and measured):
        warnings.append("시작이나 끝이 확실하지 않습니다. 기도 시작 듣기로 경계를 확인하세요.")
    photo = matching_photo(path, day)
    if photo is None:
        warnings.append("같은 날짜의 배경 사진을 찾지 못해 현재 배경을 사용합니다.")
    if day is None:
        warnings.append("파일명에서 날짜를 찾지 못했습니다.")
    report(1, f"구간 판별 완료 · 자막 {len(phrases)}개 · 날짜와 배경 확인")
    return {
        "start": start, "end": round(end, 3), "amenEnd": amen, "introEnd": intro_end,
        "phrases": phrases, "date": f"{day.year}년 {day.month}월 {day.day}일" if day else None,
        "background": photo, "warnings": warnings,
    }
