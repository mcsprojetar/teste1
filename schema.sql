-- Execute inteiro no Supabase: SQL Editor > New query > Run
create type papel as enum ('admin','funcionario');
create type status_conf as enum ('pendente','em_andamento','conferido','divergente');

create table perfis (
  id uuid primary key references auth.users on delete cascade,
  nome text not null,
  papel papel not null default 'funcionario',
  ver_venda boolean not null default false,   -- admin autoriza
  ativo boolean not null default true
);

create or replace function eh_admin() returns boolean
language sql stable security definer set search_path=public as
$$ select exists(select 1 from perfis where id=auth.uid() and papel='admin' and ativo) $$;
create or replace function eh_ativo() returns boolean
language sql stable security definer set search_path=public as
$$ select exists(select 1 from perfis where id=auth.uid() and ativo) $$;

create table fornecedores (id bigserial primary key, nome text unique not null, deleted_at timestamptz);

-- DADOS OPERACIONAIS (funcionários enxergam). NENHUM valor em dinheiro aqui.
create table mercadorias (
  id bigserial primary key,
  numero bigint generated always as identity,
  token_envio uuid unique,                     -- evita duplicidade por clique repetido
  data_compra date not null,
  criado_em timestamptz not null default now(),
  descricao text not null, marca text,
  fornecedor_id bigint references fornecedores,
  quantidade numeric(14,3) not null check (quantidade>=0),
  unidade text not null default 'un',
  nota_fiscal text, qtd_nota numeric(14,3), qtd_recebida numeric(14,3),
  observacoes text, anexo_path text,
  status status_conf not null default 'pendente',
  criado_por uuid not null references perfis default auth.uid(),
  conferido_por uuid references perfis, conferido_em timestamptz,
  deleted_at timestamptz
);
create index on mercadorias (data_compra);
create index on mercadorias (fornecedor_id, status);

-- DADOS FINANCEIROS: tabela separada, SÓ admin acessa (RLS).
create table financeiro (
  mercadoria_id bigint primary key references mercadorias on delete cascade,
  valor_compra_unit numeric(14,4) not null default 0 check (valor_compra_unit>=0),
  valor_venda_unit  numeric(14,4) not null default 0 check (valor_venda_unit>=0)
);

create table auditoria (
  id bigserial primary key, em timestamptz default now(), usuario uuid default auth.uid(),
  tabela text, registro text, acao text, antes jsonb, depois jsonb
);
create or replace function audita() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into auditoria(tabela,registro,acao,antes,depois)
  values(tg_table_name, coalesce((to_jsonb(new)->>'id'),(to_jsonb(old)->>'id'),(to_jsonb(new)->>'mercadoria_id')),
         tg_op, case when tg_op<>'INSERT' then to_jsonb(old) end, case when tg_op<>'DELETE' then to_jsonb(new) end);
  return coalesce(new,old);
end $$;
create trigger a1 after insert or update or delete on mercadorias for each row execute function audita();
create trigger a2 after insert or update or delete on financeiro  for each row execute function audita();
create trigger a3 after insert or update or delete on perfis       for each row execute function audita();

-- Registros conferidos só o admin altera
create or replace function trava_conferido() returns trigger language plpgsql as $$
begin
  if old.status='conferido' and not eh_admin() then raise exception 'Registro finalizado: peça ao administrador.'; end if;
  if not eh_admin() then new.criado_por:=old.criado_por; new.deleted_at:=old.deleted_at; end if;
  return new;
end $$;
create trigger t1 before update on mercadorias for each row execute function trava_conferido();

-- RLS
alter table perfis enable row level security;
alter table fornecedores enable row level security;
alter table mercadorias enable row level security;
alter table financeiro enable row level security;
alter table auditoria enable row level security;

create policy p_perfis_ler  on perfis for select using (id=auth.uid() or eh_admin());
create policy p_perfis_adm  on perfis for all using (eh_admin()) with check (eh_admin());
create policy p_forn_ler    on fornecedores for select using (eh_ativo());
create policy p_forn_ins    on fornecedores for insert with check (eh_ativo());
create policy p_forn_adm    on fornecedores for update using (eh_admin());
create policy p_merc_ler    on mercadorias for select using (eh_ativo() and (deleted_at is null or eh_admin()));
create policy p_merc_ins    on mercadorias for insert with check (eh_ativo() and criado_por=auth.uid());
create policy p_merc_upd    on mercadorias for update using (eh_ativo() and (status<>'conferido' or eh_admin()));
create policy p_merc_del    on mercadorias for delete using (eh_admin());
create policy p_fin_admin   on financeiro for all using (eh_admin()) with check (eh_admin());
create policy p_aud_admin   on auditoria for select using (eh_admin());
-- Sem policy para funcionário em "financeiro" = acesso negado em API, SQL e DevTools.

-- Preço de venda: só para funcionário autorizado (nunca devolve custo)
create or replace function venda_autorizada() returns table(mercadoria_id bigint, valor_venda_unit numeric)
language sql stable security definer set search_path=public as $$
  select f.mercadoria_id, f.valor_venda_unit from financeiro f
  where exists(select 1 from perfis where id=auth.uid() and ativo and (ver_venda or papel='admin')) $$;

-- Resumo gerencial (admin): custo, receita potencial, lucro, margem
create or replace function resumo(p_ini date, p_fim date) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare r jsonb;
begin
  if not eh_admin() then raise exception 'Acesso negado'; end if;
  select jsonb_build_object(
    'compras', count(*), 'itens', coalesce(sum(m.quantidade),0),
    'custo', coalesce(sum(m.quantidade*f.valor_compra_unit),0),
    'receita_potencial', coalesce(sum(m.quantidade*f.valor_venda_unit),0),
    'lucro_potencial', coalesce(sum(m.quantidade*(f.valor_venda_unit-f.valor_compra_unit)),0),
    'divergentes', count(*) filter (where m.status='divergente'),
    'por_fornecedor', (select coalesce(jsonb_agg(x),'[]') from (
        select fo.nome, sum(m2.quantidade*f2.valor_compra_unit) total
        from mercadorias m2 join financeiro f2 on f2.mercadoria_id=m2.id
        left join fornecedores fo on fo.id=m2.fornecedor_id
        where m2.deleted_at is null and m2.data_compra between p_ini and p_fim
        group by fo.nome order by 2 desc) x))
  into r from mercadorias m left join financeiro f on f.mercadoria_id=m.id
  where m.deleted_at is null and m.data_compra between p_ini and p_fim;
  return r;
end $$;

-- Anexos (bucket privado): funcionários enviam e leem; sem acesso público
insert into storage.buckets(id,name,public) values('anexos','anexos',false) on conflict do nothing;
create policy anexos_rw on storage.objects for all
  using (bucket_id='anexos' and eh_ativo()) with check (bucket_id='anexos' and eh_ativo());

-- Novo usuário em auth.users vira funcionário sem permissões extras
create or replace function novo_usuario() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into perfis(id,nome) values(new.id, coalesce(new.raw_user_meta_data->>'nome', new.email)); return new; end $$;
create trigger on_auth_user after insert on auth.users for each row execute function novo_usuario();
