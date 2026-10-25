-- =====================================================================
--  シンポジウム11 の質問を登録（「1012_医療薬たたき台_修正1」のスライド12・16・18・25・26 より）
--  ※ 管理画面で参加コード S11 のプロジェクトを作成してから実行すると、そのプロジェクトに質問が入る
--  01_schema.sql の後に1回だけ実行する。
--  参加コードは 'S11'。変更する場合は2か所の 'S11' を書き換える。
-- =====================================================================

-- ※ 管理画面の「プロジェクトを作成」を使う場合、このファイルは不要です。
--   このファイルで作ったプロジェクトには暗号がないため、管理画面で「暗号を再発行」してから共同編集者に伝えてください。
insert into public.events(code, title, project_no)
values ('S11', '症例ディスカッションで共創する難治性がん疼痛マネジメント',
        'P-' || lpad(nextval('public.project_no_seq')::text, 4, '0'))
on conflict (code) do nothing;

do $$
declare
  v_event uuid := (select id from public.events where code = 'S11');
  v_q     uuid;
begin
  -- Q0（スライド12→13）ワードクラウド・ひとりで複数投稿可
  insert into public.questions(event_id, qkey, sort_order, type, title, max_text_answers, max_text_length, text_view)
  values (v_event, 'Q0', 0, 'text', '疼痛マネジメントを考えるために、まず何を確認したいですか？', 3, 30, 'cloud')
  on conflict (event_id, qkey) do nothing;

  -- Q1（スライド16→17）複数選択・2つまで
  insert into public.questions(event_id, qkey, sort_order, type, title, min_select, max_select, sort_mode)
  values (v_event, 'Q1', 1, 'multiple', 'この時点で、あなたが最も重要だと考える問題を2つまで選んでください', 1, 2, 'original')
  on conflict (event_id, qkey) do nothing
  returning id into v_q;
  if v_q is not null then
    insert into public.options(question_id, sort_order, label) values
      (v_q, 1, 'オピオイド量が不足している'),
      (v_q, 2, '神経障害性疼痛への対応が不十分'),
      (v_q, 3, '体動時痛への対応が不十分'),
      (v_q, 4, '腫瘍進行そのものへの対応が必要'),
      (v_q, 5, '疼痛による生活機能の低下'),
      (v_q, 6, 'その他');
  end if;

  -- Q2（スライド18→19）単一選択
  v_q := null;
  insert into public.questions(event_id, qkey, sort_order, type, title)
  values (v_event, 'Q2', 2, 'single', 'そのうち、最初に介入すべき問題はどれですか')
  on conflict (event_id, qkey) do nothing
  returning id into v_q;
  if v_q is not null then
    insert into public.options(question_id, sort_order, label) values
      (v_q, 1, 'オピオイド量が不足している'),
      (v_q, 2, '神経障害性疼痛への対応が不十分'),
      (v_q, 3, '体動時痛への対応が不十分'),
      (v_q, 4, '腫瘍進行そのものへの対応が必要'),
      (v_q, 5, '疼痛による生活機能の低下'),
      (v_q, 6, 'その他');
  end if;

  -- Q3（スライド26→27）ワードクラウド
  insert into public.questions(event_id, qkey, sort_order, type, title, max_text_answers, max_text_length, text_view)
  values (v_event, 'Q3', 3, 'text', 'この患者さんが自宅で生活を続けるために、さらに何を確認したいですか？', 3, 30, 'cloud')
  on conflict (event_id, qkey) do nothing;

  -- Q4（スライド25→28）単一選択
  v_q := null;
  insert into public.questions(event_id, qkey, sort_order, type, title, sort_mode)
  values (v_event, 'Q4', 4, 'single', 'この患者の退院を妨げる最大の障壁は何だと思いますか？', 'desc')
  on conflict (event_id, qkey) do nothing
  returning id into v_q;
  if v_q is not null then
    insert into public.options(question_id, sort_order, label) values
      (v_q, 1, '薬剤管理'),
      (v_q, 2, '家族の支援体制・負担'),
      (v_q, 3, '医療用麻薬・薬剤の供給体制'),
      (v_q, 4, '病院と地域の連携'),
      (v_q, 5, '患者本人が薬剤や症状に対応できる支援体制'),
      (v_q, 6, 'その他');
  end if;

  -- TEST（リハーサル用）順位付け。本番前に削除してよい
  v_q := null;
  insert into public.questions(event_id, qkey, sort_order, type, title, rank_count, sort_mode)
  values (v_event, 'TEST', 99, 'rank', '【動作確認】退院支援で優先したい順に3つ選んでください', 3, 'desc')
  on conflict (event_id, qkey) do nothing
  returning id into v_q;
  if v_q is not null then
    insert into public.options(question_id, sort_order, label) values
      (v_q, 1, '疼痛コントロール'),
      (v_q, 2, '服薬の自己管理'),
      (v_q, 3, '家族の負担軽減'),
      (v_q, 4, '在宅チームへの情報共有'),
      (v_q, 5, '就労の継続');
  end if;
end $$;

-- 投影画面の鍵を確認（管理画面にも表示される）
select project_no, code, title from public.events where code = 'S11';
