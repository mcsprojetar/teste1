# Conferência de Mercadorias — instalação

Nada aqui está conectado ou publicado ainda. Você precisa criar as contas e colar as chaves.

## 1. Banco (Supabase, plano gratuito serve para começar)
1. Crie um projeto em supabase.com (região São Paulo).
2. SQL Editor → cole `supabase/schema.sql` → Run.
3. Project Settings → API: copie **Project URL** e **anon key**.
   Nunca use a `service_role` no navegador.
4. Authentication → URL Configuration: informe o endereço onde o site ficará (para recuperar senha).
5. Authentication → Providers → Email: desative "Confirm email" só se quiser criar usuários manualmente.

## 2. Primeiro administrador
1. Authentication → Users → **Add user** (e-mail e senha forte, marque "Auto confirm").
2. SQL Editor:
   ```sql
   update perfis set papel='admin' where id = (select id from auth.users where email='SEU@EMAIL');
   ```
3. Não existe senha fixa no código. Funcionários: crie em Add user; o padrão é `funcionario` sem ver preço de venda.
   Para liberar venda: `update perfis set ver_venda=true where id='...';`
   Para bloquear: `update perfis set ativo=false where id='...';`

## 3. Publicar
Edite `index.html` (URL e anon key no topo do script) e envie o arquivo para Netlify, Vercel ou Cloudflare Pages (arraste a pasta).

## 4. Testes obrigatórios antes de usar
- Entre como funcionário, abra o console do navegador e rode `await sb.from('financeiro').select('*')`: deve vir vazio.
- Rode `await sb.rpc('resumo',{p_ini:'2026-01-01',p_fim:'2026-12-31'})`: deve dar "Acesso negado".
- Clique duas vezes em "Salvar": só um registro é criado.
- Finalize uma conferência como funcionário e tente editá-la: deve ser bloqueado.

## 5. Backup
Supabase Pro tem backups diários e restauração. No plano gratuito, rode periodicamente `pg_dump` (Database → Connection string) e guarde o arquivo fora do Supabase.

## O que ainda falta (próximas etapas)
Exportação Excel e PDF, gráficos, comparativo com período anterior, clique nos indicadores para ver registros, tela de usuários e de histórico de alterações (a tabela `auditoria` já grava tudo), notificação de divergências e itens da nota fiscal linha a linha.
