#!/usr/bin/env python3
"""Build an editable daily-prayer timeline through Palmier Pro's local MCP."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path
from tempfile import mkdtemp
from urllib.error import URLError
from urllib.request import Request, urlopen

URL = "http://127.0.0.1:19789/mcp"
FPS = 30
MAX_VIDEO_FRAMES = 89 * FPS
OPENING_DISSOLVE = FPS
SUBTITLE_ROWS = 11
SUBTITLE_DISSOLVE = 10
SUBTITLE_LINE_SPACING = 0.043
SUBTITLE_FONT = "KimjungchulMyungjo-Regular"
SUBTITLE_FONT_SIZE = 25
DATE_Y = 0.862
MUSIC_UNDER_PRAYER_DB = -23
PRAYER_BACKGROUND_BLUR = 12
BACKGROUND_MATTE = 0.5159
PRAYER_MATTE = 0.34435
OUTRO_FONT = "GmarketSansTTFLight"
OUTRO_FONT_SIZE = 42
# Native text anchors and scales calibrated to the 1080 × 1920 ending reference.
OUTRO_WORDS = (
    ("God", 542, 639, 163 / 160, 63 / 62),
    ("Bless", 542, 753.5, 208 / 204, 62 / 61),
    ("Your", 542.5, 868.5, 181 / 189, 61 / 59),
    ("Day", 542, 985, 156 / 154, 78 / 72),
)
OUTRO_LOGO = {"centerX": 540 / 1080, "centerY": 1754.5 / 1920,
              "width": 86 / 1080, "height": 137 / 1920}


class Palmier:
    def __init__(self):
        self.session = None
        self.request("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "daily-prayer", "version": "1.0"},
        })
        self.request("notifications/initialized", {})

    def request(self, method, params):
        notice = method.startswith("notifications/")
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notice:
            message["id"] = 1
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        with urlopen(Request(URL, json.dumps(message).encode(), headers), timeout=30) as response:
            self.session = response.headers.get("Mcp-Session-Id", self.session)
            raw = response.read().decode()
        if notice:
            return None
        if raw.lstrip().startswith("{"):
            data = json.loads(raw)
        else:
            data = next(json.loads(line[6:]) for line in raw.splitlines()
                        if line.startswith("data: {"))
        if "error" in data:
            raise RuntimeError(data["error"])
        return data["result"]

    def call(self, tool, **arguments):
        response = self.request("tools/call", {"name": tool, "arguments": arguments})
        raw = next(item["text"] for item in response["content"] if item["type"] == "text")
        if response.get("isError"):
            raise RuntimeError(f"{tool}: {raw}")
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"{tool}: {raw}") from exc

    def import_path(self, path, name):
        return self.call("import_media", source={"path": str(path)}, name=name)["mediaRef"]

    def clip(self, media, start, end):
        return self.call("add_clips", entries=[{
            "mediaRef": media, "startFrame": start, "endFrame": end,
        }])["clips"][0]["id"]


def validate(job):
    for key in ("background", "layout", "logo", "recording", "music"):
        job[key] = Path(job[key]).expanduser().resolve(strict=True)
        if not job[key].is_file():
            raise ValueError(f"{key} requires a file")
    body = job["frames"] - job["outroFrames"]
    if job["sourceFps"] <= 0 or body <= 0 or job["outroFrames"] <= 0 or job["musicIn"] < 0:
        raise ValueError("Invalid frame rate, total/body/outro duration or music in point")
    length = timeline_frame(job, job["frames"])
    if length > MAX_VIDEO_FRAMES:
        raise ValueError(f"영상과 엔딩을 합쳐 1분 29초 이하여야 합니다. "
                         f"기도 구간에서 {(length - MAX_VIDEO_FRAMES) / FPS:.2f}초 이상 줄여 주세요.")
    if not job["voice"]:
        raise ValueError("At least one voice clip is required")
    for key in ("voice", "subtitles"):
        last = 0
        for entry in job.get(key, []):
            start, length = entry["at"], entry["frames"]
            if start < last or length <= 0 or start + length > body or entry.get("in", 0) < 0:
                raise ValueError(f"Invalid or overlapping {key} interval: {entry}")
            last = start + length
    last = -1
    for cue in subtitle_phrases(job):
        start = subtitle_start(job, cue)
        if not last < start < timeline_frame(job, body) or not cue["text"].strip():
            raise ValueError(f"Invalid subtitle phrase timing or text: {cue}")
        if "\n" in cue["text"] or "\r" in cue["text"]:
            raise ValueError(f"Each subtitle phrase must occupy one row: {cue['text']}")
        last = start
    if not 0 <= amen_end(job) <= body:
        raise ValueError("Amen end must be inside the prayer")
    if timeline_frame(job, job["frames"]) - timeline_frame(job, amen_end(job)) <= FPS:
        raise ValueError("Leave at least one second for the music to return to 0 dB")
    return body


def align_prayer_opening(job):
    first, *rest = job["voice"]
    original_in = first["in"]
    source_fps = job["sourceFps"]
    opening = job.get("opening", {})
    first_word = opening.get("firstWord", original_in)
    intro_end = opening.get("introEnd")
    if not 0 <= first_word or (intro_end is not None and not 0 <= intro_end <= first_word):
        raise ValueError("The opening invitation must end before the first word of the prayer")
    trimmed = round((first_word - original_in) * source_fps)
    if first_word < original_in or trimmed >= first["frames"]:
        raise ValueError("First prayer word is outside the opening voice clip")

    lead = round(source_fps)
    shift = lead - first["at"] - trimmed
    phrases = subtitle_phrases(job)
    if not phrases:
        raise ValueError("A first prayer subtitle is needed to align the opening")

    job["frames"] += shift
    if "amenEnd" in job:
        job["amenEnd"] += shift
    job["voice"] = [
        {**first, "at": lead, "in": first_word, "frames": first["frames"] - trimmed},
        *({**clip, "at": clip["at"] + shift} for clip in rest),
    ]
    job["phrases"] = [
        {**phrases[0], "projectFrame": 0},
        *({"text": cue["text"], "font": cue["font"], "size": cue["size"],
           "projectFrame": source_to_timeline(job, cue["sourceAt"]) if "sourceAt" in cue
           else timeline_frame(job, cue["at"] + shift)} for cue in phrases[1:]),
    ]
    job.pop("subtitles", None)


def prepare_voice(job, folder):
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise ValueError("ffmpeg is needed to extract the recording's dialogue track")
    folder.mkdir(exist_ok=True, parents=True)
    paths = []
    for number, clip in enumerate(job["voice"], 1):
        path = folder / f"기도-{number:02d}.wav"
        subprocess.run([
            ffmpeg, "-nostdin", "-n", "-hide_banner", "-loglevel", "error",
            "-ss", str(clip["in"]), "-i", str(job["recording"]),
            "-t", str(clip["frames"] / job["sourceFps"]), "-map", "0:a:0",
            "-vn", "-c:a", "pcm_s24le", str(path),
        ], check=True)
        paths.append(path)
    return paths


def timeline_frame(job, value):
    return round(value * FPS / job["sourceFps"])


def source_to_timeline(job, seconds):
    for clip in job["voice"]:
        end = clip["in"] + clip["frames"] / job["sourceFps"]
        if clip["in"] <= seconds < end:
            offset = round((seconds - clip["in"]) * FPS)
            return timeline_frame(job, clip["at"]) + offset
    raise ValueError(f"Subtitle source time {seconds:.3f}s is outside the retained prayer cuts")


def subtitle_start(job, cue):
    return cue["projectFrame"] if "projectFrame" in cue else timeline_frame(job, cue["at"])


def amen_end(job):
    if "amenEnd" in job:
        return job["amenEnd"]
    return max(clip["at"] + clip["frames"] for clip in job["voice"])


def subtitle_phrases(job):
    if "phrases" in job:
        return job["phrases"]
    phrases = []
    previous = []
    for cue in job.get("subtitles", []):
        lines = [line.strip() for line in cue["text"].splitlines() if line.strip()]
        prefix = 0
        while prefix < min(len(previous), len(lines)) and previous[prefix] == lines[prefix]:
            prefix += 1
        additions = lines[prefix:]
        for index, phrase in enumerate(additions):
            at = cue["at"] + round(index * cue["frames"] / len(additions))
            phrases.append({"at": at, "text": phrase, "font": cue["font"], "size": cue["size"]})
        previous = lines
    return phrases


def add_subtitle_pages(app, job, body):
    phrases = subtitle_phrases(job)
    entries = []
    fading = {}
    for first in range(0, len(phrases), SUBTITLE_ROWS):
        limit = first + SUBTITLE_ROWS
        page = phrases[first:limit]
        page_end = subtitle_start(job, phrases[limit]) if limit < len(phrases) else body
        last_start = subtitle_start(job, page[-1])
        fade_out = min(SUBTITLE_DISSOLVE, (page_end - last_start) // 2)
        first_line_y = 0.5 - (len(page) - 1) * SUBTITLE_LINE_SPACING / 2
        for row, cue in enumerate(page):
            start = subtitle_start(job, cue)
            dissolve = OPENING_DISSOLVE if start == 0 else SUBTITLE_DISSOLVE
            fade_in = min(dissolve, page_end - start - fade_out)
            fading[(start, page_end)] = (fade_in, fade_out)
            entries.append({
                "content": cue["text"], "startFrame": start, "endFrame": page_end,
                "style": {"fontName": cue["font"], "fontSize": cue["size"],
                          "color": "#FFFFFF", "alignment": "center"},
                "transform": {"x": 0.5, "y": first_line_y + row * SUBTITLE_LINE_SPACING},
            })
    if not entries:
        return []
    clips = app.call("add_texts", entries=entries)["clips"]
    by_fade = {}
    for clip in clips:
        by_fade.setdefault(fading[tuple(clip["frames"])], []).append(clip["id"])
    for (fade_in, fade_out), ids in by_fade.items():
        app.call("set_clip_properties", clipIds=ids, fadeInFrames=fade_in, fadeOutFrames=fade_out,
                 fadeInInterpolation="linear", fadeOutInterpolation="linear")
    return [clip["id"] for clip in clips]


def outro_text_style(x, y, width_scale, height_scale):
    return {
        "style": {"fontName": OUTRO_FONT, "fontSize": OUTRO_FONT_SIZE, "color": "#FFFFFF",
                  "alignment": "center", "widthScale": width_scale, "heightScale": height_scale},
        "transform": {"x": x / 1080, "y": y / 1920},
    }


def build(app, job, voice_paths):
    fps = job["sourceFps"]
    frame = lambda value: timeline_frame(job, value)
    end = frame(job["frames"])
    body = frame(job["frames"] - job["outroFrames"])
    restore_at = frame(amen_end(job))
    outro_start = max(body + 12, restore_at + FPS)
    known = app.call("manage_project", action="list")["projects"]
    names = {unicodedata.normalize("NFC", item["name"]).casefold() for item in known}
    base_name = unicodedata.normalize("NFC", job["name"])
    name = base_name
    counter = 2
    while name.casefold() in names:
        name = f"{base_name} ({counter})"
        counter += 1
    project = app.call("manage_project", action="create", name=name, fps=FPS,
                       aspectRatio="9:16", quality="1080p")
    app.call("manage_project", action="open", path=project["path"])
    background = app.clip(app.import_path(job["background"], "날짜 배경"), 0, end)
    print(project["path"], flush=True)

    app.call("apply_effect", clipIds=[background], effects=[
        {"type": "blur.gaussian", "params": {"radius": PRAYER_BACKGROUND_BLUR}},
    ])
    app.call("set_keyframes", clipId=background, property="blur", keyframes=[
        [0, PRAYER_BACKGROUND_BLUR, "hold"],
        [restore_at, PRAYER_BACKGROUND_BLUR, "linear"],
        [restore_at + FPS, 0],
    ])
    black = app.call("import_media", name="검정", source={"matte": {"hex": "#000000"}})["mediaRef"]
    base_matte = app.clip(black, 0, end)
    app.call("set_clip_properties", clipIds=[base_matte], opacity=BACKGROUND_MATTE)
    body_matte = app.clip(black, 0, body)
    app.call("set_clip_properties", clipIds=[body_matte], opacity=PRAYER_MATTE, fadeOutFrames=30)
    layout = app.clip(app.import_path(job["layout"], "매일의 기도 레이아웃"), 0, body)
    app.call("set_clip_properties", clipIds=[layout], fadeInFrames=OPENING_DISSOLVE, fadeOutFrames=15)
    logo = app.clip(app.import_path(job["logo"], "할렐루야교회 로고"), outro_start, end)
    app.call("set_clip_properties", clipIds=[logo], fadeInFrames=14,
             transform=OUTRO_LOGO)
    subtitle_ids = add_subtitle_pages(app, job, body)
    date_id = app.call("add_texts", entries=[
        {"content": job["date"]["text"], "startFrame": 0, "endFrame": body,
         "style": {"fontName": job["date"]["font"], "fontSize": job["date"]["size"], "color": "#FFFFFF", "alignment": "center"},
         "transform": {"x": 0.5, "y": DATE_Y}},
    ])["clips"][0]["id"]
    closing = app.call("add_texts", entries=[
        {"content": word, "startFrame": outro_start, "endFrame": end,
         **outro_text_style(*geometry)}
        for word, *geometry in OUTRO_WORDS
    ])["clips"]
    app.call("set_clip_properties", clipIds=[date_id], fadeInFrames=OPENING_DISSOLVE, fadeOutFrames=15)
    app.call("set_clip_properties", clipIds=[clip["id"] for clip in closing], fadeInFrames=14)
    voice = [{"mediaRef": app.import_path(path, path.stem), "startFrame": frame(clip["at"]),
              "source": [0, clip["frames"] / fps]} for path, clip in zip(voice_paths, job["voice"])]
    voice_ids = [c["id"] for c in app.call("add_clips", entries=voice)["clips"]]
    music = app.import_path(job["music"], "예배합니다")
    music_id = app.call("add_clips", entries=[{
        "mediaRef": music, "startFrame": 0, "source": [job["musicIn"], job["musicIn"] + end / FPS],
    }])["clips"][0]["id"]
    app.call("set_clip_properties", clipIds=[music_id], fadeInFrames=18, fadeOutFrames=30)
    gain = [[0, MUSIC_UNDER_PRAYER_DB, "hold"]]
    if restore_at:
        gain.append([restore_at, MUSIC_UNDER_PRAYER_DB, "linear"])
    else:
        gain[0][2] = "linear"
    gain.append([restore_at + FPS, 0])
    app.call("set_keyframes", clipId=music_id, property="volumeDb", keyframes=gain)

    state = app.call("get_timeline")
    by_id = {clip["id"]: (track, clip) for track in state["tracks"] for clip in track["clips"]}
    roles = [(background, "배경"), (layout, "레이아웃"), (logo, "로고"),
             (voice_ids[0], "기도"), (music_id, "음악"), (base_matte, "명암"),
             (body_matte, "본문명암"), (date_id, "날짜")]
    roles.extend((clip["id"], "엔딩타이틀") for clip in closing)
    subtitle_tracks = sorted({by_id[clip][0]["index"]: by_id[clip][0]["trackId"]
                              for clip in subtitle_ids}.items(), reverse=True)
    track_names = {by_id[clip][0]["trackId"]: role for clip, role in roles}
    track_names.update({track_id: f"기도자막{row}" for row, (_, track_id) in enumerate(subtitle_tracks, 1)})
    app.call("manage_tracks", set=[{"trackId": track_id, "name": role}
                                  for track_id, role in track_names.items()])
    if (state["width"], state["height"], state["fps"], state["totalFrames"]) != (1080, 1920, FPS, end):
        raise RuntimeError(f"Unexpected timeline size or duration: {state['totalFrames']} frames")
    actual_voice = [by_id[clip_id][1]["frames"] for clip_id in voice_ids]
    expected_voice = [[frame(clip["at"]), frame(clip["at"] + clip["frames"])] for clip in job["voice"]]
    for actual, expected in zip(actual_voice, expected_voice):
        if actual[0] != expected[0] or abs(actual[1] - expected[1]) > 1:
            raise RuntimeError(f"Unexpected voice placement: {actual}, expected {expected}")
    app.call("manage_project", action="close", path=project["path"])
    app.call("manage_project", action="open", path=project["path"])
    print(f"검증 완료 · {len(by_id)}개 클립 · {end}프레임 · 기도 컷 {actual_voice}", flush=True)
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("job", type=Path)
    parser.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    job = json.loads(args.job.read_text(encoding="utf-8"))
    align_prayer_opening(job)
    validate(job)
    if args.validate:
        print(f"{job['name']} · 입력 확인 완료")
        return
    app = Palmier()
    media_folder = Path(os.environ.get("MAEKI_WORKSPACE", Path(__file__).resolve().parent)) / "오디오"
    media_folder.mkdir(exist_ok=True)
    folder = Path(mkdtemp(prefix=f"{args.job.stem}-", dir=media_folder))
    build(app, job, prepare_voice(job, folder))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, RuntimeError, URLError, subprocess.CalledProcessError) as error:
        sys.exit(f"자동편집 중단 · {error}")
