# usei
Usei. é uma plataforma de aluguel sob demanda que permite usar o que você precisa, apenas quando precisa. Sem comprar, sem desperdício. Precisou? Usei.

## Versões no ar

| Endereço | O que é |
|---|---|
| `https://useiapp.github.io/usei/app/` | **Alpha 2** — visual novo, páginas com URL própria, galeria com zoom. Em teste. |
| `https://useiapp.github.io/usei/catalogo.html` | Alpha 1 — versão anterior, ainda no ar até a Alpha 2 ser aprovada. |

## Alpha 2 (`app/index.html`)

Arquivo único (HTML + CSS + JS, sem framework), como o resto do projeto.

- **Visual:** inspirado na Apple (vidro fosco, tipografia grande, cartões amplos), no allu (UX de aluguel com período em dias, preço por período e selos de confiança) e no Mercado Livre (galeria com zoom). Fonte Instrument Sans (Google Fonts). Modo claro e escuro. No celular, os modais viram gaveta e a navegação fica numa cápsula de vidro embaixo.
- **Endereços (rotas):** cada página tem URL própria e o botão voltar funciona.
  `#/` início · `#/explorar?cat=&tipo=&q=` · `#/produto/<id>` · `#/pedidos` · `#/anuncios` · `#/verificacao` · `#/admin/<aba>` · `#/admin/usuarios/<id>`
- **Fotos:** o Cloudinary entrega cada foto no tamanho certo (`cld(url, largura)`): cartões leves e zoom em alta. No computador, lente + painel ampliado ao passar o mouse; no celular, carrossel de deslizar; em ambos, tela cheia com pinça, duplo toque/clique e roda do mouse.
- **Segurança:** todo texto vindo de usuário passa por `esc()` antes de ir para a tela, e links de imagem por `safeUrl()`.

## Backend

- **Hoje (Alpha 1 e Alpha 2):** Firebase — Authentication + Firestore (projeto `usei-b1b88`). Regras em `firestore.rules`, que precisam ser coladas no Console (Firestore Database → Regras → Publicar).
- **Próximo passo:** Supabase (Postgres + Auth + armazenamento privado + chat em tempo real), com o cálculo de pedido, cupom e taxa feito no servidor. Estrutura pronta em `supabase/schema.sql`; passo a passo em `supabase/README.md`. O banco novo começa zerado, e o Firebase fica guardado como backup.
