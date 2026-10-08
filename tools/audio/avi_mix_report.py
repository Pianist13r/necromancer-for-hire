"""Звук из AVI Movie Maker Godot → WAV и числа микса (аудит звука 08.10, SND-17).

Movie Maker пишет кадры MJPEG и звук PCM (16 бит, стерео) в AVI без вывода на колонки —
драйвер звука в этом режиме принудительно Dummy (проверено 08.10: AudioServer.get_driver_name()).
Скрипт достаёт звуковые блоки «01wb», сохраняет рядом WAV и печатает: пик (dBFS), число
сэмплов у потолка (клиппинг), средний RMS и громкость по секундам — без ffmpeg.

    python tools/audio/avi_mix_report.py <файл.avi> [--wav <выход.wav>]
"""
import argparse
import math
import struct
import sys
import wave


def read_avi_audio(path):
    """Вернуть (частота, каналы, бит, байты PCM) из потока 01wb."""
    rate, channels, bits = 44100, 2, 16
    pcm = bytearray()
    with open(path, "rb") as f:
        data = f.read()
    # формат звука — в strf второго потока (WAVEFORMATEX): ищем 'auds' и следующий 'strf'
    i = data.find(b"auds")
    if i >= 0:
        j = data.find(b"strf", i)
        if j >= 0:
            fmt = data[j + 8:j + 8 + 16]
            _tag, channels, rate, _bps, _align, bits = struct.unpack("<HHIIHH", fmt)
    pos = data.find(b"movi")
    if pos < 0:
        raise SystemExit("нет списка movi")
    pos += 4
    end = len(data)
    while pos + 8 <= end:
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        if cid == b"LIST":
            pos += 12
            continue
        if cid == b"idx1":
            break
        if cid == b"01wb":
            pcm += data[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)
    return rate, channels, bits, bytes(pcm)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("avi")
    ap.add_argument("--wav", default=None)
    a = ap.parse_args()
    rate, ch, bits, pcm = read_avi_audio(a.avi)
    if bits != 16:
        raise SystemExit("ожидался PCM 16 бит, а не %d" % bits)
    out = a.wav or a.avi.rsplit(".", 1)[0] + ".wav"
    with wave.open(out, "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    n = len(pcm) // 2
    samples = struct.unpack("<%dh" % n, pcm)
    peak = max(abs(s) for s in samples) if samples else 0
    at_ceiling = sum(1 for s in samples if abs(s) >= 32700)
    frames = n // ch
    sec = frames / rate
    sq = sum(s * s for s in samples)
    rms = math.sqrt(sq / max(n, 1)) / 32768.0

    def db(v):
        return 20 * math.log10(max(v, 1e-9))

    print("файл: %s" % out)
    print("длительность %.1f с, %d Гц, %d кан." % (sec, rate, ch))
    print("пик %.1f dBFS (%d из 32767), сэмплов у потолка (≥32700): %d"
          % (db(peak / 32768.0), peak, at_ceiling))
    print("средний RMS %.1f dBFS" % db(rms))
    per = rate * ch
    worst = []
    line = []
    for k in range(int(sec)):
        chunk = samples[k * per:(k + 1) * per]
        if not chunk:
            break
        r = math.sqrt(sum(s * s for s in chunk) / len(chunk)) / 32768.0
        p = max(abs(s) for s in chunk) / 32768.0
        line.append("%d:%.0f/%.0f" % (k, db(r), db(p)))
        worst.append(p)
    print("по секундам (RMS/пик dBFS): " + " ".join(line))
    return 0


if __name__ == "__main__":
    sys.exit(main())
