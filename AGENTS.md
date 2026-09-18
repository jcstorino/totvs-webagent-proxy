# AGENTS.md — totvs-webagent-proxy

## Objetivo

Este projeto implementa um proxy nativo para macOS para compatibilizar o TOTVS Protheus WebApp/WebAgent com navegadores que exigem WebSocket seguro (WSS), especialmente Safari, sem alterar a porta configurada no Protheus.

O comportamento funcional já foi validado com um protótipo Python. A implementação Swift DEVE preservar esse comportamento.

## Estado atual

- Projeto: `totvs-webagent-proxy`
- Plataforma principal de desenvolvimento: macOS Apple Silicon (Mac M1).
- O Swift Package já compila em modo release.
- Build validado:
  - `Build complete!`
  - `dist/totvs-webagent-proxy: Mach-O 64-bit executable arm64`
- Existem warnings do linker sobre paths de CommandLineTools inexistentes; não impediram o build e não são prioridade enquanto a implementação funcional estiver em andamento.
- O binário Swift atual ainda não deve ser considerado substituto do protótipo Python até passar por todos os testes descritos abaixo.

## Problema original

O TOTVS WebAgent 1.1.1 funciona no Chrome, mas o Safari apresenta incompatibilidade no cenário HTTPS.

A aplicação Protheus/WebApp é acessada por HTTPS. O WebAgent local escuta por padrão na porta `21021`.

No Chrome foi comprovado o seguinte fluxo:

    página HTTPS
        -> ws://127.0.0.1:21021/agent?uuid=0
        -> WebAgent

O Chrome aceita esse WebSocket loopback sem TLS nesse cenário.

No Safari, o WebSocket sem TLS é bloqueado como mixed content. O fluxo necessita:

    wss://127.0.0.1:21021/agent?uuid=0

Entretanto, o WebAgent não implementa TLS diretamente nessa porta.

## Evidências técnicas já comprovadas

### WebAgent

Executável:

    /Applications/web-agent.app/Contents/MacOS/web-agent

Opções conhecidas:

    --tray
    --console
    --version
    --help
    --port <port>
    --locallog <enabled>

O WebAgent aceita WebSocket puro.

Um WebSocket Upgrade enviado diretamente à porta do WebAgent retorna:

    HTTP/1.1 101 Switching Protocols

O WebAgent NÃO funciona como servidor TLS diretamente. Tentativas HTTPS/TLS contra sua porta produziram erros de protocolo/"wrong version number".

### Certificados do WebAgent

Arquivos existentes no bundle:

    /Applications/web-agent.app/Contents/MacOS/totvs_certificate.crt
    /Applications/web-agent.app/Contents/MacOS/totvs_certificate_key.pem
    /Applications/web-agent.app/Contents/MacOS/totvs_certificate_CA.crt

O certificado possui SAN para:

    DNS:localhost
    IP Address:127.0.0.1

Esses arquivos NÃO devem ser copiados para o repositório público.

O proxy deve utilizar os arquivos presentes na instalação local do WebAgent.

### Teste TLS já validado

Foi comprovado manualmente que uma camada TLS na porta 21021 encaminhando para WebAgent sem TLS na 21022 resolve o Safari.

Fluxo validado:

    Safari
       -> WSS/TLS 127.0.0.1:21021
       -> TLS termination
       -> TCP/WS 127.0.0.1:21022
       -> WebAgent

Um teste com `openssl s_client` contra o proxy retornou TLS válido e:

    Verify return code: 0 (ok)

No Safari:

    new WebSocket('wss://127.0.0.1:21021/agent?uuid=0')

abriu com sucesso.

## Descoberta importante: Chrome e Safari usam protocolos diferentes

Foi capturado tráfego real chegando à porta 21021.

Chrome envia WebSocket Upgrade puro, começando aproximadamente com:

    GET /agent?uuid=0 HTTP/1.1
    Host: 127.0.0.1:21021
    Connection: Upgrade
    Upgrade: websocket
    Origin: https://<servidor-protheus>

Safari envia TLS ClientHello, começando com bytes de TLS:

    0x16 0x03 ...

Portanto a porta 21021 precisa aceitar OS DOIS casos:

1. WS puro/TCP — Chrome.
2. WSS/TLS — Safari.

O proxy deve detectar o protocolo olhando os primeiros bytes da conexão.

Regra já validada no protótipo:

    primeiro byte == 0x16
    segundo byte == 0x03
        => TLS/WSS

Caso contrário:

        => WS puro

Não alterar essa arquitetura sem uma razão técnica comprovada.

## Arquitetura obrigatória

A configuração do Protheus deve continuar usando:

    127.0.0.1:21021

A porta 21021 NÃO deve ser alterada no Protheus.

Arquitetura:

    Safari / Chrome
          |
          v
    totvs-webagent-proxy
    127.0.0.1:21021
          |
          | WS puro após eventual TLS termination
          v
    TOTVS WebAgent
    127.0.0.1:21022

A porta 21022 é interna à solução.

O proxy deve escutar SOMENTE loopback (`127.0.0.1`), não interfaces externas.

## Inicialização do WebAgent

O WebAgent não deve ficar permanentemente rodando.

Quando chegar a primeira conexão e não houver WebAgent escutando na 21022, o proxy deve iniciar:

    /Applications/web-agent.app/Contents/MacOS/web-agent \
      --tray \
      --port 21022 \
      --locallog 1

IMPORTANTE: usar `--tray`.

NÃO usar `--console` para execução em background. Foi comprovado que `--console` tenta ler stdin/TTY e pode ficar suspenso com `tty input`.

Após iniciar, aguardar a porta 21022 ficar disponível antes de conectar o cliente ao upstream.

O protótipo usou aproximadamente 5 segundos de tolerância, verificando em intervalos curtos.

## Gerenciamento de conexões

A decisão de encerrar o WebAgent NÃO pode ser baseada em quantidade de tráfego ou "tempo sem bytes".

Um usuário pode permanecer logado no Protheus por horas sem interagir.

Enquanto o WebSocket/TCP estiver ABERTO:

    WebAgent deve permanecer rodando.

Manter contador de conexões efetivamente abertas através do proxy.

Exemplo:

    3 conexões -> mantém
    2 conexões -> mantém
    1 conexão  -> mantém
    0 conexões -> inicia temporizador

Somente quando a última conexão for realmente fechada deve iniciar o timer de shutdown.

## Shutdown automático

Delay atualmente validado:

    60 segundos

Quando o contador chegar a zero:

    aguardar 60 segundos

Se surgir nova conexão durante esse período:

    cancelar/inutilizar o shutdown pendente

Se após 60 segundos continuar com zero conexões:

    encerrar WebAgent

O proxy deve encerrar SOMENTE uma instância do WebAgent que ele próprio tenha iniciado.

Não matar arbitrariamente outro processo WebAgent do usuário.

O protótipo Python utilizou uma "generation" para invalidar timers antigos quando uma nova conexão surgia. Uma implementação Swift equivalente é aceitável.

## Concorrência

A implementação deve ser thread-safe.

Há pelo menos estes estados compartilhados:

- quantidade de conexões ativas;
- processo WebAgent iniciado pelo proxy;
- operação de startup do WebAgent;
- geração/token do shutdown pendente.

Evitar iniciar duas instâncias do WebAgent quando duas conexões chegarem simultaneamente.

## Proxy bidirecional

Depois que a conexão com 21022 estiver estabelecida, o proxy deve encaminhar bytes nas duas direções:

    cliente -> WebAgent
    WebAgent -> cliente

Para conexão Safari:

    cliente TLS
       -> TLS termination no proxy
       -> bytes WebSocket normais
       -> WebAgent

Para Chrome:

    cliente TCP/WS
       -> encaminhamento direto
       -> WebAgent

Não interpretar ou modificar frames WebSocket se não for necessário. O protótipo funcional opera essencialmente como proxy de stream.

## Protótipo Python validado

O comportamento de referência foi implementado em Python 3 usando somente biblioteca padrão.

Elementos essenciais:

- listener `127.0.0.1:21021`;
- `MSG_PEEK` nos primeiros bytes;
- `ssl.SSLContext(PROTOCOL_TLS_SERVER)` para Safari;
- certificado/key do bundle TOTVS;
- `subprocess.Popen` com `--tray --port 21022`;
- upstream TCP `127.0.0.1:21022`;
- duas rotinas de cópia bidirecional;
- contador de conexões;
- shutdown após 60 s em zero conexões;
- cancelamento do shutdown se nova conexão chegar;
- encerramento apenas do PID/processo iniciado pelo proxy.

Esse protótipo foi testado com sucesso.

## Testes já realizados com sucesso no protótipo

### Safari

PASSOU.

O proxy identificou:

    WSS/TLS

Iniciou o WebAgent na 21022 e o login do Protheus abriu normalmente.

### Chrome

PASSOU.

O mesmo proxy aceitou WS puro e o Protheus funcionou normalmente.

### Sessão ociosa

PASSOU.

Usuário permaneceu logado sem utilizar o Protheus.

O WebAgent NÃO foi encerrado porque a conexão continuava aberta.

### Encerramento

PASSOU.

Ao fechar a última conexão:

    conexões ativas -> 0
    aguarda 60 segundos
    WebAgent encerra

### Reinicialização sob demanda

PASSOU.

Depois do shutdown, uma nova abertura do Protheus inicia novamente o WebAgent.

## Critérios obrigatórios para considerar a implementação Swift pronta

A versão Swift só substitui o Python quando TODOS estes testes passarem:

    Safari                    PASS
    Chrome                    PASS
    sessão ociosa             PASS
    shutdown após 60 s        PASS
    restart sob demanda       PASS

Não remover o protótipo/referência funcional ou declarar a implementação concluída antes desses testes.

## Distribuição

Objetivo final: disponibilizar o projeto publicamente no GitHub e permitir instalação em outras máquinas.

O usuário já possui pelo menos outros três usuários interessados na solução.

A distribuição não deve exigir:

- Python;
- Homebrew;
- socat.

Objetivo final preferido:

    binário nativo macOS

Idealmente Universal Binary:

    arm64
    x86_64

para Apple Silicon e Intel, se as APIs utilizadas e deployment target permitirem.

Instalação pretendida do executável:

    /usr/local/bin/totvs-webagent-proxy

Não utilizar `/usr/bin`, pois é área do sistema protegida pelo macOS/SIP.

## launchd

Depois da implementação nativa ser validada, criar LaunchAgent para iniciar o proxy automaticamente no login do usuário.

Local esperado:

    ~/Library/LaunchAgents/

O proxy pode permanecer aguardando na 21021 com consumo mínimo.

O WebAgent continua sendo iniciado e encerrado sob demanda.

Primeiro validar completamente o binário manualmente. Só depois finalizar instalação automática/launchd.

## Repositório público

Nome:

    totvs-webagent-proxy

Não versionar:

- certificados TOTVS;
- private keys;
- arquivos proprietários do WebAgent;
- binários proprietários TOTVS;
- dados específicos de clientes;
- IP/endereço do ambiente de desenvolvimento.

README deve deixar claro que é projeto independente/não oficial e não afiliado à TOTVS.

TOTVS, Protheus e WebAgent são nomes/marcas/produtos de terceiros.

Antes da publicação, revisar também licença e eventuais implicações de distribuição.

## Estrutura pretendida

A estrutura inicial criada segue aproximadamente:

    totvs-webagent-proxy/
    ├── README.md
    ├── LICENSE
    ├── .gitignore
    ├── Package.swift
    ├── AGENTS.md
    ├── Sources/
    │   └── WebAgentProxy/
    ├── scripts/
    ├── launchd/
    └── dist/

Manter a estrutura simples e adequada tanto para Swift Package Manager quanto para abertura no Xcode.

## Build já utilizado

Na raiz:

    ./scripts/build.sh

Resultado confirmado no Mac M1:

    Build complete!
    dist/totvs-webagent-proxy: Mach-O 64-bit executable arm64

Existiram warnings:

    ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found
    ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found

Eles não impediram o build. Investigar depois, sem desviar da implementação funcional neste momento.

## Prioridade para o Codex

Ao continuar este projeto:

1. Inspecione primeiro `Package.swift`, `Sources/` e scripts existentes.
2. Não reestruture o projeto sem necessidade.
3. Use este AGENTS.md como contrato funcional.
4. Implemente a versão Swift incrementalmente.
5. Preserve exatamente a arquitetura 21021 -> proxy -> 21022.
6. Não introduza dependência de Python/Homebrew/socat no produto final.
7. Não coloque certificados/chaves TOTVS no repositório.
8. Faça build após alterações relevantes.
9. Trate warnings separadamente de erros funcionais.
10. Antes de considerar concluído, solicite/execute os cinco testes funcionais obrigatórios.

## Próxima tarefa

Continuar a implementação nativa Swift do proxy.

A implementação deve começar pela inspeção do código existente e então completar:

- listener loopback 21021;
- detecção WS/WSS;
- TLS server-side usando os certificados existentes do WebAgent;
- gerenciamento do processo WebAgent na 21022;
- proxy bidirecional;
- contador de conexões;
- shutdown seguro de 60 segundos;
- logs;
- tratamento de erros.

A versão Python validada é a especificação comportamental. Não alterar o comportamento apenas por conveniência de implementação em Swift.
