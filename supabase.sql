-- Cole este arquivo inteiro em: Supabase > SQL Editor > New query > Run

create table if not exists public.orcamentos (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),   -- vai no link enviado ao cliente
  owner uuid not null default auth.uid() references auth.users(id),
  numero int,
  data date default current_date,
  cliente text,
  contato text,
  tipo text,
  descricao text,
  itens jsonb not null default '[]',
  total numeric(12,2) not null default 0,
  empresa jsonb not null default '{}',                      -- nome, CNPJ, telefone, e-mail (aparecem na página do cliente)
  status text not null default 'Pendente'
    check (status in ('Pendente','Em revisão','Aprovado','Recusado')),
  nota text,
  rev int not null default 0,
  pago numeric(12,2) not null default 0,
  respondido_em timestamptz,
  created_at timestamptz not null default now()
);

alter table public.orcamentos enable row level security;

-- Só o dono (você, logado) lê e altera os próprios orçamentos
drop policy if exists dono on public.orcamentos;
create policy dono on public.orcamentos for all
  using (owner = auth.uid()) with check (owner = auth.uid());

-- Página do cliente: lê UM orçamento pelo token do link (sem login)
create or replace function public.orcamento_publico(p_token uuid)
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'numero', numero, 'data', data, 'cliente', cliente, 'contato', contato,
    'descricao', descricao, 'itens', itens, 'total', total, 'empresa', empresa,
    'status', status, 'rev', rev, 'nota', nota)
  from public.orcamentos where token = p_token
$$;

-- Página do cliente: registra Aprovado, Recusado ou Em revisão (só enquanto estiver Pendente ou Em revisão)
create or replace function public.responder_orcamento(p_token uuid, p_resposta text, p_nota text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s text;
begin
  if p_resposta not in ('Aprovado','Recusado','Em revisão') then return 'invalido'; end if;
  update public.orcamentos
     set status = p_resposta, nota = left(p_nota, 1000), respondido_em = now()
   where token = p_token and status in ('Pendente','Em revisão')
   returning status into s;
  return coalesce(s, 'indisponivel');
end $$;

revoke all on function public.orcamento_publico(uuid) from public;
revoke all on function public.responder_orcamento(uuid, text, text) from public;
grant execute on function public.orcamento_publico(uuid) to anon, authenticated;
grant execute on function public.responder_orcamento(uuid, text, text) to anon, authenticated;

-- Dados do app (clientes, produtos, serviços, empresa) guardados por usuário
create table if not exists public.dados (
  owner uuid primary key default auth.uid() references auth.users(id),
  conteudo jsonb not null default '{}',
  atualizado timestamptz not null default now()
);
alter table public.dados enable row level security;
drop policy if exists dono on public.dados;
create policy dono on public.dados for all
  using (owner = auth.uid()) with check (owner = auth.uid());

-- ===== Solicitações feitas pelos clientes (página pública solicitar.html) =====
create table if not exists public.perfil_publico (
  owner uuid primary key references auth.users(id),
  nome text, tel text, logo text
);
alter table public.perfil_publico enable row level security;
drop policy if exists dono on public.perfil_publico;
create policy dono on public.perfil_publico for all
  using (owner = auth.uid()) with check (owner = auth.uid());

create table if not exists public.solicitacoes (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id),
  protocolo bigint generated always as identity,
  tipo text not null check (tipo in ('Serviço','Atendimento','Orçamento','Informações')),
  status text not null default 'Recebida' check (status in ('Recebida','Em andamento','Atendida')),
  doc text, nome text, contato text, tel text, email text,
  cep text, rua text, numero text, complemento text, bairro text, cidade text, uf text,
  descricao text,
  agendamento timestamptz,
  visto boolean not null default false,
  cliente_criado boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.solicitacoes enable row level security;
drop policy if exists dono on public.solicitacoes;
create policy dono on public.solicitacoes for all
  using (owner = auth.uid()) with check (owner = auth.uid());

-- Página pública: dados da empresa (nome, telefone, logo)
create or replace function public.empresa_publica(p_owner uuid)
returns json language sql security definer set search_path = public as $$
  select json_build_object('nome', nome, 'tel', tel, 'logo', logo)
  from public.perfil_publico where owner = p_owner
$$;

-- Página pública: cria a solicitação (sem login), com validação e limite de 40 por hora
create or replace function public.criar_solicitacao(p_owner uuid, p jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if coalesce(p->>'website','') <> '' then return 0; end if;  -- campo-armadilha contra robôs
  if not exists (select 1 from public.perfil_publico where owner = p_owner) then raise exception 'empresa'; end if;
  if (select count(*) from public.solicitacoes where owner = p_owner and created_at > now() - interval '1 hour') >= 40
    then raise exception 'limite'; end if;
  if coalesce(p->>'tipo','') not in ('Serviço','Atendimento','Orçamento','Informações')
     or coalesce(trim(p->>'nome'),'') = '' or coalesce(trim(p->>'descricao'),'') = ''
    then raise exception 'invalido'; end if;
  insert into public.solicitacoes (owner,tipo,doc,nome,contato,tel,email,cep,rua,numero,complemento,bairro,cidade,uf,descricao)
  values (p_owner,p->>'tipo',left(p->>'doc',20),left(p->>'nome',160),left(p->>'contato',120),left(p->>'tel',30),
          left(p->>'email',160),left(p->>'cep',10),left(p->>'rua',200),left(p->>'numero',20),left(p->>'complemento',120),
          left(p->>'bairro',100),left(p->>'cidade',100),left(p->>'uf',2),left(p->>'descricao',3000))
  returning protocolo into n;
  return n;
end $$;

revoke all on function public.empresa_publica(uuid) from public;
revoke all on function public.criar_solicitacao(uuid, jsonb) from public;
grant execute on function public.empresa_publica(uuid) to anon, authenticated;
grant execute on function public.criar_solicitacao(uuid, jsonb) to anon, authenticated;
