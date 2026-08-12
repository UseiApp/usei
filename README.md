# usei
Usei. é uma plataforma de aluguel sob demanda que permite usar o que você precisa, apenas quando precisa. Sem comprar, sem desperdício. Precisou? Usei.

## Backend (Firebase)

`catalogo.html` é o app completo (catálogo, login, checkout, dashboard, admin). Os dados ficam no Firestore, projeto `usei-b1b88`.

- **Autenticação:** Firebase Authentication real (Identity Toolkit REST API, sem SDK — consistente com o resto do projeto, que não usa dependências externas de JS). Senhas nunca são salvas no Firestore, só no Firebase Auth.
- **Admin:** definido pela coleção `admins/{uid}` no Firestore, não por um campo local. O primeiro admin é criado manualmente no Firebase Console; admins existentes podem promover outras contas pelo painel (aba "Administradores").
- **Regras de segurança:** ver `firestore.rules` neste repositório — precisa estar publicado no Console (Firestore Database → Regras) para os dados ficarem protegidos. Sem isso, qualquer pessoa pode ler/escrever tudo.
- **Setup necessário no Firebase Console** (uma vez): Authentication → Sign-in method → ativar "Email/Password".
