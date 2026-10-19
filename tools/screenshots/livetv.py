"""livetv.py <out dir> <base url>: a demo Live TV source (M3U, XMLTV, logos, art) for the Live TV shot.

Art and summaries come from the server's "…-demo" libraries (PLEX_TOKEN, PLEX_SERVER as in shoot.sh).
Guide times are relative to now, so run it right before shooting. Channels are fictional.
"""
import datetime, json, os, sys, urllib.parse, urllib.request
from PIL import Image, ImageDraw, ImageFont

OUT, BASE = sys.argv[1:3]
SERVER = os.environ.get("PLEX_SERVER", "http://192.168.1.140:32400")
TOKEN = os.environ["PLEX_TOKEN"]
FONT = "/Library/Fonts/SF-Pro-Display-Heavy.otf"

# (number, channel, genre, airing now, up next)
CHANNELS = [
    (101, "Cinema One", "Movie", "Sintel", "Tears of Steel"),
    (102, "Indie Film", "Movie", "Cosmos Laundromat", "Elephants Dream"),
    (103, "Sci-Fi Cinema", "Movie", "Tears of Steel", "Sintel"),
    (104, "Art House", "Movie", "Elephants Dream", "Cosmos Laundromat"),
    (201, "Toon Time", "Kids", "Spring", "Caminandes"),
    (202, "Family", "Kids", "Big Buck Bunny", "Spring"),
    (203, "Kids Club", "Kids", "Caminandes", "Big Buck Bunny"),
    (301, "Classic TV", "Drama", "Sherlock Holmes (1954)", "Pioneer One"),
    (302, "Drama Plus", "Drama", "Pioneer One", "Sherlock Holmes (1954)"),
]


def get(path):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(f"{SERVER}{path}{sep}X-Plex-Token={TOKEN}", headers={"Accept": "application/json"})
    return urllib.request.urlopen(req, timeout=20).read()


os.makedirs(OUT, exist_ok=True)
items = {}
for d in json.loads(get("/library/sections"))["MediaContainer"]["Directory"]:
    if d["title"].endswith("-demo"):
        for m in json.loads(get(f"/library/sections/{d['key']}/all"))["MediaContainer"]["Metadata"]:
            items[m["title"]] = m

for title, m in items.items():
    if m.get("art"):
        q = urllib.parse.quote(m["art"])
        open(f"{OUT}/art-{m['ratingKey']}.jpg", "wb").write(get(f"/photo/:/transcode?width=1280&height=720&minSize=1&url={q}"))

font = ImageFont.truetype(FONT, 110)
for num, name, *_ in CHANNELS:
    w = int(font.getlength(name)) + 20
    logo = Image.new("RGBA", (w, 150), (0, 0, 0, 0))
    ImageDraw.Draw(logo).text((10, 75), name, font=font, fill="white", anchor="lm")
    logo.save(f"{OUT}/logo-{num}.png")

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

now = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
fmt = lambda t: t.strftime("%Y%m%d%H%M%S +0000")
m3u = ["#EXTM3U"]
xml = ['<?xml version="1.0" encoding="UTF-8"?>', "<tv>"]
for i, (num, name, genre, current, upnext) in enumerate(CHANNELS):
    cid = f"demo{num}"
    m3u.append(f'#EXTINF:-1 tvg-id="{cid}" tvg-chno="{num}" tvg-logo="{BASE}/logo-{num}.png",{name}')
    m3u.append(f"{BASE}/stream-{num}.m3u8")
    xml.append(f'<channel id="{cid}"><display-name>{esc(name)}</display-name><icon src="{BASE}/logo-{num}.png"/></channel>')
    start = now - datetime.timedelta(minutes=10 + 7 * i)
    for title, length in ((current, 30 + 8 * i), (upnext, 90), (current, 90)):
        m = items[title]
        stop = start + datetime.timedelta(minutes=length)
        art = f'<icon src="{BASE}/art-{m["ratingKey"]}.jpg" width="1280" height="720"/>' if m.get("art") else ""
        xml.append(f'<programme channel="{cid}" start="{fmt(start)}" stop="{fmt(stop)}"><title>{esc(title)}</title>'
                   f'<desc>{esc(m.get("summary", ""))}</desc><category>{genre}</category>{art}</programme>')
        start = stop
xml.append("</tv>")
open(f"{OUT}/demo.m3u", "w").write("\n".join(m3u) + "\n")
open(f"{OUT}/guide.xml", "w").write("\n".join(xml) + "\n")
print(f"{OUT}: {len(CHANNELS)} channels, art for {sum(1 for m in items.values() if m.get('art'))} titles")
