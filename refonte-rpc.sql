-- ═══════════════════════════════════════════════════════════════
--  PitStock — refonte-rpc.sql
--  Fonctions atomiques appelées par l'app via supabase.rpc(...).
--  Corrige le bug d'atomicité : avant, un achat lot faisait 2 appels
--  séparés (achats, puis articles) — si le 2ᵉ plantait, achat fantôme
--  sans voiture. Ici, tout passe dans UNE fonction = UNE transaction :
--  si une ligne échoue, tout est annulé, rien n'est à moitié écrit.
--
--  À lancer APRÈS sql-creation-complete.sql et import-catalogue.sql.
-- ═══════════════════════════════════════════════════════════════

-- ═══ 1. creer_achat — voiture seule OU lot, même fonction ═══
-- p_articles : tableau JSON, une entrée par voiture à créer.
--   [{"ref":"75899","etat":"nu","minifig":true,"cout_achat":15.00,
--     "valeur_estimee":null,"etiquette":null,"note":null}, ...]
-- Pour une voiture seule : un tableau à un seul élément.
create or replace function creer_achat(
  p_nature       nature,
  p_montant_paye numeric,
  p_proprietaire proprietaire,
  p_payeur       payeur,
  p_plateforme   plateforme,
  p_articles     jsonb
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_achat_id    bigint;
  v_article     jsonb;
  v_article_ids bigint[] := '{}';
  v_new_id      bigint;
begin
  if p_articles is null or jsonb_array_length(p_articles) = 0 then
    raise exception 'Un achat doit contenir au moins une voiture.';
  end if;
  if p_montant_paye is null or p_montant_paye <= 0 then
    raise exception 'Le montant payé doit être positif.';
  end if;

  insert into achats (nature, montant_paye, proprietaire, payeur, plateforme)
  values (p_nature, p_montant_paye, p_proprietaire, p_payeur, p_plateforme)
  returning id into v_achat_id;

  for v_article in select * from jsonb_array_elements(p_articles)
  loop
    if v_article->>'ref' is null then
      raise exception 'Chaque voiture doit avoir une référence.';
    end if;

    insert into articles (ref, etat, minifig, note, proprietaire, achat_id, cout_achat, valeur_estimee, etiquette)
    values (
      v_article->>'ref',
      coalesce((v_article->>'etat')::etat, 'nu'),
      coalesce((v_article->>'minifig')::boolean, false),
      nullif(v_article->>'note', ''),
      p_proprietaire,
      v_achat_id,
      (v_article->>'cout_achat')::numeric,
      (v_article->>'valeur_estimee')::numeric,
      coalesce((v_article->>'etiquette')::etiquette, 'estime_max')
    )
    returning id into v_new_id;

    v_article_ids := array_append(v_article_ids, v_new_id);
  end loop;

  -- Le trigger t_achat_compte_courant s'est déjà déclenché sur l'insert ci-dessus
  -- (règle §8) : à ce stade le compte courant de Jojo est déjà à jour.
  return jsonb_build_object('achat_id', v_achat_id, 'article_ids', v_article_ids);
end $$;

grant execute on function creer_achat(nature, numeric, proprietaire, payeur, plateforme, jsonb) to authenticated;


-- ═══ 2. creer_vente — une voiture qui part ═══
-- Ajoute une garde qu'il n'y avait pas avant : impossible de vendre
-- deux fois la même voiture (le double-clic qui coûte cher).
create or replace function creer_vente(
  p_article_id       bigint,
  p_montant_encaisse numeric,
  p_encaisse_par     encaisse_par,
  p_plateforme       plateforme
) returns bigint
language plpgsql
set search_path = public
as $$
declare
  v_statut  statut;
  v_vente_id bigint;
begin
  if p_montant_encaisse is null or p_montant_encaisse <= 0 then
    raise exception 'Le montant encaissé doit être positif.';
  end if;

  select statut into v_statut from articles where id = p_article_id;
  if v_statut is null then
    raise exception 'Cette voiture n''existe pas.';
  end if;
  if v_statut = 'vendu' then
    raise exception 'Cette voiture a déjà été vendue.';
  end if;

  insert into ventes (article_id, montant_encaisse, encaisse_par, plateforme)
  values (p_article_id, p_montant_encaisse, p_encaisse_par, p_plateforme)
  returning id into v_vente_id;

  -- Le trigger t_vente a déjà exécuté les 8 effets en chaîne (§12) :
  -- statut, CUMP figé, prix_reference, compte courant Jojo si JM.
  return v_vente_id;
end $$;

grant execute on function creer_vente(bigint, numeric, encaisse_par, plateforme) to authenticated;


-- ═══ 3. creer_vente_groupee — plusieurs voitures parties dans la même annonce ═══
-- Cas du set à 2-3 voitures revendu en bloc (décision du 31/08) : un seul montant
-- encaissé, réparti entre les voitures au prorata de leur valeur estimée —
-- exactement la même clé de répartition qu'à l'achat d'un lot (§10).
-- L'arrondi est absorbé sur la dernière voiture, jamais perdu (cf. achat lot).
create or replace function creer_vente_groupee(
  p_article_ids  bigint[],
  p_montant_total numeric,
  p_encaisse_par  encaisse_par,
  p_plateforme    plateforme
) returns bigint[]
language plpgsql
set search_path = public
as $$
declare
  v_n          int := coalesce(array_length(p_article_ids, 1), 0);
  v_total_poids numeric;
  v_poids      numeric;
  v_montant    numeric;
  v_reste      numeric := p_montant_total;
  v_article_id bigint;
  v_statut     statut;
  v_vente_id   bigint;
  v_ids        bigint[] := '{}';
  i            int := 0;
begin
  if v_n < 2 then
    raise exception 'Une vente groupée porte sur au moins 2 voitures — utilise creer_vente pour une seule.';
  end if;
  if p_montant_total is null or p_montant_total <= 0 then
    raise exception 'Le montant encaissé doit être positif.';
  end if;

  -- Garde : aucune des voitures n'est déjà vendue
  select statut into v_statut from articles where id = any(p_article_ids) and statut = 'vendu' limit 1;
  if v_statut is not null then
    raise exception 'Au moins une de ces voitures a déjà été vendue.';
  end if;

  select coalesce(sum(coalesce(valeur_estimee, cout_achat, 0)), 0) into v_total_poids
  from articles where id = any(p_article_ids);
  if v_total_poids = 0 then
    raise exception 'Impossible de répartir : aucune voiture n''a de valeur estimée ni de coût d''achat.';
  end if;

  foreach v_article_id in array p_article_ids loop
    i := i + 1;
    select coalesce(valeur_estimee, cout_achat, 0) into v_poids from articles where id = v_article_id;

    if i = v_n then
      v_montant := round(v_reste, 2);                                  -- absorbe l'arrondi
    else
      v_montant := round(p_montant_total * v_poids / v_total_poids, 2);
      v_reste   := v_reste - v_montant;
    end if;

    insert into ventes (article_id, montant_encaisse, encaisse_par, plateforme)
    values (v_article_id, v_montant, p_encaisse_par, p_plateforme)
    returning id into v_vente_id;

    v_ids := array_append(v_ids, v_vente_id);
  end loop;

  return v_ids;
end $$;

grant execute on function creer_vente_groupee(bigint[], numeric, encaisse_par, plateforme) to authenticated;


-- ─── Contrôle : les 3 fonctions doivent apparaître ───
select proname, pronargs from pg_proc
where proname in ('creer_achat','creer_vente','creer_vente_groupee')
order by proname;
-- Attendu : 3 lignes
