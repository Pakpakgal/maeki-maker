"""Translate the review app's editable draft into the existing Palmier job format."""
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE = Path(os.environ.get("MAEKI_WORKSPACE", ROOT))
sys.path.insert(0, str(ROOT))
from build_prayer import (
    BACKGROUND_MATTE, DATE_Y, OUTRO_LOGO, OUTRO_WORDS, PRAYER_BACKGROUND_BLUR, PRAYER_MATTE,
    SUBTITLE_FONT, SUBTITLE_FONT_SIZE, SUBTITLE_LINE_SPACING,
    align_prayer_opening, outro_text_style, subtitle_page_ranges, subtitle_phrases, validate,
)

from caption_grouping import caption_rows
from progress_log import report

FPS = 30


def load(path):
    job = json.loads(Path(path).read_text(encoding="utf-8"))
    if "review" in job:
        return job["review"]
    fps = job["sourceFps"]
    voice = job["voice"]
    first, last = voice[0], voice[-1]
    start = job.get("opening", {}).get("firstWord", first["in"])
    end = last["in"] + last["frames"] / fps

    def source_at(cue):
        if "sourceAt" in cue:
            return cue["sourceAt"]
        at = cue["at"]
        for clip in voice:
            if clip["at"] <= at < clip["at"] + clip["frames"]:
                return clip["in"] + (at - clip["at"]) / fps
        return start if at <= first["at"] else None

    phrases = []
    for cue in subtitle_phrases(job):
        at = source_at(cue)
        if at is not None and at < end:
            if phrases and at <= phrases[-1]["sourceAt"]:
                continue
            phrases.append({"text": cue["text"], "sourceAt": max(start, at), "visible": True})
    for left, right in zip(voice, voice[1:]):
        if left["in"] + left["frames"] / fps > right["in"] + 1e-6:
            raise ValueError("이 작업의 음성 컷은 원본 순서대로 배치되어 있지 않습니다.")
    cuts = []
    for left, right in zip(voice, voice[1:]):
        gap_start = left["in"] + left["frames"] / fps
        if gap_start + 1e-6 < right["in"]:
            cuts.append({"start": gap_start, "end": right["in"], "reason": "기존 음성 컷"})
    return {
        "name": job["name"], "date": job["date"]["text"], "recording": job["recording"],
        "background": job["background"], "music": job["music"],
        "musicEnd": job["musicIn"] + job["frames"] / fps,
        "start": start, "end": end,
        "amenEnd": last["in"] + (job.get("amenEnd", last["at"] + last["frames"]) - last["at"]) / fps,
        "introEnd": job.get("opening", {}).get("introEnd"),
        "phrases": phrases, "cuts": cuts, "zoom": 1, "cropX": 0.5, "cropY": 0.5,
    }


def template_job():
    defaults = json.loads((ROOT / "defaults.json").read_text(encoding="utf-8"))
    sample = WORKSPACE / "1206.json"
    config = WORKSPACE / "assets.json"
    for source in (sample, config):
        if source.is_file():
            settings = json.loads(source.read_text(encoding="utf-8"))
            for key in ("layout", "logo", "music"):
                if key in settings:
                    defaults[key] = settings[key]
    return defaults


def preview_style():
    job = template_job()
    return {
        "layout": job["layout"], "logo": job["logo"], "logoGeometry": OUTRO_LOGO,
        "date": {**job["date"], "x": 0.5, "y": DATE_Y},
        "subtitleFont": SUBTITLE_FONT, "subtitleSize": SUBTITLE_FONT_SIZE,
        "lineSpacing": SUBTITLE_LINE_SPACING,
        "blur": PRAYER_BACKGROUND_BLUR, "matte": BACKGROUND_MATTE, "bodyMatte": PRAYER_MATTE,
        "words": [{"text": word, **outro_text_style(*geometry)} for word, *geometry in OUTRO_WORDS],
    }


def retained_spans(draft):
    start, end = draft["start"], draft["end"]
    if not 0 <= start < end:
        raise ValueError("기도 시작과 끝의 원본 시간을 확인하세요.")
    amen = draft["amenEnd"]
    if not start < amen <= end:
        raise ValueError("아멘 종료 시각이 기도 구간 안에 있어야 합니다.")
    intro = draft.get("introEnd")
    if intro is not None and not 0 <= intro <= start:
        raise ValueError("안내 멘트가 첫 단어 시작과 겹칩니다.")
    cursor = start
    for cut in sorted(draft["cuts"], key=lambda item: item["start"]):
        left, right = cut["start"], cut["end"]
        if not start < left < right < amen:
            raise ValueError("삭제 구간은 첫 단어 뒤부터 아멘 종료 전까지 지정하세요.")
        if left < cursor:
            raise ValueError("서로 겹치는 삭제 구간을 합쳐 주세요.")
        if left > cursor:
            yield cursor, left
        cursor = right
    yield cursor, end


def media_duration(path):
    probe = shutil.which("ffprobe")
    if probe is None:
        raise ValueError("미디어 길이를 확인하려면 FFmpeg가 필요합니다.")
    output = subprocess.check_output([
        probe, "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", path,
    ], text=True)
    return float(output.strip())


def whisper_segments(recording, start, end):
    ffmpeg, whisper = shutil.which("ffmpeg"), shutil.which("mlx_whisper")
    if not ffmpeg or not whisper:
        raise ValueError("자동 초안에는 설치된 FFmpeg와 MLX Whisper가 필요합니다.")
    with tempfile.TemporaryDirectory() as directory:
        wav = Path(directory) / "prayer.wav"
        subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-ss", str(start),
                        "-i", recording, "-t", str(end - start),
                        "-map", "0:a:0", "-ac", "1", "-ar", "16000", str(wav)],
                       check=True, capture_output=True)
        result = subprocess.run([
            whisper, str(wav), "--model", "mlx-community/whisper-large-v3-turbo",
            "--language", "ko", "--output-format", "json", "--output-dir", directory,
            "--word-timestamps", "True", "--verbose", "False",
        ], env={**os.environ, "HF_HUB_OFFLINE": "1"}, capture_output=True, text=True)
        if result.returncode:
            raise ValueError("로컬 전사를 실행할 수 없습니다. 설치된 Whisper 모델을 확인하세요.")
        return json.loads(wav.with_suffix(".json").read_text(encoding="utf-8"))["segments"]


def transcribe(draft):
    start, end = draft["start"], draft["end"]
    if not 0 <= start < end <= media_duration(draft["recording"]) + 0.01:
        raise ValueError("전사하기 전에 유효한 기도 시작·끝 시각을 지정하세요.")
    report(0.1, f"선택 구간 전사 · 원본 {start:.2f}–{end:.2f}초")
    segments = whisper_segments(draft["recording"], start, end)
    report(0.65, "Whisper 전사 완료 · Gemma 4로 자막 구절 정리 중")
    cues = caption_rows(segments, start, end, start)
    report(1, f"자막 초안 {len(cues)}개 준비 완료")
    return cues


def compile_job(draft, crop_path):
    template = template_job()
    if not all(template[key] and Path(template[key]).is_file() for key in ("layout", "logo")):
        raise ValueError("앱의 ‘공통 에셋’에서 레이아웃과 로고 파일을 지정하세요.")
    if not draft["name"].strip() or not draft["date"].strip():
        raise ValueError("프로젝트 이름과 날짜를 입력하세요.")
    if draft["end"] > media_duration(draft["recording"]) + 0.01:
        raise ValueError("기도 끝 시각이 녹화 파일보다 깁니다.")
    spans = list(retained_spans(draft))
    position = FPS
    voice = []
    for start, end in spans:
        frames = round((end - start) * FPS)
        if frames <= 0:
            raise ValueError("음성 컷이 한 프레임보다 짧습니다.")
        voice.append({"at": position, "in": start, "frames": frames})
        position += frames

    phrases = []
    for cue in sorted(draft["phrases"], key=lambda row: row["sourceAt"]):
        at = cue["sourceAt"]
        if not cue["visible"] or any(c["start"] <= at < c["end"] for c in draft["cuts"]):
            continue
        if not draft["start"] <= at < draft["end"]:
            raise ValueError(f"기도 구간 밖의 자막을 확인하세요. {cue['text']}")
        text = cue["text"].strip()
        if not text:
            raise ValueError("빈 자막에 문구를 입력하거나 숨겨 주세요.")
        phrases.append({"sourceAt": at, "text": text, "font": SUBTITLE_FONT, "size": SUBTITLE_FONT_SIZE})
    if not phrases or abs(phrases[0]["sourceAt"] - draft["start"]) > 1 / FPS:
        raise ValueError("첫 자막을 첫 기도 단어의 원본 시각에 맞춰 주세요.")

    tail = voice[-1]
    amen = tail["at"] + round((draft["amenEnd"] - tail["in"]) * FPS)
    total = position + 15 + template["outroFrames"]
    if total > 89 * FPS:
        raise ValueError(f"전체 길이 {total / FPS:.2f}초. {(total - 89 * FPS) / FPS:.2f}초를 더 줄여 주세요.")
    music_end = draft["musicEnd"]
    if not math.isfinite(music_end) or music_end > media_duration(draft["music"]) + 0.01:
        raise ValueError("음악 종료 시각이 BGM 파일보다 깁니다.")
    if music_end < total / FPS:
        raise ValueError("선택한 BGM 구간이 완성 영상보다 짧습니다.")

    job = {key: template[key] for key in ("layout", "logo", "outroFrames")}
    job.update(
        name=draft["name"].strip(), sourceFps=FPS, frames=total,
        background=str(Path(crop_path).resolve(strict=True)), recording=draft["recording"],
        music=draft["music"], musicIn=music_end - total / FPS, voice=voice,
        date={**template["date"], "text": draft["date"].strip()},
        phrases=phrases, amenEnd=amen, opening={"firstWord": draft["start"], "introEnd": draft.get("introEnd")},
        review=draft,
    )
    # Validate a copy because the executor normalizes jobs in place.
    check = json.loads(json.dumps(job))
    align_prayer_opening(check)
    validate(check)
    return job


def main():
    command, *args = sys.argv[1:]
    if command == "asset-settings":
        result = {key: template_job()[key] for key in ("layout", "logo", "music")}
    elif command == "preview-style":
        result = preview_style()
    elif command == "subtitle-pages":
        texts = json.loads(Path(args[0]).read_text(encoding="utf-8"))
        result = [texts[first:limit] for first, limit in subtitle_page_ranges(texts)]
    elif command == "load":
        result = load(args[0])
    elif command == "compile":
        result = compile_job(json.loads(Path(args[0]).read_text(encoding="utf-8")), args[1])
    elif command == "prepare":
        from auto_prepare import prepare
        result = prepare(Path(args[0]), whisper_segments, caption_rows, media_duration)
    elif command == "analyze":
        from cut_analysis import analyze
        result = analyze(json.loads(Path(args[0]).read_text(encoding="utf-8")),
                         whisper_segments, retained_spans, media_duration)
    elif command == "transcribe":
        result = transcribe(json.loads(Path(args[0]).read_text(encoding="utf-8")))
    else:
        raise ValueError(f"Unknown review command: {command}")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
