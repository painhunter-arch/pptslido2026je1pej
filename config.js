/* Supabase の「Project Settings → API」に表示される2つの値を貼り付ける。
   anon key は公開して使う前提の鍵（データの保護はデータベース側の権限設定で行っている）。
   service_role key は絶対にここへ書かないこと。 */
window.VOTE_CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT.supabase.co",
  SUPABASE_ANON_KEY: "YOUR-ANON-KEY",

  // 聴衆の端末が「いまの質問」を確認する間隔（ミリ秒）。参加者が多いほど長めに
  PARTICIPANT_POLL_MS: 3000,
  // 投影画面が結果を更新する間隔（ミリ秒）
  PROJECTOR_POLL_MS: 2000
};
