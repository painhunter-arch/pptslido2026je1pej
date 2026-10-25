/* 共通処理：Supabase接続、エラー文言、結果の描画 */
(function () {
  const cfg = window.VOTE_CONFIG || {};
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.includes("YOUR-PROJECT")) {
    document.addEventListener("DOMContentLoaded", () => {
      document.body.innerHTML =
        '<p class="notice error" style="margin:2rem">config.js に Supabase の URL と anon key を設定してください。</p>';
    });
  }
  const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
  });

  const MESSAGES = {
    event_not_found: "参加コードが見つかりません。URLを確認してください。",
    event_closed: "この会の参加受付は終了しました。",
    invalid_participant: "参加情報が無効になりました。もう一度参加してください。",
    question_not_found: "質問が見つかりません。",
    question_not_active: "この質問は締め切られたか、次の質問に進みました。",
    voting_closed: "投票は締め切られました。",
    already_voted: "この質問には投票済みです（変更できない設定です）。",
    select_exactly_one: "1つ選んでください。",
    select_count_out_of_range: "選べる数を確認してください。",
    rank_count_mismatch: "指定された数だけ順位をつけてください。",
    no_selection: "選択肢を選んでください。",
    duplicate_option: "同じ選択肢が重複しています。",
    invalid_option: "選択肢が更新されました。画面を読み込み直してください。",
    empty_text: "回答を入力してください。",
    text_too_long: "文字数が上限を超えています。",
    text_limit_reached: "この質問への投稿数の上限に達しました。",
    own_post: "自分の投稿には賛同できません。",
    add_not_allowed: "この質問では選択肢を追加できません。",
    too_many_options: "選択肢は10件までです。",
    post_not_found: "この投稿は表示されていません。",
    not_approved: "まだ利用が許可されていません。全体管理者（伊東）の許可をお待ちください。",
    bad_email: "メールアドレスの形式が正しくありません。",
    nickname_required: "ニックネーム（本名でも可）を入力してください。",
    bad_project_or_pass: "プロジェクト番号またはパスワードが違います。",
    pass_too_short: "プロジェクトのパスワードは8文字以上にしてください。",
    too_many_attempts: "失敗が続いたため、1時間ほど待ってからお試しください。",
    login_required: "ログインしてください。",
    admin_exists: "全体管理者は既に登録されています。",
    bad_code: "参加コードは英数字2〜16文字にしてください。",
    forbidden: "この操作の権限がありません。"
  };
  function errText(err) {
    const m = (err && (err.message || err.error_description || String(err))) || "";
    for (const k of Object.keys(MESSAGES)) if (m.includes(k)) return MESSAGES[k];
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "通信できません。電波状況を確認してください。";
    return "エラーが発生しました：" + m;
  }

  async function rpc(name, args) {
    const { data, error } = await sb.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function esc(s) {
    return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  /* 自由記載のまとめ：表記ゆれ（全角半角・空白・句読点）を寄せて同じ回答を数える */
  function groupTexts(texts) {
    const map = new Map();
    for (const t of texts) {
      if (t.hidden) continue;
      const key = t.body.normalize("NFKC").replace(/[\s、。,.!！?？・]/g, "").toLowerCase();
      if (!key) continue;
      const g = map.get(key);
      if (g) g.count++; else map.set(key, { label: t.body.normalize("NFKC").trim(), count: 1, key });
    }
    return [...map.values()];
  }
  function hash(s) { let h = 0; for (const c of s) h = (h * 31 + c.codePointAt(0)) | 0; return h; }

  /* 結果を描画する。data は get_results の戻り値 */
  function renderResults(el, data, opt = {}) {
    const q = data.question;
    if (!q) { el.innerHTML = ""; return; }
    const voters = data.voters || 0;
    const mode = opt.displayMode || q.display_mode;

    if (q.type === "qa" || q.type === "ideas") {
      const posts = (data.texts || []).filter(t => !t.hidden);
      const unit = q.type === "qa" ? "賛同" : "共感";
      let show, empty;
      if (q.board_mode === "top") {
        show = posts.slice().sort((a, b) => (b.likes || 0) - (a.likes || 0) || String(a.created_at).localeCompare(String(b.created_at))).slice(0, opt.max || 5);
        empty = q.type === "qa" ? "質問を受け付けています" : "アイデアを受け付けています";
      } else {
        show = posts.filter(t => t.featured).sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
        empty = (q.type === "qa" ? "質問" : "アイデア") + `を受け付けています（${posts.length}件）`;
      }
      if (!show.length) { el.innerHTML = `<p class="res-empty">${empty}</p>`; return; }
      el.innerHTML = `<ul class="res-board${show.length === 1 ? " one" : ""}">` + show.map(t => `
        <li class="${t.answered ? "answered" : ""}"><p>${esc(t.body)}</p>
          <div class="meta"><span class="likes">${unit} ${t.likes || 0}</span>${t.answered ? '<span class="done">回答済み</span>' : ""}</div></li>`).join("") + "</ul>";
      return;
    }

    if (q.type === "text") {
      const groups = groupTexts(data.texts || []);
      if (!groups.length) { el.innerHTML = '<p class="res-empty">回答を待っています</p>'; return; }
      const view = opt.textView || q.text_view;
      if (view === "list") {
        groups.sort((a, b) => b.count - a.count || a.label.localeCompare(b.label, "ja"));
        el.innerHTML = '<ul class="res-list">' + groups.map(g =>
          `<li>${esc(g.label)}${g.count > 1 ? `<span class="cnt">×${g.count}</span>` : ""}</li>`).join("") + "</ul>";
      } else {
        const max = Math.max(...groups.map(g => g.count));
        // 位置が更新のたびに飛ばないよう、文字列から決まる順で並べる
        groups.sort((a, b) => hash(a.key) - hash(b.key));
        el.innerHTML = '<div class="res-cloud">' + groups.map(g => {
          const lv = max <= 1 ? 2 : 1 + Math.round(3 * (g.count - 1) / (max - 1));
          return `<span class="w${lv}" title="${g.count}件">${esc(g.label)}</span>`;
        }).join("") + "</div>";
      }
      return;
    }

    if (q.type === "rating") {
      const rows = (data.options || []).map(o => ({ v: Number(o.label) || 0, n: Number(o.count) || 0 })).sort((a, b) => b.v - a.v);
      const total = rows.reduce((t, r) => t + r.n, 0);
      const avg = total ? rows.reduce((t, r) => t + r.v * r.n, 0) / total : 0;
      const max = rows.length ? Math.max(...rows.map(r => r.v)) : 5;
      const top = Math.max(1, ...rows.map(r => r.n));
      el.innerHTML = `<div class="res-rating">
        <div class="avg"><span class="num">${total ? avg.toFixed(1) : "—"}</span><span class="of">/ ${max}</span>
          <div class="stars" aria-hidden="true">${starBar(avg, max)}</div><div class="cap">平均</div></div>
        <ol class="res-bars${opt.inline ? " inline" : ""}">${rows.map(r => `
          <li class="res-bar${r.n > 0 && r.n === top ? " lead" : ""}">
            <div class="row"><span class="label">★${r.v}</span><span class="value">${total ? Math.round(100 * r.n / total) : 0}<small>%</small><small>${r.n}票</small></span></div>
            <div class="track"><div class="fill" style="width:${(100 * r.n / top).toFixed(1)}%"></div></div></li>`).join("")}
        </ol></div>`;
      if (opt.fit) fitBox(el);
      return;
    }

    let rows = (data.options || []).map(o => ({ ...o }));
    const isRank = q.type === "rank";
    const totalVotes = rows.reduce((t, r) => t + (Number(r.count) || 0), 0);   // 全投票数
    const maxPoints = isRank ? voters * q.rank_count : 0;
    rows.forEach(r => {
      r.value = Number(isRank ? r.points : r.count) || 0;
      // 割合は「全投票数に対する割合」（複数選択でも合計100%）。順位付けは満点に対する得点率
      r.pct = isRank ? (maxPoints ? (100 * r.value) / maxPoints : 0) : (totalVotes ? (100 * r.value) / totalVotes : 0);
    });
    const sortMode = isRank ? "desc" : (opt.sortMode || q.sort_mode);
    if (sortMode === "desc") rows.sort((a, b) => b.value - a.value || a.sort_order - b.sort_order);
    const top = Math.max(0, ...rows.map(r => r.value));
    const revealed = q.quiz && q.reveal;

    const bar = (r, i) => {
      // 選択肢を作り込む形式では、割合と件数を常に同時に表示する
      const val = isRank
        ? `${r.value}<small>点</small><small>1位 ${r.first}人</small>`
        : `${Math.round(r.pct)}<small>%</small><small>${r.value}票</small>`;
      const w = top ? (100 * r.value) / top : 0;              // 最多の選択肢をいっぱいに描く
      const rankNo = sortMode === "desc" ? `<span class="rank-no">${i + 1}位</span>` : "";
      const ok = revealed && r.correct === true;
      return `<li class="res-bar${r.value > 0 && r.value === top && !revealed ? " lead" : ""}${ok ? " correct" : ""}${r.user_added ? " added" : ""}">
        <div class="row"><span class="label">${rankNo}${ok ? '<span class="ok" aria-label="正解">✓</span>' : ""}${esc(r.label)}</span><span class="value">${val}</span></div>
        <div class="track"><div class="fill" style="width:${w.toFixed(1)}%"></div></div></li>`;
    };
    const draw = (list, rest) => {
      el.innerHTML = `<ol class="res-bars${opt.inline ? " inline" : ""}${revealed ? " revealed" : ""}">` + list.map(bar).join("") +
        (rest ? `<li class="res-more">ほか ${rest.n} 項目（計 ${rest.votes}票・${Math.round(totalVotes ? 100 * rest.votes / totalVotes : 0)}%）</li>` : "") + "</ol>";
    };
    draw(rows);
    // 枠に全選択肢が入るよう文字を自動で縮める。最小まで縮めても入らないとき（回答者が選択肢を多数追加した場合など）は
    // 票の多い順に入るだけ表示し、残りを「ほか n 項目」にまとめる
    if (opt.fit && !fitBox(el)) {
      const sorted = rows.slice().sort((a, b) => b.value - a.value || a.sort_order - b.sort_order);
      for (let k = sorted.length - 1; k >= 1; k--) {
        const restRows = sorted.slice(k);
        draw(sorted.slice(0, k), { n: restRows.length, votes: restRows.reduce((t, r) => t + r.value, 0) });
        if (fitBox(el, true)) break;
      }
    }
  }

  // 要素の中身が高さに収まるまで文字を縮める（1.0倍〜最小0.5倍）。収まれば true
  function fitBox(el, keep) {
    let f = keep ? parseFloat(el.style.fontSize) || 0.5 : 1;
    if (!keep) el.style.fontSize = "";
    const fits = () => el.scrollHeight <= el.clientHeight + 1;
    while (!fits() && f > 0.5) { f = Math.round((f - 0.05) * 100) / 100; el.style.fontSize = f + "em"; }
    return fits();
  }

  // 投票数のまとめ（右上の表示用）
  function tally(data) {
    const q = data.question || {};
    if (["single", "multiple", "rating"].includes(q.type)) {
      const total = (data.options || []).reduce((t, o) => t + (Number(o.count) || 0), 0);
      return { n: total, unit: "票", label: "全投票数", sub: `回答者 ${data.voters}人` };
    }
    if (["text", "qa", "ideas"].includes(q.type)) return { n: data.voters, unit: "人", label: "投稿者", sub: "" };
    return { n: data.voters, unit: "人", label: "回答者", sub: "" };
  }

  function starBar(avg, max) {
    let h = "";
    for (let i = 1; i <= max; i++) {
      const f = Math.max(0, Math.min(1, avg - (i - 1)));
      h += `<span class="st"><span style="width:${(f * 100).toFixed(0)}%">★</span>★</span>`;
    }
    return h;
  }

  const tsu = n => n < 10 ? `${n}つ` : `${n}個`;   // 「10つ」とならないように
  function typeLabel(q) {
    if (q.type === "qa") return "会場からの質問";
    if (q.type === "ideas") return "アイデア募集";
    if (q.type === "rating") return `星で評価（1〜${q.rank_count || (q.options || []).length || 5}）`;
    if (q.type === "text") return q.text_view === "list" ? "自由意見" : q.text_view === "cloud" ? "ワードクラウド（短い言葉で）" : "自由記載";
    if (q.quiz) return "クイズ（" + (q.type === "multiple" ? "当てはまるものをすべて選ぶ" : "1つ選ぶ") + "）" + (q.reveal ? "　正解を公開中" : "");
    if (q.type === "single") return "1つ選ぶ";
    if (q.type === "multiple") return q.min_select === q.max_select ? `${tsu(q.max_select)}選ぶ` : `${tsu(q.max_select)}まで選ぶ`;
    if (q.type === "rank") return `上位${tsu(q.rank_count)}に順位をつける`;
    return "自由記載";
  }

  function baseUrl() {
    return location.href.replace(/[^/]*(\?.*)?(#.*)?$/, "");
  }

  // ---------- 配色（スライドのデザインに合わせて選ぶ） ----------
  const PALETTES = {
    teal:   { name: "ティール",   main: "#0b6f6a", deep: "#08504d", pale: "#d8ecea", dmain: "#3fb3a8", ddeep: "#7fd6cc" },
    navy:   { name: "ネイビー",   main: "#1f4e8c", deep: "#163a69", pale: "#dbe6f4", dmain: "#6d9ee0", ddeep: "#a9c6f0" },
    sky:    { name: "スカイ",     main: "#0e7fb8", deep: "#0a5f8a", pale: "#d7edf8", dmain: "#5cb8e6", ddeep: "#9dd5f1" },
    forest: { name: "フォレスト", main: "#3b7a3a", deep: "#2b5a2a", pale: "#e0eedd", dmain: "#7cc07a", ddeep: "#ace0aa" },
    wine:   { name: "ワイン",     main: "#8c2f4a", deep: "#6a2238", pale: "#f3dde4", dmain: "#e07b98", ddeep: "#f1b0c3" },
    orange: { name: "オレンジ",   main: "#c45a12", deep: "#94430c", pale: "#f9e4d4", dmain: "#f0964f", ddeep: "#f7c193" },
    purple: { name: "パープル",   main: "#5b4a9b", deep: "#43367a", pale: "#e6e2f4", dmain: "#a08fe0", ddeep: "#c9bff0" },
    gray:   { name: "グレー",     main: "#4a5560", deep: "#2f363d", pale: "#e3e7ea", dmain: "#a3b0bc", ddeep: "#d0d8df" }
  };
  function applyPalette(el, key, dark) {
    const p = PALETTES[key] || PALETTES.teal;
    el.style.setProperty("--teal", dark ? p.dmain : p.main);
    el.style.setProperty("--teal-deep", dark ? p.ddeep : p.deep);
    el.style.setProperty("--teal-pale", dark ? "rgba(255,255,255,.12)" : p.pale);
  }
  // 背景画像を敷く。overlay：light＝白で薄める／dark＝濃紺で沈める（文字を白に）／none
  function applyBackground(el, dataUrl, overlay) {
    if (!dataUrl) { el.style.backgroundImage = ""; return; }
    const veil = overlay === "dark" ? "rgba(12,24,34,.70)" : overlay === "none" ? "rgba(0,0,0,0)" : "rgba(255,255,255,.84)";
    el.style.backgroundImage = `linear-gradient(${veil}, ${veil}), url("${dataUrl}")`;
    el.style.backgroundSize = "cover"; el.style.backgroundPosition = "center";
  }
  // 画像を縮小して JPEG の data URL にする（データベースに入れられる大きさまで）
  function compressImage(file, maxW = 1920) {
    return new Promise((res, rej) => {
      const img = new Image(), url = URL.createObjectURL(file);
      img.onload = () => {
        const r = Math.min(1, maxW / img.width), c = document.createElement("canvas");
        c.width = Math.round(img.width * r); c.height = Math.round(img.height * r);
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
        let q = 0.82, d = c.toDataURL("image/jpeg", q);
        while (d.length > 1400000 && q > 0.3) { q -= 0.1; d = c.toDataURL("image/jpeg", q); }
        URL.revokeObjectURL(url);
        d.length > 1400000 ? rej(new Error("画像が大きすぎます")) : res(d);
      };
      img.onerror = () => rej(new Error("画像を読み込めませんでした"));
      img.src = url;
    });
  }
  function qrSvg(text) {
    const qr = qrcode(0, "M"); qr.addData(text); qr.make();
    return qr.createSvgTag({ cellSize: 6, margin: 2, scalable: true });
  }

  // ---------- PowerPoint アドインの設定ファイル（公開先URLを埋め込んで作る） ----------
  function manifestXml() {
    const base = baseUrl().replace(/&/g, "&amp;");
    const id = cfg.ADDIN_ID || "4b52dc98-0b83-40b0-9bd1-2a2d3261a063";
    return `<?xml version="1.0" encoding="UTF-8"?>
<OfficeApp xmlns="http://schemas.microsoft.com/office/appforoffice/1.1"
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
           xsi:type="ContentApp">
  <Id>${id}</Id>
  <Version>1.0.0.0</Version>
  <ProviderName>Symposium Vote</ProviderName>
  <DefaultLocale>ja-JP</DefaultLocale>
  <DisplayName DefaultValue="投票結果（自前）" />
  <Description DefaultValue="会場投票の作成とスライドへのリアルタイム表示" />
  <IconUrl DefaultValue="${base}assets/icon-32.png" />
  <HighResolutionIconUrl DefaultValue="${base}assets/icon-64.png" />
  <SupportUrl DefaultValue="${base}install.html" />
  <AppDomains>
    <AppDomain>${location.origin}</AppDomain>
  </AppDomains>
  <Hosts>
    <Host Name="Presentation" />
  </Hosts>
  <DefaultSettings>
    <SourceLocation DefaultValue="${base}addin.html" />
    <RequestedWidth>960</RequestedWidth>
    <RequestedHeight>540</RequestedHeight>
  </DefaultSettings>
  <Permissions>ReadWriteDocument</Permissions>
  <AllowSnapshot>true</AllowSnapshot>
</OfficeApp>
`;
  }

  window.VoteApp = { sb, rpc, errText, esc, renderResults, typeLabel, baseUrl, cfg, tally, fitBox, tsu, PALETTES, applyPalette, applyBackground, compressImage, qrSvg, manifestXml };
})();
