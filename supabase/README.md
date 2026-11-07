# Backend da USEI (Supabase)

Por que Supabase: no plano grátis ele já traz banco de dados (Postgres),
login com e-mail e senha (e Google, se quisermos), armazenamento
**privado** para documento e selfie, chat em tempo real e funções no
servidor. No Firebase grátis isso não é mais possível: o armazenamento de
arquivos passou a exigir cartão de crédito (plano Blaze).

Limites do plano grátis (conferidos em supabase.com/pricing, nov/2026):
banco 500 MB, arquivos 1 GB, 5 GB de tráfego/mês, 50 mil usuários ativos/mês,
2 projetos. Projeto parado por 1 semana pausa sozinho e volta com um clique
no painel. Para o lançamento, vale avaliar o plano Pro.

As fotos dos anúncios continuam no Cloudinary (rápido e com zoom em alta).
Só documento e selfie vão para o armazenamento privado do Supabase.

## Passo a passo (5 minutos, uma vez só)

1. Crie a conta em https://supabase.com e clique em **New project**.
   - Nome: `usei`
   - Região: **South America (São Paulo)**
   - Senha do banco: gere uma forte e guarde no seu gerenciador de senhas.
     **Não mande essa senha para ninguém, nem para o Claude.**
2. Quando o projeto terminar de criar: **SQL Editor → New query**, cole o
   arquivo `schema.sql` inteiro e clique em **Run**. Deve aparecer
   "Success. No rows returned".
3. **Authentication → Sign In / Providers → Email**: durante a Alpha,
   desligue **Confirm email**. O e-mail grátis do Supabase manda só
   poucas mensagens por hora e travaria os testes. Antes do Beta, ligamos
   de novo com um provedor de e-mail próprio.
4. **Authentication → URL Configuration**:
   - Site URL: `https://useiapp.github.io/usei/app/`
   - Redirect URLs: adicione `https://useiapp.github.io/usei/app/**`
5. **Project Settings → API Keys** (ou **Data API**): copie e mande para o
   Claude só estas duas coisas, que são públicas e vão no código do site:
   - **Project URL** (algo como `https://abcd1234.supabase.co`)
   - **Publishable key** (começa com `sb_publishable_`) ou, em projetos
     mais antigos, a **anon public key**.
   **Nunca mande** a `secret key` / `service_role` nem a senha do banco.
6. Depois que o app novo estiver ligado ao Supabase, crie sua conta nele e
   rode no SQL Editor a linha do final do `schema.sql` para virar admin.

## O que fica no servidor (e não pode ser burlado pelo navegador)

- Valor do pedido, desconto do cupom e taxa da plataforma (`create_order`).
- Mudança de status do pedido, transação e reembolso (`set_order_status`).
- Envio e aprovação da verificação de vendedor (`submit_verification`,
  `review_verification`).
- Banimento, taxa por cliente, anotações e cargo (`admin_update_profile`).
- ID sequencial da conta (`USEI-00001`, `USEI-00002`, ...).
