"""GitHub Actions から呼ばれる。リポジトリ変数から config.js を作る（アドインの設定ファイルは install.html が許可された人にだけ作る）。
手元で試すとき：SUPABASE_URL=... SUPABASE_ANON_KEY=... BASE_URL=https://.../ python3 tools/build.py
"""
import os, sys, re, json, uuid
from urllib.parse import urlparse

url = os.environ.get("SUPABASE_URL", "").strip()
key = os.environ.get("SUPABASE_ANON_KEY", "").strip()
base = os.environ.get("BASE_URL", "").strip()
if not url or not key:
    print("::error::リポジトリ変数 SUPABASE_URL と SUPABASE_ANON_KEY を設定してください（Settings → Secrets and variables → Actions → Variables）")
    sys.exit(1)
if key.startswith("sb_secret_") or "service_role" in key:
    print("::error::secret key / service_role key は使えません。Publishable key（sb_publishable_…）または anon key を設定してください")
    sys.exit(1)
if not base.endswith("/"):
    base += "/"
origin = "{0.scheme}://{0.netloc}".format(urlparse(base))
# アドインID：配布用 PowerPoint に組み込んだ枠と一致させるため固定（変える場合はリポジトリ変数 ADDIN_ID）
addin_id = os.environ.get("ADDIN_ID", "").strip() or "4b52dc98-0b83-40b0-9bd1-2a2d3261a063"

with open("config.js", "w", encoding="utf-8") as f:
    f.write("/* GitHub Actions が自動で作成。直接編集しないでください。 */\n")
    f.write("window.VOTE_CONFIG = " + json.dumps({
        "SUPABASE_URL": url, "SUPABASE_ANON_KEY": key, "ADDIN_ID": addin_id,
        "PARTICIPANT_POLL_MS": 3000, "PROJECTOR_POLL_MS": 2000}, ensure_ascii=False, indent=2) + ";\n")

# アドインの設定ファイルは公開フォルダに置かない（許可された人だけが install.html から入手する）
if os.path.exists("manifest.xml"):
    os.remove("manifest.xml")
print("config.js を作成しました:", base, "／アドインID:", addin_id)
